import AVFoundation
import FluidAudio
import Foundation
import os
import WhisperKit

private let engineLog = Logger(subsystem: "com.earshot", category: "engine")

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

/// A meeting's hint terms, the custom vocabulary first (`custom` of them): `prompt` for Whisper's prompt (trimmed to
/// its budget from the end), `boost` for Parakeet's rescoring and caption spelling.
struct Hints: Sendable {
    var prompt: [String] = []
    var boost: [String] = []
    var custom = 0
}

struct EngineOutput: Sendable {
    var model: String
    var language: String?
    var duration: Double?
    var text: String
    var segments: [Segment]
    /// Speaker label ("Speaker 1") → voice embedding, when diarized.
    var voices: [String: [Float]] = [:]
    /// Every timed word, and the cleaned speaker turns under the same labels (for naming from captions).
    var words: [LiveWord] = []
    var turns: [SpeakerTurn] = []
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
    /// Whisper's word probability, or Parakeet's lowest token confidence in the word.
    var confidence: Float = 1

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

    /// Parakeet v3 knows the language (nil: it detects it), so its timings can retime Whisper's words. FluidAudio's
    /// Language also lists three languages v3 wasn't trained on.
    nonisolated static func parakeetKnows(_ language: String?) -> Bool {
        guard let code = language?.lowercased().split(separator: "-").first.map(String.init), code != "auto" else { return true }
        guard let l = Language(rawValue: code) else { return false }
        return ![.bosnian, .belarusian, .serbian].contains(l)
    }

    private var asr: AsrManager?
    private var whisper: WhisperKit?
    private var whisperLoad: Task<WhisperKit, Error>?
    private var whisperFailedAt = Date.distantPast
    private var whisperPrompt: (terms: [String], tokens: [Int]?)?
    /// Whisper is unloaded once no meeting is running and nothing has used it for this long (it holds ≈ 1.5 GB).
    static let whisperIdle: TimeInterval = 600
    private var meetingActive = false
    private var whisperUsedAt = Date()
    private var whisperBusy = 0
    private var idleWatch: Task<Void, Never>?
    /// Sessions (MeetingSession.id) a live Whisper pass has heard ≥ 2 s of speech in; until then shorter windows wait.
    private var settled: Set<String> = []
    /// Below this, words of a window decoded before its session settled are dropped (made-up lines are unsure).
    static let unsettledConfidence: Float = 0.5
    private var roomTerms: (key: Int, hints: Hints)?
    /// A step skipped because its model isn't installed is logged once.
    private var skipLogged: Set<String> = []
    private var diarizer: OfflineDiarizerManager?
    /// Clustering bounded by the meeting's roster (same models, other speaker-count limits).
    private var bounded: (min: Int, max: Int, manager: OfflineDiarizerManager)?
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
    // AsrManager reuses its buffers: its calls never interleave, also the timing reference's beside Whisper's batches.
    private var asrLocked = false
    private var asrWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquire(live: Bool = false) async {
        if !locked { locked = true; return }
        await withCheckedContinuation { if live { liveWaiters.append($0) } else { waiters.append($0) } }
    }

    private func release() {
        if !liveWaiters.isEmpty { liveWaiters.removeFirst().resume() }
        else if !waiters.isEmpty { waiters.removeFirst().resume() }
        else { locked = false }
    }

    private func parakeet(_ asr: AsrManager, _ samples: [Float], language: String?) async throws -> ASRResult {
        if asrLocked { await withCheckedContinuation { asrWaiters.append($0) } } else { asrLocked = true }
        defer { if asrWaiters.isEmpty { asrLocked = false } else { asrWaiters.removeFirst().resume() } }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        return try await asr.transcribe(samples, decoderState: &state, language: language.flatMap(Language.init(rawValue:)))
    }

    private func skipping(_ step: String) {
        guard skipLogged.insert(step).inserted else { return }
        LiveDebug.log("[engine] \(step) skipped: model missing")
    }

    // MARK: Models

    /// Downloads (first run only) and loads Parakeet v3.
    func ensureLoaded(_ requested: String? = nil) async throws -> String {
        if asr != nil { return Self.modelID }
        _ = try await loadASR().value
        return Self.modelID
    }

