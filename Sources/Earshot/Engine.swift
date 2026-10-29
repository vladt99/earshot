import AVFoundation
import FluidAudio
import Foundation
import WhisperKit

struct TranscribeOptions: Codable, Sendable {
    var model: String?
    /// ISO 639-1 hint, nil = auto-detect (Parakeet v3 detects the language itself). Any language but English
    /// goes to Whisper.
    var language: String?
    /// Whisper only: decode straight to English.
    var translate = false
    /// Label speakers (FluidAudio offline diarizer, pyannote Community-1).
    var diarize = false
    /// Rescore against Settings.vocabulary (Parakeet CTC 110M). Off for live passes.
    var boostVocabulary = true
}

struct EngineOutput: Sendable {
    var model: String
    var language: String?
    var duration: Double?
    var text: String
    var segments: [Segment]
    /// Speaker label ("Speaker 1") → voice embedding, when diarized.
    var voices: [String: [Float]] = [:]
}

/// Diarizer output: turns plus one voice embedding per speaker id.
struct SpeakerTurns: Sendable {
    var turns: [(start: Double, end: Double, speaker: String)]
    var embeddings: [String: [Float]]
}

/// One decoded word of a live pass, times relative to the pass start.
struct LiveWord: Sendable {
    var text: String
    var start: Double
    var end: Double

    /// For agreement between passes: case/punctuation-insensitive.
    var key: String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
}

