import AVFoundation
import FluidAudio
import Foundation

struct TranscribeOptions: Sendable {
    var model: String?
    /// ISO 639-1 hint, nil = auto-detect (Parakeet v3 detects the language itself)
    var language: String?
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

/// Speech engine, locked to FluidAudio: NVIDIA Parakeet TDT 0.6B v3 (Core ML, Neural Engine) for transcription and
/// the offline pyannote pipeline for speakers. Models are not bundled: they download on first use into
/// ~/Library/Application Support/FluidAudio/Models.
actor Engine {
    static let shared = Engine()
    static let modelID = "parakeet-tdt-v3"

    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?
    private var boosting: (terms: [String], session: VocabularyBoostingSession)?
    private(set) var loadedModel: String?

    // Inference is serialized: live passes, file jobs and diarization share the models.
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
    }

    // MARK: Models

    /// Downloads (first run only) and loads Parakeet v3.
    func ensureLoaded(_ requested: String? = nil) async throws -> String {
        if asr != nil { return Self.modelID }
        let downloading = !ModelCatalog.isInstalled(ModelCatalog.parakeet)
        await publish(downloading ? "Downloading Parakeet v3 (\(ModelCatalog.parakeet.sizeText))…" : "Loading Parakeet v3…")
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: Self.progress(ModelCatalog.parakeet.id))
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
        } catch {
            await publish("Speech model unavailable")
            throw APIError(503, "Could not download or load Parakeet v3: \(error.localizedDescription)")
        }
        loadedModel = Self.modelID
        await Self.finishDownload(ModelCatalog.parakeet.id)
        await publish("Ready")
        return Self.modelID
    }

    private func loadDiarizer() async throws -> OfflineDiarizerManager {
        if let diarizer { return diarizer }
        await MainActor.run { AppState.shared.downloads[ModelCatalog.diarizer.id] = AppState.shared.downloads[ModelCatalog.diarizer.id] ?? 0 }
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        diarizer = manager
        await Self.finishDownload(ModelCatalog.diarizer.id)
        return manager
    }

    /// First launch: fetch every speech model so the first meeting doesn't wait on a download.
    func prepareSpeechModels() async {
        _ = try? await ensureLoaded()
        _ = try? await loadDiarizer()
        await EchoCanceller.prepareModel()
    }

    func unload() {
        asr = nil
        loadedModel = nil
    }

    // MARK: Custom vocabulary

    /// Downloads Parakeet CTC 110M (≈ 100 MB) and builds the boosting session for the current word list.
    @discardableResult
    func prepareVocabulary(force: Bool = false) async throws -> VocabularyBoostingSession? {
        let terms = Settings.vocabulary
        guard !terms.isEmpty || force else { boosting = nil; return nil }
        if let boosting, boosting.terms == terms { return boosting.session }
        let id = ModelCatalog.vocabulary.id
        await MainActor.run { AppState.shared.downloads[id] = AppState.shared.downloads[id] ?? 0 }
        defer { Task { await Self.finishDownload(id) } }
        let ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        guard !terms.isEmpty else { return nil }
        let vocab = CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) })
        let session = try await VocabularyBoostingSession(vocabulary: vocab, ctcModels: ctc)
        boosting = (terms, session)
        return session
    }

    func resetVocabulary() { boosting = nil }

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
            let original = r.originalWord.split(separator: " ").map { LiveWord(text: String($0), start: 0, end: 0).key }
            // The rescorer occasionally maps unrelated words onto a term ("Good morning" → "Kubernetes"); only accept
            // replacements that are spelled like what was heard ("Cooper Netties" → "Kubernetes", "post gress" → "Postgres").
            guard !original.isEmpty, words.count >= original.count,
                  Self.similarity(original.joined(), LiveWord(text: replacement, start: 0, end: 0).key) >= 0.5 else { continue }
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
        let words = try await words(samples, language: options.language, boost: options.boostVocabulary)
        var segments = LiveStream.lines(from: words, offset: 0, speaker: nil)
        var voices: [String: [Float]] = [:]

        if options.diarize, !words.isEmpty {
            await publish("Identifying speakers…")
            let speakers = try await diarizeDetailed(samples: samples)
            let (labelled, labels) = Self.attribute(words, turns: speakers.turns, prefix: speakerPrefix)
            segments = labelled
            for (id, label) in labels { voices[label] = speakers.embeddings[id] }
        }
        return EngineOutput(
            model: Self.modelID,
            language: options.language,
            duration: Double(samples.count) / SampleSink.rate,
            text: Formats.speakerText(segments),
            segments: segments,
            voices: voices
        )
    }

    /// One streaming pass over the unconfirmed tail of a live stream.
    func transcribeStream(_ samples: [Float], language: String?) async throws -> (words: [LiveWord], language: String?) {
        (try await words(samples, language: language, boost: false), language)
    }

    private func words(_ samples: [Float], language: String?, boost: Bool) async throws -> [LiveWord] {
        _ = try await ensureLoaded()
        guard let asr, samples.count > Int(SampleSink.rate * 0.2) else { return [] }
        await acquire()
        defer { release() }
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