    private func loadASR(priority: TaskPriority? = nil) -> Task<AsrManager, Error> {
        if let asrLoad { return asrLoad }
        let task = Task(priority: priority) { () throws -> AsrManager in
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
            if !ModelCatalog.isInstalled(ModelCatalog.diarizer) {
                await MainActor.run { AppState.shared.downloads[id] = AppState.shared.downloads[id] ?? 0 }
            }
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

    func unloadDiarizer() {
        diarizer = nil
        bounded = nil
    }

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

    /// Ahead of a meeting (pre-join overlay, its language changed): load at low priority what `language` needs,
    /// Whisper or Parakeet, and the speaker model. Downloads only a speech model this language needs and lacks.
    func prewarm(language: String?) async {
        if Self.usesWhisper(language: language) {
            whisperUsedAt = Date()
            if whisper == nil, Date().timeIntervalSince(whisperFailedAt) > 60 { _ = loadWhisper(priority: .utility) }
        } else if asr == nil {
            _ = loadASR(priority: .utility)
        }
        if diarizer == nil, diarizerLoad == nil, ModelCatalog.isInstalled(ModelCatalog.diarizer) {
            Task(priority: .utility) { _ = try? await self.loadDiarizer() }
        }
    }

    /// A meeting session started or stopped. Between meetings Whisper is unloaded after `whisperIdle` unused.
    func setMeetingActive(_ active: Bool) {
        meetingActive = active
        whisperUsedAt = Date()
        watchIdleWhisper()
    }

    private func watchIdleWhisper() {
        guard idleWatch == nil, whisper != nil else { return }
        idleWatch = Task(priority: .background) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                // A pre-join screen still up for a call in a Whisper language keeps it, however long the lobby.
                let lobby = await MainActor.run { AppState.shared.preJoin.map { !$0.dismissed && Self.usesWhisper(language: $0.startLanguage) } ?? false }
                if self.unloadIdleWhisper(lobby: lobby) { return }
            }
        }
    }