/// Speech engine: NVIDIA Parakeet TDT 0.6B v3 (FluidAudio, Core ML) for English and auto-detect, Whisper
/// large-v3-turbo (WhisperKit) for any other language, and FluidAudio's offline pyannote pipeline for speakers.
/// Models are not bundled: they download on first use into ~/Library/Application Support/FluidAudio/Models and
/// ~/Library/Application Support/Earshot/Models/whisperkit.
actor Engine {
    static let shared = Engine()
    static let modelID = "parakeet-tdt-v3"
    static let whisperID = "whisper-large-v3-turbo"

    /// English and auto-detect stay on Parakeet; any other language is forced on Whisper. An explicit model id wins.
    nonisolated static func usesWhisper(language: String?, model: String? = nil) -> Bool {
        if let model, let m = ModelCatalog.find(model), [ModelCatalog.parakeet.id, ModelCatalog.whisper.id].contains(m.id) {
            return m.id == ModelCatalog.whisper.id
        }
        guard let code = language?.lowercased().split(separator: "-").first.map(String.init) else { return false }
        return !["", "auto", "en"].contains(code)
    }

    nonisolated static func modelID(for language: String?) -> String { usesWhisper(language: language) ? whisperID : modelID }

    private var asr: AsrManager?
    private var whisper: WhisperKit?
    private var whisperLoad: Task<WhisperKit, Error>?
    private var whisperFailedAt = Date.distantPast
    private var whisperPrompt: (terms: [String], tokens: [Int]?)?
    private var diarizer: OfflineDiarizerManager?
    private var ctc: CtcModels?
    private var boosting: (terms: [String], session: VocabularyBoostingSession)?
    private(set) var loadedModel: String?

    // One in-flight load per model; every caller awaits the same task.
    private var asrLoad: Task<AsrManager, Error>?
    private var diarizerLoad: Task<Void, Error>?
    private var ctcLoad: Task<CtcModels, Error>?
    private var boostingLoad: (terms: [String], task: Task<VocabularyBoostingSession, Error>)?

    // Inference is serialized: live passes, file jobs and diarization share the models. A waiting live pass goes
    // before waiting batch work.
    private var locked = false
    private var liveWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire(live: Bool = false) async {
        if !locked { locked = true; return }
        await withCheckedContinuation { if live { liveWaiters.append($0) } else { waiters.append($0) } }
    }

    private func release() {
        if !liveWaiters.isEmpty { liveWaiters.removeFirst().resume() }
        else if !waiters.isEmpty { waiters.removeFirst().resume() }
        else { locked = false }
    }

    // MARK: Models

    /// Downloads (first run only) and loads Parakeet v3.
    func ensureLoaded(_ requested: String? = nil) async throws -> String {
        if asr != nil { return Self.modelID }
        _ = try await loadASR().value
        return Self.modelID
    }

    private func loadASR() -> Task<AsrManager, Error> {
        if let asrLoad { return asrLoad }
        let task = Task { () throws -> AsrManager in
            defer { asrLoad = nil }
            let id = ModelCatalog.parakeet.id
            let downloading = !ModelCatalog.isInstalled(ModelCatalog.parakeet)
            await publish(downloading ? "Downloading Parakeet v3 (\(ModelCatalog.parakeet.sizeText))…" : "Loading Parakeet v3…")
            do {
                let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: Self.progress(id))
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                asr = manager
                loadedModel = Self.modelID
                await Self.finishDownload(id)
                await publish("Ready")
                return manager
            } catch {
                let message = "Could not download or load Parakeet v3: \(error.localizedDescription)"
                await Self.failDownload(id, message)
                await publish("Speech model unavailable")
                throw APIError(503, message)
            }
        }
        asrLoad = task
        return task
    }

    private func loadDiarizer() async throws -> OfflineDiarizerManager {
        if let diarizer { return diarizer }
        let task = diarizerLoad ?? Task { () throws in
            defer { diarizerLoad = nil }
            let id = ModelCatalog.diarizer.id
            await MainActor.run { AppState.shared.downloads[id] = AppState.shared.downloads[id] ?? 0 }
            do {
                let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
                try await manager.prepareModels()
                diarizer = manager
                await Self.finishDownload(id)
            } catch {
                await Self.failDownload(id, "Could not download the speaker model: \(error.localizedDescription)")
                throw APIError(503, "Could not download the speaker model: \(error.localizedDescription)")
            }
        }
        diarizerLoad = task
        try await task.value
        guard let diarizer else { throw APIError(503, "Speaker model unavailable") }
        return diarizer
    }

    /// Downloads and loads the speaker model without running it (Settings → Download).
    func prepareDiarizer() async throws { _ = try await loadDiarizer() }

    func unloadDiarizer() { diarizer = nil }

    /// First launch: fetch every speech model so the first meeting doesn't wait on a download.
    func prepareSpeechModels() async {
        _ = try? await ensureLoaded()
        _ = try? await loadDiarizer()
        await EchoCanceller.prepareModel()
        // A non-English language is already picked: have Whisper ready before the first meeting.
        if Self.usesWhisper(language: Settings.language) { _ = try? await prepareWhisper() }
    }

    func unload() {
        asr = nil
        loadedModel = whisper == nil ? nil : Self.whisperID
    }

    // MARK: Whisper

    /// Downloads (once) and loads Whisper large-v3-turbo (Settings → Download, a non-English language picked).
    func prepareWhisper() async throws { _ = try await loadWhisper().value }

    /// A decode in flight keeps its reference until it finishes.
    func unloadWhisper() {
        whisper = nil
        whisperPrompt = nil
        loadedModel = asr == nil ? nil : Self.modelID
    }

    /// Live passes never wait for Whisper's download: until it's loaded (started here) Parakeet covers them.
    func liveUsesWhisper(_ language: String?) -> Bool {
        guard Self.usesWhisper(language: language) else { return false }
        if whisper == nil, whisperLoad == nil, Date().timeIntervalSince(whisperFailedAt) > 60 {
            _ = loadWhisper()
        }
        return whisper != nil
    }

    private func loadWhisper() -> Task<WhisperKit, Error> {
        if let whisperLoad { return whisperLoad }
        if let whisper { return Task { whisper } }
        let task = Task { () throws -> WhisperKit in
            defer { whisperLoad = nil }
            let m = ModelCatalog.whisper, base = ModelCatalog.folder(m)
            let downloading = !ModelCatalog.isInstalled(m)
            await publish(downloading ? "Downloading Whisper large-v3-turbo (\(m.sizeText))…" : "Loading Whisper large-v3-turbo…")
            do {
                if downloading {
                    await MainActor.run { AppState.shared.downloads[m.id] = AppState.shared.downloads[m.id] ?? 0 }
                    // Hub progress counts files, and one file is most of the model: report bytes on disk instead.
                    let meter = Task.detached {
                        while !Task.isCancelled {
                            let f = min(0.99, Double(ModelCatalog.size(of: base, partial: true)) / Double(m.bytes))
                            await MainActor.run { if AppState.shared.downloads[m.id] != nil { AppState.shared.downloads[m.id] = f } }
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    defer { meter.cancel() }
                    _ = try await WhisperKit.download(variant: ModelCatalog.whisperVariant, downloadBase: base, from: m.repo)
                    await publish("Loading Whisper large-v3-turbo…")
                }
                let config = WhisperKitConfig(modelFolder: ModelCatalog.whisperFolder.path, tokenizerFolder: base,
                                              computeOptions: WhisperSupport.compute, verbose: false, logLevel: .error,
                                              load: true, download: false)
                let kit = try await WhisperKit(config)
                whisper = kit
                loadedModel = Self.whisperID
                await Self.finishDownload(m.id)
                await publish("Ready")
                return kit
            } catch {
                whisperFailedAt = Date()
                let message = "Could not download or load Whisper large-v3-turbo: \(error.localizedDescription)"
                await Self.failDownload(m.id, message)
                await publish("Whisper unavailable")
                throw APIError(503, message)
            }
        }
        whisperLoad = task
        return task
    }

    private func whisperPromptTokens(_ kit: WhisperKit) -> [Int]? {
        let terms = Settings.vocabulary
        if let whisperPrompt, whisperPrompt.terms == terms { return whisperPrompt.tokens }
        let tokens = WhisperSupport.prompt(terms, tokenizer: kit.tokenizer)
        whisperPrompt = (terms, tokens)
        return tokens
    }

    /// Whisper words (and the language it heard). Files go through in blocks, releasing the engine between them.
    private func whisperWords(_ samples: [Float], language: String?, translate: Bool, live: Bool) async throws -> (words: [LiveWord], language: String?) {
        let kit: WhisperKit
        if live {
            guard let whisper else { throw APIError(503, "Whisper large-v3-turbo is still loading") }
            kit = whisper
        } else {
            kit = try await loadWhisper().value
        }
        guard samples.count > Int(SampleSink.rate * 0.2), WhisperSupport.hasSound(samples) else { return ([], language) }
        let options = WhisperSupport.options(language: language, translate: translate, live: live, prompt: whisperPromptTokens(kit))
        loadedModel = Self.whisperID
        var words: [LiveWord] = [], detected: String?
        for range in live ? [0..<samples.count] : WhisperSupport.blocks(samples) {
            await acquire(live: live)
            defer { release() }
            let block = range == 0..<samples.count ? samples : Array(samples[range])
            let results = try await kit.transcribe(audioArray: block, decodeOptions: options)
            detected = detected ?? results.first?.language
            let offset = Double(range.lowerBound) / SampleSink.rate
            words += WhisperSupport.words(results.flatMap(\.segments), samples: block)
                .map { LiveWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
        }
        if translate, WhisperSupport.isEnglish(words) { return (words, "en") }
        // Not translated after all (large-v3-turbo mostly answers in the spoken language): the caller translates.
        return (words, language ?? detected)
    }

    // MARK: Custom vocabulary

    /// Downloads Parakeet CTC 110M (≈ 100 MB) and builds the boosting session for the current word list.
    @discardableResult
    func prepareVocabulary(force: Bool = false) async throws -> VocabularyBoostingSession? {
        let terms = Settings.vocabulary
        guard !terms.isEmpty || force else { boosting = nil; return nil }
        if let boosting, boosting.terms == terms { return boosting.session }
        let ctc = try await loadCTC()
        guard !terms.isEmpty else { return nil }
        if let boostingLoad, boostingLoad.terms == terms { return try await boostingLoad.task.value }
        let task = Task { () throws -> VocabularyBoostingSession in
            let vocab = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
            return try await VocabularyBoostingSession(vocabulary: vocab, ctcModels: ctc)
        }
        boostingLoad = (terms, task)
        defer { if boostingLoad?.terms == terms { boostingLoad = nil } }
        let session = try await task.value
        boosting = (terms, session)
        return session
    }

    private func loadCTC() async throws -> CtcModels {
        if let ctc { return ctc }
        if let ctcLoad { return try await ctcLoad.value }
        let task = Task { () throws -> CtcModels in
            defer { ctcLoad = nil }
            let id = ModelCatalog.vocabulary.id
            await MainActor.run { AppState.shared.downloads[id] = AppState.shared.downloads[id] ?? 0 }
            do {
                let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
                ctc = models
                await Self.finishDownload(id)
                return models
            } catch {
                await Self.failDownload(id, "Could not download the vocabulary model: \(error.localizedDescription)")
                throw error
            }
        }
        ctcLoad = task
        return try await task.value
    }

    func resetVocabulary() {
        boosting = nil
        ctc = nil
    }

    /// Rescoring returns corrected text; carry its replacements onto the timed words (one or more words each).
    private func boosted(_ words: [LiveWord], tokenTimings: [TokenTiming], samples: [Float]) async -> [LiveWord] {
        guard !Settings.vocabulary.isEmpty, !words.isEmpty,
              let session = try? await prepareVocabulary(),
              let out = await session.rescore(text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                                              tokenTimings: tokenTimings, audioSamples: samples), out.wasModified else { return words }
        var words = words
        LiveDebug.log("[vocab] text=\(out.text)")
        for r in out.replacements where r.shouldReplace {
            LiveDebug.log("[vocab] '\(r.originalWord)' → '\(r.replacementWord ?? "")' \(r.reason)")
            guard let replacement = r.replacementWord else { continue }
            let original = r.originalWord.split(separator: " ").map { LiveWord(text: String($0), start: 0, end: 0).key }.filter { !$0.isEmpty }
            // The rescorer occasionally maps unrelated words onto a term ("the deadline" → "the Datadog"); only
            // accept replacements that are spelled and sound like what was heard ("Cooper Netties" → "Kubernetes").
            guard !original.isEmpty, words.count >= original.count,
                  VocabularyGuard.accepts(original: r.originalWord, replacement: replacement) else { continue }
            for i in 0...(words.count - original.count) where words[i..<(i + original.count)].map(\.key) == original {
                let span = words[i..<(i + original.count)]
                let trailing = String(span.last!.text.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                let merged = LiveWord(text: " " + replacement + trailing, start: span.first!.start, end: span.last!.end)
                words.replaceSubrange(i..<(i + original.count), with: [merged])
                break
            }
        }
        return words
    }

    // MARK: Transcription

    func transcribe(file: URL, options: TranscribeOptions) async throws -> EngineOutput {
        let (audio, isTemp) = try await AudioPrep.readableAudio(for: file)
        defer { if isTemp { try? FileManager.default.removeItem(at: audio) } }
        let samples = try AudioConverter().resampleAudioFile(audio)
        await publish("Transcribing \(file.lastPathComponent)…")
        defer { Task { await publish("Ready") } }
        var out = try await transcribe(samples: samples, options: options)
        out.duration = await AudioPrep.duration(of: file) ?? Double(samples.count) / SampleSink.rate
        return out
    }

    /// Full transcription of 16 kHz mono samples, optionally with speaker labels.
    func transcribe(samples: [Float], options: TranscribeOptions, speakerPrefix: String = "Speaker") async throws -> EngineOutput {
        let whisper = Self.usesWhisper(language: options.language, model: options.model)
        let words: [LiveWord], language: String?
        if whisper {
            (words, language) = try await whisperWords(samples, language: options.language, translate: options.translate, live: false)
        } else {
            words = try await self.words(samples, language: options.language, boost: options.boostVocabulary)
            language = options.language
        }
        var segments = LiveStream.lines(from: words, offset: 0, speaker: nil)
        var voices: [String: [Float]] = [:]

        if options.diarize, !words.isEmpty {
            await publish("Identifying speakers…")
            // A clip the diarizer can't handle (too short, no speech found) keeps its text, just without speakers.
            do {
                let speakers = try await diarizeDetailed(samples: samples)
                let (labelled, labels) = Self.attribute(words, turns: speakers.turns, prefix: speakerPrefix)
                segments = labelled
                for (id, label) in labels { voices[label] = speakers.embeddings[id] }
            } catch {
                LiveDebug.log("[diarize] skipped: \(error)")
            }
        }
        return EngineOutput(
            model: whisper ? Self.whisperID : Self.modelID,
            language: language,
            duration: Double(samples.count) / SampleSink.rate,
            text: Formats.speakerText(segments),
            segments: segments,
            voices: voices
        )
    }

    /// One streaming pass over the unconfirmed tail of a live stream (`whisper`: from `liveUsesWhisper`).
    func transcribeStream(_ samples: [Float], language: String?, whisper: Bool = false) async throws -> (words: [LiveWord], language: String?) {
        if whisper { return try await whisperWords(samples, language: language, translate: false, live: true) }
        return (try await words(samples, language: language, boost: false, live: true), language)
    }

    private func words(_ samples: [Float], language: String?, boost: Bool, live: Bool = false) async throws -> [LiveWord] {
        _ = try await ensureLoaded()
        guard let asr, samples.count > Int(SampleSink.rate * 0.2) else { return [] }
        await acquire(live: live)
        defer { release() }
        loadedModel = Self.modelID
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state, language: language.flatMap(Language.init(rawValue:)))
        let words = buildWordTimings(from: result.tokenTimings ?? [])
            .map { LiveWord(text: " " + $0.word, start: $0.startTime, end: $0.endTime) }
        guard boost else { return words }
        return await boosted(words, tokenTimings: result.tokenTimings ?? [], samples: samples)
    }

    /// Speaker turns over the given audio.
    func diarize(samples: [Float]) async throws -> [(start: Double, end: Double, speaker: String)] {
        try await diarizeDetailed(samples: samples).turns
    }

    /// Speaker turns plus each speaker's voice embedding (for recognising people across meetings).
    func diarizeDetailed(samples: [Float]) async throws -> SpeakerTurns {
        let d = try await loadDiarizer()
        await acquire()
        defer { release() }
        let result = try await d.process(audio: samples)
        return SpeakerTurns(turns: result.segments.map { (Double($0.startTimeSeconds), Double($0.endTimeSeconds), $0.speakerId) },
                            embeddings: result.speakerDatabase ?? [:])
    }

    /// Words → lines labelled "Speaker N" (numbered by first appearance), split at speaker changes and sentence ends.
    /// Also returns diarizer id → label.
    static func attribute(_ words: [LiveWord], turns: [(start: Double, end: Double, speaker: String)], prefix: String) -> ([Segment], [String: String]) {
        var numbers: [String: Int] = [:]
        func label(_ w: LiveWord) -> String? {
            let mid = (w.start + w.end) / 2
            let hit = turns.first { mid >= $0.start && mid <= $0.end }
                ?? turns.min { abs(($0.start + $0.end) / 2 - mid) < abs(($1.start + $1.end) / 2 - mid) }
            guard let id = hit?.speaker else { return nil }
            if numbers[id] == nil { numbers[id] = numbers.count + 1 }
            return "\(prefix) \(numbers[id]!)"
        }
        var out: [Segment] = []
        var run: [LiveWord] = []
        var runSpeaker: String?
        func flush() {
            out += LiveStream.lines(from: run, offset: 0, speaker: runSpeaker)
            run = []
        }
        for w in words {
            let s = label(w)
            if s != runSpeaker, !run.isEmpty { flush() }
            runSpeaker = s
            run.append(w)
        }
        flush()
        return (out, numbers.mapValues { "\(prefix) \($0)" })
    }

    /// 1 − normalized edit distance.
    static func similarity(_ a: String, _ b: String) -> Double { VocabularyGuard.similarity(a, b) }

    static let hallucinations: Set<String> = ["thank you.", "thanks for watching!", "you", "[music]", "[blank_audio]"]

    private func publish(_ state: String) async {
        let loaded = loadedModel
        await MainActor.run {
            AppState.shared.engineState = state
            AppState.shared.loadedModel = loaded
        }
    }

    static func progress(_ id: String) -> ProgressHandler {
        { p in
            let f = p.fractionCompleted
            Task { @MainActor in AppState.shared.downloads[id] = f }
        }
    }

    static func finishDownload(_ id: String) async {
        await MainActor.run {
            AppState.shared.downloads[id] = nil
            AppState.shared.refreshModelStatus()
        }
    }

    /// Clears the progress bar (so Download shows again) and tells the user why.
    static func failDownload(_ id: String, _ message: String) async {
        await MainActor.run {
            AppState.shared.downloads[id] = nil
            AppState.shared.lastError = message
            AppState.shared.refreshModelStatus()
        }
    }
}

enum AudioPrep {
    /// Formats AVAudioFile reads directly; anything else (video, …) is exported to m4a first.
    static let direct: Set<String> = ["wav", "mp3", "m4a", "aif", "aiff", "caf", "flac", "aac"]

    static func readableAudio(for url: URL) async throws -> (URL, Bool) {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw APIError(404, "File not found or not readable: \(url.path)")
        }
        if direct.contains(url.pathExtension.lowercased()) { return (url, false) }

        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        guard !tracks.isEmpty else { throw APIError(415, "No audio track in \(url.lastPathComponent)") }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw APIError(415, "Cannot extract audio from \(url.lastPathComponent)")
        }
        let out = Paths.uploads.appendingPathComponent(UUID().uuidString + ".m4a")
        try await session.export(to: out, as: .m4a)
        return (out, true)
    }

    static func duration(of url: URL) async -> Double? {
        guard let d = try? await AVURLAsset(url: url).load(.duration), d.isNumeric else { return nil }
        return d.seconds
    }

    static func loadSamples(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }
}

/// Custom vocabulary replacements are kept only when the heard words are spelled and sound like the term.
enum VocabularyGuard {
    static func accepts(original: String, replacement: String) -> Bool {
        let words = original.split(separator: " ").map(letters).filter { !$0.isEmpty }
        let heard = words.joined(), term = letters(replacement)
        guard !heard.isEmpty, !term.isEmpty else { return false }
        let spelled = similarity(heard, term)
        guard spelled >= 0.5, similarity(phonetic(heard), phonetic(term)) >= 0.75 else { return false }
        // An ordinary English word needs to be spelled closer still before it becomes a term.
        if words.count == 1, spelled < 0.6, common.contains(heard) { return false }
        return true
    }

    /// Lowercased letters and digits, diacritics and punctuation removed.
    static func letters<S: StringProtocol>(_ s: S) -> String {
        String(String.UnicodeScalarView(String(s).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// Simplified Metaphone: vowels after the first letter dropped, similar consonants merged, repeats collapsed.
    static func phonetic(_ word: String) -> String {
        var out = ""
        for (i, c) in Array(word.replacingOccurrences(of: "ph", with: "f")).enumerated() {
            let key: String
            switch c {
            case "a", "e", "i", "o", "u", "y": key = i == 0 ? "A" : ""
            case "h", "w": key = i == 0 ? String(c).uppercased() : ""
            case "c", "k", "q", "g", "j": key = "K"
            case "s", "z": key = "S"
            case "d", "t": key = "T"
            case "b", "p": key = "P"
            case "f", "v": key = "F"
            case "x": key = "KS"
            default: key = String(c).uppercased()
            }
            for k in key where out.last != k { out.append(k) }
        }
        return out
    }

    /// 1 − normalized edit distance.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let cur = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = cur
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    /// Lowercase entries of the system word list (proper nouns excluded).
    static let common: Set<String> = {
        guard let list = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
        return Set(list.split(separator: "\n").filter { $0.first?.isLowercase == true }.map { $0.lowercased() })
    }()
}