    /// True once there's nothing left to watch.
    private func unloadIdleWhisper(lobby: Bool) -> Bool {
        guard whisper != nil else { idleWatch = nil; return true }
        if lobby { whisperUsedAt = Date() }
        let idle = Date().timeIntervalSince(whisperUsedAt)
        guard !meetingActive, whisperBusy == 0, whisperLoad == nil, idle >= Self.whisperIdle else { return false }
        unloadWhisper()
        idleWatch = nil
        engineLog.info("Unloaded Whisper after \(Int(idle / 60)) min unused")
        LiveDebug.log("[engine] unloaded Whisper after \(Int(idle)) s unused")
        return true
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

    private func loadWhisper(priority: TaskPriority? = nil) -> Task<WhisperKit, Error> {
        if let whisperLoad { return whisperLoad }
        if let whisper { return Task { whisper } }
        let task = Task(priority: priority) { () throws -> WhisperKit in
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
                config.segmentSeeker = PromptAlignedSeeker()
                let kit = try await WhisperKit(config)
                await WhisperSupport.warmUp(kit)
                whisper = kit
                whisperUsedAt = Date()
                loadedModel = Self.whisperID
                watchIdleWhisper()
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

    private func whisperPromptTokens(_ kit: WhisperKit, terms: [String], keep: Int) -> [Int]? {
        if let whisperPrompt, whisperPrompt.terms == terms { return whisperPrompt.tokens }
        let tokens = WhisperSupport.prompt(terms, keep: keep, tokenizer: kit.tokenizer)
        whisperPrompt = (terms, tokens)
        return tokens
    }

    /// Whisper words (and the language it heard). Live: one window; `closing` when the stream will commit its words.
    /// Not `decoded` when the window waits for more speech (the stream keeps it). Files: speech only, in concurrent
    /// batches of chunks, releasing the engine between batches.
    private func whisperWords(_ samples: [Float], language: String?, translate: Bool, live: Bool, terms: [String], keep: Int = 0,
                              session: String? = nil, closing: Bool = true) async throws -> (words: [LiveWord], language: String?, decoded: Bool) {
        // Counted busy before any await, so the idle unload can't drop the model in between.
        whisperBusy += 1
        defer { whisperBusy -= 1; whisperUsedAt = Date() }
        let kit: WhisperKit
        if live {
            guard let whisper else { throw APIError(503, "Whisper large-v3-turbo is still loading") }
            kit = whisper
        } else {
            kit = try await loadWhisper().value
        }
        guard samples.count > Int(SampleSink.rate * 0.2), WhisperSupport.hasSound(samples) else { return ([], language, true) }
        let options = WhisperSupport.options(language: language, translate: translate, live: live, prompt: whisperPromptTokens(kit, terms: terms, keep: keep))
        loadedModel = Self.whisperID
        var words: [LiveWord] = [], detected: String?
        if live {
            // A session's first window waits for 2 s of speech: shorter ones come out as made-up lines. One closing (or
            // full) before that is decoded all the same, keeping only words Whisper is sure of.
            let speech = WhisperSupport.speechSeconds(samples), key = session ?? ""
            let early = !settled.contains(key) && speech < 2
            if early, !closing { return ([], language, false) }
            await acquire(live: true)
            let results: [TranscriptionResult]
            do { results = try await kit.transcribe(audioArray: samples, decodeOptions: options) } catch { release(); throw error }
            release()
            detected = results.first?.language
            words = WhisperSupport.words(results.flatMap(\.segments), samples: samples)
            if early { words = words.filter { $0.confidence >= Self.unsettledConfidence } }
            if speech >= 2 { settled.insert(key) }
            // Retimed only when the words are about to be committed, by a Parakeet already loaded that knows the language.
            if closing, options.promptTokens != nil, asr != nil, Self.parakeetKnows(language), !words.isEmpty,
               let reference = try? await self.words(samples, language: language, boost: nil, live: true) {
                words = Retiming.retime(words, to: reference)
            }
        } else {
            let chunks = WhisperSupport.speechChunks(samples)
            // A prompt shifts Whisper's timings: words move onto Parakeet's (decoded meanwhile) before the skipped
            // stretches are looked for. Only with Parakeet installed (never downloaded for this) and knowing the language.
            let retime = options.promptTokens != nil && Self.parakeetKnows(language)
            if retime, asr == nil {
                if ModelCatalog.isInstalled(ModelCatalog.parakeet) { _ = try? await ensureLoaded() } else { skipping("retiming") }
            }
            // A Whisper error leaves this scope, which cancels the reference pass.
            let reference = retime ? asr : nil
            async let timing = parakeetWords(reference, samples: samples, chunks: chunks, language: language)
            let first = try await whisperBatches(samples, chunks: chunks, kit: kit, options: options, detected: &detected)
            let timed = await timing
            words = timed.map { Retiming.retime(first, to: $0) } ?? first
            let gaps = WhisperSupport.skipped(samples, chunks: chunks, words: words)
            if !gaps.isEmpty {
                let found = try await whisperBatches(samples, chunks: gaps.map(\.audio), kit: kit, options: options, detected: &detected)
                words = WhisperSupport.again(words, gaps: gaps, found: timed.map { Retiming.gaps(found, in: gaps, reference: $0) } ?? found)
            }
        }
        if translate, WhisperSupport.isEnglish(words) { return (words, "en", true) }
        // Not translated after all (large-v3-turbo mostly answers in the spoken language): the caller translates.
        return (words, language ?? detected, true)
    }

    /// Parakeet's words for the speech chunks, the timing reference for Whisper's (nil without Parakeet, or cancelled).
    /// Runs beside Whisper's batches (Neural Engine and GPU) outside the engine lock, a chunk per turn of the ASR's.
    private func parakeetWords(_ asr: AsrManager?, samples: [Float], chunks: [Range<Int>], language: String?) async -> [LiveWord]? {
        guard let asr else { return nil }
        var reference: [LiveWord] = []
        for c in chunks {
            guard !Task.isCancelled, let r = try? await parakeet(asr, Array(samples[c]), language: language) else { return nil }
            let offset = Double(c.lowerBound) / SampleSink.rate
            reference += Self.timedWords(r.tokenTimings ?? []).map { LiveWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
        }
        return reference
    }

    /// Chunks decoded concurrently, a batch per turn of the engine lock.
    private func whisperBatches(_ samples: [Float], chunks: [Range<Int>], kit: WhisperKit, options: DecodingOptions,
                                detected: inout String?) async throws -> [LiveWord] {
        var words: [LiveWord] = [], start = 0
        while start < chunks.count {
            await acquire()
            defer { release() }
            // Sized once the lock is ours: a meeting started meanwhile, or live passes waiting, get small batches.
            let size = meetingActive || !liveWaiters.isEmpty ? WhisperSupport.liveBatch : WhisperSupport.batch
            let batch = Array(chunks[start..<min(chunks.count, start + size)])
            start += size
            let r = try await WhisperSupport.decode(samples, chunks: batch, kit: kit, options: options)
            detected = detected ?? r.language
            words += r.words
            whisperUsedAt = Date()
        }
        return words
    }

    /// The meeting's hint terms: the custom vocabulary, then its room vocabulary (or the custom vocabulary alone).
    func terms(for context: MeetingContext?) -> Hints {
        let custom = Settings.vocabulary
        guard Settings.roomVocabulary, let context else { return Hints(prompt: custom, boost: custom, custom: custom.count) }
        var h = Hasher()
        h.combine(custom)
        h.combine(context.title)
        h.combine(context.calendar)
        h.combine(context.participants.map { [$0.name, $0.bot ? "b" : "", $0.presentation ? "p" : ""] })
        h.combine(context.events.filter { $0.kind == .chat })
        let key = h.finalize()
        if let roomTerms, roomTerms.key == key { return roomTerms.hints }
        let hints = Hints(prompt: RoomVocabulary.terms(context, custom: custom),
                          boost: RoomVocabulary.terms(context, custom: custom, limit: RoomVocabulary.boostLimit),
                          custom: RoomVocabulary.terms(nil, custom: custom).count)
        if roomTerms?.hints.boost != hints.boost { LiveDebug.log("[vocab] room: \(hints.prompt.count) terms, \(hints.boost.count) boosted") }
        roomTerms = (key, hints)
        return hints
    }

    // MARK: Custom vocabulary

    /// Downloads Parakeet CTC 110M (≈ 100 MB) and builds the boosting session for the current word list.
    @discardableResult
    func prepareVocabulary(force: Bool = false) async throws -> VocabularyBoostingSession? {
        let terms = Settings.vocabulary
        guard !terms.isEmpty || force else { boosting = nil; return nil }
        guard !terms.isEmpty else { _ = try await loadCTC(); return nil }
        return try await boostingSession(terms)
    }

    /// One session per term list (the custom vocabulary, or a meeting's room vocabulary).
    private func boostingSession(_ terms: [String]) async throws -> VocabularyBoostingSession {
        if let boosting, boosting.terms == terms { return boosting.session }
        let ctc = try await loadCTC()
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
            if !ModelCatalog.isInstalled(ModelCatalog.vocabulary) {
                await MainActor.run { AppState.shared.downloads[id] = AppState.shared.downloads[id] ?? 0 }
            }
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

    /// The boosting session for `terms`, only with the vocabulary model on disk: boosting never downloads it.
    private func installedBoosting(_ terms: [String]?) async -> VocabularyBoostingSession? {
        guard let terms, !terms.isEmpty else { return nil }
        guard ctc != nil || ModelCatalog.isInstalled(ModelCatalog.vocabulary) else { skipping("vocab"); return nil }
        return try? await boostingSession(terms)
    }

    /// Rescoring returns corrected text; carry its replacements onto the timed words (one or more words each).
    private func boosted(_ words: [LiveWord], tokenTimings: [TokenTiming], samples: [Float], session: VocabularyBoostingSession) async -> [LiveWord] {
        guard !words.isEmpty,
              let out = await session.rescore(text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                                              tokenTimings: tokenTimings, audioSamples: samples), out.wasModified else { return words }
        var words = words
        // Counts only: the debug log goes into Copy Diagnostics, so no transcript words or terms.
        LiveDebug.log("[vocab] rescored: \(out.replacements.filter(\.shouldReplace).count) replacements")
        for r in out.replacements where r.shouldReplace {
            LiveDebug.log("[vocab] replacement: \(r.originalWord.split(separator: " ").count) words → \((r.replacementWord ?? "").split(separator: " ").count) words")
            guard let replacement = r.replacementWord else { continue }
            let original = r.originalWord.split(separator: " ").map { LiveWord(text: String($0), start: 0, end: 0).key }.filter { !$0.isEmpty }
            // The rescorer occasionally maps unrelated words onto a term ("the deadline" → "the Datadog"); only
            // accept replacements that are spelled and sound like what was heard ("Cooper Netties" → "Kubernetes").
            guard !original.isEmpty, words.count >= original.count,
                  VocabularyGuard.accepts(original: r.originalWord, replacement: replacement) else { continue }
            for i in 0...(words.count - original.count) where words[i..<(i + original.count)].map(\.key) == original {
                let span = words[i..<(i + original.count)]
                let trailing = String(span.last!.text.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
                let merged = LiveWord(text: " " + replacement + trailing, start: span.first!.start, end: span.last!.end, confidence: 1)
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

    /// Full transcription of 16 kHz mono samples, optionally with speaker labels. `context`: the meeting the audio
    /// comes from, which bounds how many speakers there can be.
    func transcribe(samples: [Float], options: TranscribeOptions, speakerPrefix: String = "Speaker",
                    context: MeetingContext? = nil) async throws -> EngineOutput {
        let whisper = Self.usesWhisper(language: options.language, model: options.model)
        let hints = terms(for: context)
        var words: [LiveWord], language: String?
        if whisper {
            (words, language, _) = try await whisperWords(samples, language: options.language, translate: options.translate, live: false,
                                                          terms: hints.prompt, keep: hints.custom)
        } else {
            words = try await self.words(samples, language: options.language, boost: options.boostVocabulary ? hints.boost : nil)
            language = options.language
        }
        if Settings.captionSpelling, let context, !context.captions.isEmpty { words = CaptionSpelling.fix(words, context: context, terms: hints.boost) }
        var segments = LiveStream.lines(from: words, offset: 0, speaker: nil)
        var voices: [String: [Float]] = [:], turns: [SpeakerTurn] = []
        let duration = Double(samples.count) / SampleSink.rate

        if options.diarize, !words.isEmpty {
            await publish("Identifying speakers…")
            // A clip the diarizer can't handle (too short, no speech found) keeps its text, just without speakers.
            do {
                let bounds = SpeakerPipeline.range(context, duration: duration)
                let speakers = Self.clean(try await diarizeDetailed(samples: samples, speakers: bounds), bounded: bounds != nil)
                let (labelled, labels) = Self.attribute(words, turns: speakers.turns, prefix: speakerPrefix)
                segments = labelled
                for (id, label) in labels { voices[label] = speakers.embeddings[id] }
                turns = speakers.turns.compactMap { t in labels[t.speaker].map { (t.start, t.end, $0) } }
            } catch {
                LiveDebug.log("[diarize] skipped: \(error)")
            }
            await publish("Ready")
        }
        return EngineOutput(
            model: whisper ? Self.whisperID : Self.modelID,
            language: language,
            duration: duration,
            text: Formats.speakerText(segments),
            segments: segments,
            voices: voices,
            words: words,
            turns: turns
        )
    }

    /// Diarizer clusters → turns without flicker, split voices merged; without a roster bound, clusters that
    /// hardly speak are also folded into their neighbours.
    static func clean(_ s: SpeakerTurns, bounded: Bool) -> SpeakerTurns {
        let (turns, embeddings) = SpeakerPipeline.tidy(s.turns, embeddings: s.embeddings,
                                                       same: bounded ? SpeakerPipeline.sameVoiceBounded : SpeakerPipeline.sameVoice, absorb: !bounded)
        let smooth = SpeakerPipeline.smooth(turns)
        return SpeakerTurns(turns: smooth, embeddings: embeddings.filter { id, _ in smooth.contains { $0.speaker == id } })
    }

    /// One streaming pass over the unconfirmed tail of a live stream (`whisper`: from `liveUsesWhisper`). `context`: the
    /// session's live context (room vocabulary for Whisper's prompt, captions for spelling); `at`: where the window
    /// starts on the session's audio clock (estimated from the newest caption when nil); `session`: its id; `closing`:
    /// the stream commits these words; `mic`: the stream is your mic (true) or everyone else (false), for the captions
    /// spelling uses. Not `decoded` when the window waits for more speech.
    func transcribeStream(_ samples: [Float], language: String?, whisper: Bool = false, context: MeetingContext? = nil,
                          at start: Double? = nil, session: String? = nil, closing: Bool = true,
                          mic: Bool? = nil) async throws -> (words: [LiveWord], language: String?, decoded: Bool) {
        let hints = terms(for: context)
        let result: (words: [LiveWord], language: String?, decoded: Bool)
        if whisper {
            result = try await whisperWords(samples, language: language, translate: false, live: true, terms: hints.prompt, keep: hints.custom,
                                            session: session, closing: closing)
        } else {
            result = (try await words(samples, language: language, boost: nil, live: true), language, true)
        }
        guard Settings.captionSpelling, let context, !context.captions.isEmpty, !result.words.isEmpty else { return result }
        let seconds = Double(samples.count) / SampleSink.rate
        let offset = start ?? max(0, (context.captions.map(\.end).max() ?? 0) + 1 - seconds)
        let recent = context.captions.filter { $0.end >= offset - 5 && $0.start <= offset + seconds + 5 }
        guard !recent.isEmpty else { return result }
        var c = context
        c.captions = recent
        return (CaptionSpelling.fix(result.words, context: c, terms: hints.boost, offset: offset, mic: mic), result.language, true)
    }

    /// `boost`: the terms to rescore against (Parakeet CTC), nil for none.
    private func words(_ samples: [Float], language: String?, boost: [String]?, live: Bool = false) async throws -> [LiveWord] {
        _ = try await ensureLoaded()
        guard let asr, samples.count > Int(SampleSink.rate * 0.2) else { return [] }
        // Before taking the lock: loading the vocabulary model and building its session.
        let session = await installedBoosting(boost)
        await acquire(live: live)
        defer { release() }
        loadedModel = Self.modelID
        let result = try await parakeet(asr, samples, language: language)
        let words = Self.timedWords(result.tokenTimings ?? [])
        guard let session else { return words }
        return await boosted(words, tokenTimings: result.tokenTimings ?? [], samples: samples, session: session)
    }

    /// Parakeet tokens → words (as FluidAudio's buildWordTimings), each with its least confident token's confidence.
    static func timedWords(_ tokens: [TokenTiming]) -> [LiveWord] {
        var out: [LiveWord] = []
        for t in tokens where !t.token.isEmpty && t.token != "<blank>" && t.token != "<pad>" {
            if isWordBoundary(t.token) || out.isEmpty {
                out.append(LiveWord(text: " " + stripWordBoundaryPrefix(t.token), start: t.startTime, end: t.endTime, confidence: t.confidence))
            } else {
                out[out.count - 1].text += t.token
                out[out.count - 1].end = t.endTime
                out[out.count - 1].confidence = min(out[out.count - 1].confidence, t.confidence)
            }
        }
        return out.compactMap { w in
            let text = w.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : LiveWord(text: " " + text, start: w.start, end: w.end, confidence: w.confidence)
        }
    }

    /// Speaker turns over the given audio.
    func diarize(samples: [Float]) async throws -> [(start: Double, end: Double, speaker: String)] {
        try await diarizeDetailed(samples: samples).turns
    }

    /// Speaker turns plus each speaker's voice embedding (for recognising people across meetings). `speakers`: how
    /// many people can be talking (from the meeting's roster); the diarizer finds no more than `max`.
    func diarizeDetailed(samples: [Float], speakers: (min: Int, max: Int)? = nil) async throws -> SpeakerTurns {
        var d = try await loadDiarizer()
        if let speakers {
            if let b = bounded, b.min == speakers.min, b.max == speakers.max {
                d = b.manager
            } else {
                var config = OfflineDiarizerConfig()
                config.clustering.minSpeakers = speakers.min
                config.clustering.maxSpeakers = speakers.max
                let m = OfflineDiarizerManager(config: config)
                try await m.prepareModels()
                bounded = (speakers.min, speakers.max, m)
                d = m
            }
        }
        await acquire()
        defer { release() }
        let result = try await d.process(audio: samples)
        return SpeakerTurns(turns: result.segments.map { (Double($0.startTimeSeconds), Double($0.endTimeSeconds), $0.speakerId) },
                            embeddings: result.speakerDatabase ?? [:])
    }

    /// Words → segments labelled "Speaker N" (numbered by first appearance), one speaker per sentence.
    /// Also returns diarizer id → label.
    static func attribute(_ words: [LiveWord], turns: [SpeakerTurn], prefix: String) -> ([Segment], [String: String]) {
        var numbers: [String: Int] = [:]
        let segments = SpeakerPipeline.attribute(words, turns: turns).map { s -> Segment in
            var s = s
            if let id = s.speaker {
                if numbers[id] == nil { numbers[id] = numbers.count + 1 }
                s.speaker = "\(prefix) \(numbers[id]!)"
            }
            return s
        }
        return (segments, numbers.mapValues { "\(prefix) \($0)" })
    }

    /// 1 − normalized edit distance.
    static func similarity(_ a: String, _ b: String) -> Double { VocabularyGuard.similarity(a, b) }

    static let hallucinations = SpeakerPipeline.hallucinations

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
