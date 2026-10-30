import AppKit
import Foundation

/// What the UI and API see of the running meeting.
struct MeetingSnapshot: Sendable {
    var id: String
    var title: String
    var platform: String
    var appName: String
    var startedAt: Date
    var lines: [Segment]
    var hypotheses: [String: String]
    var capturingMic: Bool
    var notes: [Note] = []
    /// "Your microphone has been silent…" — shown in the panel until the condition clears.
    var warning: String?
    /// Meet captions are being read (speaker names come from them).
    var readingCaptions = false
    /// Captions could name speakers but Earshot isn't trusted for Accessibility (an update can revoke the grant).
    var captionsNeedAccess = false
    /// Stop was pressed: capture is over and the meeting is being finished and saved ("Saving…").
    var stopping = false
    /// What the meeting app shows about the room and its people (Google Meet today).
    var context: MeetingContext?
    /// You are muted in the meeting app, so your microphone isn't being recorded.
    var selfMuted = false
    /// The meeting app's captions are off, so speakers can't be named from them.
    var captionsOff = false
    /// The meeting page can't be read as expected (layout changed, no access); shown once as a hint.
    var meetHealth: String? = nil
    /// A Live Captions session that will be saved as a meeting when it stops (`keepSession()`, or a call's captions).
    var kept = false
    /// "Speaker N" labels the user skipped in the panel's "Who is this?" prompt.
    var skippedSpeakers: Set<String> = []
}

/// Starts/stops meeting sessions from detection, UI or API.
@MainActor
final class MeetingController {
    static let shared = MeetingController()

    private(set) var session: MeetingSession?
    /// The session whose Stop is still finishing (last passes, saving). A new meeting may already be running.
    private(set) var stopping: MeetingSession?
    private var stopTask: Task<Transcript?, Never>?
    private var startedFromDetection: String?
    private var dismissTask: Task<Void, Never>?
    private var stopCountdown: Task<Void, Never>?
    private var quitting = false

    var isStopping: Bool { stopping != nil }

    private var activeSessions = 0
    private var activeChain: Task<Void, Never>?

    /// Engine.setMeetingActive in call order, true while any session runs (one may start while the last is saving).
    @discardableResult
    func sessionActive(_ started: Bool) -> Task<Void, Never> {
        activeSessions = max(0, activeSessions + (started ? 1 : -1))
        let active = activeSessions > 0, previous = activeChain
        let t = Task { @MainActor in
            await previous?.value
            await Engine.shared.setMeetingActive(active)
        }
        activeChain = t
        return t
    }

    /// The folder belongs to a session that is recording or still being saved.
    func owns(_ folder: URL) -> Bool {
        [session, stopping].contains { $0?.folder.standardizedFileURL == folder.standardizedFileURL }
    }

    func meetingDetected(_ m: DetectedMeeting) {
        guard !quitting else { return }
        if let session {
            if session.appBundle == m.appBundleID || (session.appBundle == nil && session.call == m.key) {
                // The app took the mic again during the auto-stop countdown (next call, rejoin): keep recording.
                stopCountdown?.cancel()
                AppState.shared.stoppingAt = nil
                AppState.shared.detectedMeeting = nil
                startedFromDetection = m.key
            } else if ["auto", "ask"].contains(Settings.meetingMode) {
                Notifier.post("Meeting detected in \(m.appName)",
                              body: "\(session.title) is still recording, so this call isn't transcribed. Stop it to transcribe \(m.title).")
            }
            return
        }
        switch Settings.meetingMode {
        case "auto":
            do {
                try start(app: m.appBundleID, title: m.title, platform: m.platform, appName: m.appName, mic: true, fromDetection: m.key)
                Notifier.post("Transcribing \(m.title)", body: "\(m.appName) is using the microphone. Live transcript is running.")
            } catch {
                let reason = (error as? APIError)?.message ?? error.localizedDescription
                AppState.shared.lastError = "Couldn't record \(m.title): \(reason)"
                Notifier.post("Couldn't transcribe \(m.title)", body: reason)
                MeetingPanel.shared.show()
            }
        case "ask":
            MeetingPanel.shared.show()
            Notifier.post("Meeting detected in \(m.appName)", body: "Open Earshot to transcribe \(m.title).")
            // "Automatically dismiss detected meeting alerts after 10 seconds"
            dismissTask?.cancel()
            if Settings.autoDismissMeetingAlerts {
                dismissTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(10))
                    guard !Task.isCancelled, self.session == nil, AppState.shared.detectedMeeting?.key == m.key else { return }
                    AppState.shared.detectedMeeting = nil
                    if !AppState.shared.showsPreJoin { MeetingPanel.shared.hide() }
                }
            }
        default:
            break
        }
    }

    /// "Stop recording 10 seconds after a meeting ends. Dismiss the alert to keep recording."
    func detectedMeetingEnded(_ m: DetectedMeeting) {
        guard let s = session, startedFromDetection == m.key, Settings.autoStopAfterMeeting else { return }
        AppState.shared.stoppingAt = Date().addingTimeInterval(10)
        MeetingPanel.shared.show()
        stopCountdown?.cancel()
        stopCountdown = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, AppState.shared.stoppingAt != nil, self.session === s else { return }
            _ = await self.stop(auto: true)
        }
    }

    func keepRecording() {
        stopCountdown?.cancel()
        AppState.shared.stoppingAt = nil
        startedFromDetection = nil
    }

    /// The meeting app showed its end screen ("You left the meeting") or its tab closed: stop now, as the auto-stop
    /// countdown would.
    func observedMeetingEnded(_ s: MeetingSession) {
        guard session === s, Settings.autoStopAfterMeeting else { return }
        LiveDebug.log("[meet] call ended: stopping")
        Task { @MainActor in _ = await self.stop(auto: true) }
    }

    /// Turns the running Live Captions session into a meeting: the audio is kept, polished and saved when it stops.
    @discardableResult
    func keepSession() -> Bool {
        guard let s = session, !s.save else { return false }
        s.keep()
        return true
    }

    /// `app`: bundle id to capture ("com.google.Chrome"), or nil/"system" for all system audio. `language`: picked by the
    /// user for this meeting (before joining): it wins over the meeting's caption language, live and at polish.
    @discardableResult
    func start(app: String?, title: String?, platform: String? = nil, appName: String? = nil,
               mic: Bool = true, fromDetection: String? = nil, origin: String = "meeting", save: Bool = true,
               language: String? = nil) throws -> MeetingSnapshot {
        if let session { return session.snapshot }
        dismissTask?.cancel()
        let detected = MeetingDetector.shared.current
        let bundle = (app == "system") ? nil : (app ?? detected?.appBundleID)
        let name = appName ?? bundle.map { MeetingDetector.meeting(for: $0).appName } ?? "System audio"
        let given = title ?? CalendarLookup.currentEventTitle()
        // System audio while a call is detected records that call: it ends with it and is named after it.
        let call = bundle == nil ? detected : (detected?.key == bundle ? detected : nil)
        let s = MeetingSession(
            appBundle: bundle,
            appName: name,
            platform: platform ?? name,
            title: given ?? (bundle == nil ? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))" : "\(name) meeting"),
            genericTitle: given == nil || given == "Live Captions" || given == "\(name) meeting" || given == call?.title,
            captureMic: mic,
            origin: origin,
            save: save,
            call: call,
            language: language
        )
        do { try s.start() } catch { s.discard(); throw error }
        session = s
        startedFromDetection = fromDetection ?? call?.key
        AppState.shared.meeting = s.snapshot
        AppState.shared.detectedMeeting = nil
        AppState.shared.stoppingAt = nil
        BookmarkHotkey.shared.update()
        MeetingPanel.shared.show()
        EventBus.shared.publish("meeting.started", Self.payload(s.snapshot))
        return s.snapshot
    }

    /// Stops capture, flushes both streams and saves. While that runs (it can take a while) the meeting stays on
    /// screen with `stopping` set, a second Stop waits for the same result, and a new meeting can already start.
    /// `auto`: the auto-stop countdown fired.
    func stop(auto: Bool = false) async -> Transcript? {
        guard let s = session else { return await stopTask?.value }
        session = nil
        startedFromDetection = nil
        stopCountdown?.cancel()
        AppState.shared.stoppingAt = nil
        BookmarkHotkey.shared.update()
        stopping = s
        let task = Task { @MainActor in await self.finish(s, auto: auto) }
        stopTask = task
        return await task.value
    }

    private func finish(_ s: MeetingSession, auto: Bool) async -> Transcript? {
        if !s.save, s.keepsAsMeeting { s.keep() }
        // Polish diarizes both recordings again, so a last live diarization would be wasted work.
        let polish = s.save && (Settings.polishAfterMeeting || s.asrFailed || s.kept)
        let transcript = PostProcess.apply(await s.stop(diarize: s.save && !polish))
        defer {
            if stopping === s { stopping = nil; stopTask = nil }
            if AppState.shared.meeting?.id == s.id { AppState.shared.meeting = nil }
            if session == nil, AppState.shared.detectedMeeting == nil, !AppState.shared.showsPreJoin { MeetingPanel.shared.hide() }
            redetect(after: s, auto: auto)
        }
        guard s.save else {
            try? FileManager.default.removeItem(at: s.folder)
            return transcript
        }
        guard !transcript.segments.isEmpty || MeetingAudio.track(s.folder, "others") != nil else { return nil }
        guard Store.shared.insert(transcript) else {
            // The manifest stays unsaved: recovery tries again at the next launch.
            AppState.shared.lastError = "Couldn't save \(transcript.title) to the library. The recording is kept and will be retried at the next launch."
            Notifier.post("Meeting not saved", body: "\(transcript.title): the recording is kept and will be retried at the next launch.")
            return nil
        }
        AppState.shared.didSave(transcript)
        MeetingManifest.markSaved(s.folder)
        let polishing = polish && !quitting
        EventBus.shared.publish("meeting.saved", ["meeting_id": transcript.id, "transcript_id": transcript.id, "title": transcript.title,
                                                  "polishing": polishing])
        if polishing {
            // The live text is saved; replace it with one clean pass over both recordings.
            Task { @MainActor in
                if let final = (try? await self.retranscribe(transcript.id)) ?? Store.shared.get(transcript.id) { self.finalize(final) }
            }
        } else {
            finalize(transcript)
        }
        return transcript
    }

    /// A call that came in while the last meeting was recording or stopping was only announced: pick it up now.
    /// After a manual Stop the same app's call is left alone (the user stopped it on purpose).
    private func redetect(after s: MeetingSession, auto: Bool) {
        guard !quitting, session == nil,
              let m = MeetingDetector.shared.activeMeetings.first(where: { auto || $0.appBundleID != s.appBundle }) else { return }
        AppState.shared.detectedMeeting = m
        meetingDetected(m)
    }

    /// Quit during a meeting: stop and save it, but don't hold up the quit for more than `timeout` seconds
    /// (an unsaved meeting is recovered at the next launch).
    func stopForQuit(timeout: Double) async {
        quitting = true
        let s = session ?? stopping
        if session != nil { Task { @MainActor in _ = await self.stop() } }
        let deadline = Date().addingTimeInterval(timeout)
        while session != nil || stopping != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        s?.closeFiles()
    }

    /// The meeting's transcript is final: export, webhook/SSE `meeting.finalized`, notification, then the recording
    /// is compressed in the background.
    func finalize(_ t: Transcript) {
        PostProcess.finished(t)
        if let p = t.sourcePath { MeetingAudio.compressLater(URL(fileURLWithPath: p, isDirectory: true)) }
        EventBus.shared.publish("meeting.finalized", ["meeting_id": t.id, "transcript_id": t.id, "title": t.title,
                                                      "speakers": Array(Set(t.segments.compactMap(\.speaker))).sorted()])
        Notifier.post("Meeting saved", body: t.title)
    }

    /// Bookmark (text nil) or note on the running meeting, at the current point of the transcript.
    @discardableResult
    func addNote(_ text: String?, kind: String = "note") -> Note? {
        guard let session else { return nil }
        let note = session.addNote(text, kind: kind)
        if kind == "bookmark" { NSSound(named: "Tink")?.play() }
        return note
    }

    nonisolated static func payload(_ m: MeetingSnapshot) -> [String: Any] {
        ["id": m.id, "title": m.title, "platform": m.platform, "app": m.appName,
         "started_at": Formats.iso(m.startedAt), "capturing_mic": m.capturingMic]
    }

    /// Multitrack re-transcription of a saved meeting at full quality: runs automatically after Stop when
    /// `polishAfterMeeting` is on. The app track is diarized, speakers are named
    /// from Meet captions and saved voices, custom vocabulary is applied, and notes are kept.
    func retranscribe(_ id: String) async throws -> Transcript {
        guard let t = Store.shared.get(id), ["meeting", "podcast", "appaudio"].contains(t.origin), let folder = t.sourcePath.map(URL.init(fileURLWithPath:)) else {
            throw APIError(404, "No such meeting")
        }
        let others = MeetingAudio.track(folder, "others") != nil, me = MeetingAudio.track(folder, "me") != nil
        guard others || me else {
            throw APIError(409, "A meeting needs at least one recorded stream to transcribe")
        }
        guard !AppState.shared.polishing.contains(id) else { throw APIError(409, "This meeting is already being transcribed") }
        AppState.shared.polishing.insert(id)
        defer { AppState.shared.polishing.remove(id) }
        EventBus.shared.publish("meeting.polishing", ["meeting_id": id, "transcript_id": id])
        let started = Date()
        let manifest = MeetingManifest.read(folder)
        let context = t.context ?? MeetingContextFile.read(folder)
        let pinned = manifest?.languagePinned == true ? manifest?.language : nil
        let spoken = Settings.followMeetingLanguage ? context?.captionLanguage.flatMap(Self.languageCode) : nil
        let options = TranscribeOptions(model: nil, language: pinned ?? spoken ?? t.language, diarize: Settings.diarizeMeetings)
        var appSegments: [Segment] = [], mine: [Segment] = []
        var model = t.model, language = options.language
        var duration = 0.0
        // A track that was there but can't be read fails the pass: a transcript missing one side isn't saved over the old one.
        if others {
            guard let samples = await Self.loadTrack(folder, "others") else { throw APIError(500, "Couldn't read the meeting's audio of \(t.title)") }
            duration = Double(samples.count) / SampleSink.rate
            let out = try await Engine.shared.transcribe(samples: samples, options: options, speakerPrefix: "Speaker", context: context)
            model = out.model
            language = language ?? out.language
            appSegments = out.segments.map { var s = $0; s.speaker = s.speaker ?? Settings.participantsName; return s }
            let names = Self.names(for: appSegments, turns: out.turns, words: out.words, voices: out.voices,
                                   hints: manifest?.speakerHints ?? [], context: context, picks: manifest?.speakerPicks ?? [])
            appSegments = appSegments.map { var s = $0; if let n = s.speaker.flatMap({ names[$0] }) { s.speaker = n }; return s }
            var voices: [String: [Float]] = [:]
            for (label, v) in out.voices { voices[names[label] ?? label] = v }
            MeetingVoices.write(voices, to: folder)
        }
        if me {
            guard let samples = await Self.loadTrack(folder, "me") else { throw APIError(500, "Couldn't read your microphone recording of \(t.title)") }
            duration = max(duration, Double(samples.count) / SampleSink.rate)
            var meOptions = options
            meOptions.diarize = false
            // Room vocabulary and caption spelling for your track too.
            let out = try await Engine.shared.transcribe(samples: samples, options: meOptions, context: context)
            mine = out.segments.map { var s = $0; s.speaker = Settings.myName; return s }
        }
        var polished = t
        polished.segments = SpeakerPipeline.merge(appSegments + mine.filter { !Self.isEcho($0, others: appSegments) })
        polished = PostProcess.apply(polished)

        // The user may have renamed, moved, starred or trashed the meeting meanwhile: update only the content, and
        // never bring back a meeting deleted for good.
        guard Store.shared.get(id) != nil else { throw APIError(404, "The meeting was deleted while it was being transcribed") }
        guard Store.shared.updateContent(id: id, segments: polished.segments, text: Formats.speakerText(polished.segments), model: model,
                                         processingSeconds: Date().timeIntervalSince(started),
                                         duration: duration > 0 ? duration : nil, language: language),
              let fresh = Store.shared.get(id) else { throw APIError(500, "Couldn't save the new transcript of \(t.title)") }
        if fresh.deletedAt == nil { AppState.shared.didSave(fresh) }
        AppState.shared.reloadLibrary()
        EventBus.shared.publish("meeting.retranscribed", ["meeting_id": id, "transcript_id": id])
        return fresh
    }

    /// "en-US" → "en".
    nonisolated static func languageCode(_ s: String) -> String? {
        let code = s.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return code.isEmpty ? nil : code
    }

    /// Decodes a recorded track (.wav or .m4a) off the main actor (a 2 h track is ~460 MB of samples).
    nonisolated static func loadTrack(_ url: URL) async -> [Float]? {
        await Task.detached(priority: .userInitiated) { MeetingAudio.readMono16k(url) ?? (try? AudioPrep.loadSamples(url)) }.value
    }

    /// A meeting's track by name ("others", "me"), whichever format it is in now.
    nonisolated static func loadTrack(_ folder: URL, _ name: String) async -> [Float]? {
        await Task.detached(priority: .userInitiated) {
            MeetingAudio.load(folder, name) ?? MeetingAudio.track(folder, name).flatMap { try? AudioPrep.loadSamples($0) }
        }.value
    }

    /// Laptop speakers leak the other side into the microphone: a line of yours that repeats what someone else
    /// said within ±3 s is that echo. Short replies only count when they repeat a whole line of theirs.
    nonisolated static func isEcho(_ line: Segment, others: [Segment]) -> Bool {
        let mine = echoWords(line.text)
        guard !mine.isEmpty else { return false }
        let near = others.filter { $0.start <= line.end + 3 && $0.end >= line.start - 3 }
        guard !near.isEmpty else { return false }
        let lines = near.map { echoWords($0.text) }
        if mine.count < 4 { return lines.contains(mine) }
        if Double(commonRun(mine, Array(lines.joined()))) / Double(mine.count) >= 0.7 { return true }
        let text = mine.joined(separator: " ")
        return lines.contains { Engine.similarity(text, $0.joined(separator: " ")) >= 0.7 }
    }

    nonisolated static func echoWords(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Longest common subsequence of two word lists.
    nonisolated static func commonRun(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diag = 0
            for j in 1...b.count {
                let up = row[j]
                row[j] = x == b[j - 1] ? diag + 1 : max(row[j], row[j - 1])
                diag = up
            }
        }
        return row[b.count]
    }

    /// "Speaker N" → person: names the user picked during the meeting first, then the meeting's captions (they name
    /// whoever talks), then caption hints, then saved voices. Names learned this way are remembered as voices and
    /// added to People.
    static func names(for segments: [Segment], turns: [SpeakerTurn] = [], words: [LiveWord] = [], voices: [String: [Float]],
                      hints: [SpeakerHint], context: MeetingContext? = nil, picks: [SpeakerPick] = []) -> [String: String] {
        let turns = turns.isEmpty ? segments.compactMap { s in s.speaker.map { (start: s.start, end: s.end, speaker: $0) } } : turns
        let picked = SpeakerPicker.fromPicks(turns: turns, picks: picks)
        guard Settings.autoNameSpeakers || !picked.isEmpty else { return [:] }
        var names = picked
        if Settings.autoNameSpeakers {
            let captioned = context.map { SpeakerPipeline.fromCaptions(turns: turns, context: $0, words: words) } ?? [:]
            names.merge(captioned) { a, _ in a }
            let hinted = SpeakerNaming.fromHints(turns: turns.filter { names[$0.speaker] == nil }, hints: hints)
            names.merge(hinted.filter { !names.values.contains($0.value) }) { a, _ in a }
        }
        if Settings.rememberVoices {
            for (label, name) in names { if let v = voices[label] { Store.shared.learnVoice(name, v) } }
            let unnamed = voices.filter { names[$0.key] == nil && Settings.autoNameSpeakers }
            names.merge(SpeakerNaming.fromVoices(unnamed, known: Store.shared.voices(), taken: Set(names.values))) { a, _ in a }
        }
        let people = Set(Store.shared.people().map(\.name))
        for name in Set(names.values) where !people.contains(name) {
            Store.shared.savePerson(Person(id: UUID().uuidString.lowercased(), name: name))
        }
        return names
    }
}

/// One recorded meeting: the meeting app's audio and the microphone as two separate streams and files
/// (the other participants and you), each with its own live transcriber.
@MainActor
final class MeetingSession {
    let id: String
    let appBundle: String?
    let appName: String
    let platform: String
    private(set) var title: String
    let startedAt: Date
    let folder: URL
    let captureMic: Bool
    private(set) var origin: String
    private(set) var save: Bool
    /// The call detected when this session started (its key); the session ends with it.
    let call: String?
    /// The title is a placeholder ("Live Captions", "Dia meeting"): the meeting's own name replaces it once known.
    private var genericTitle: Bool
    /// A Live Captions session turned into a meeting.
    private(set) var kept = false

    private let othersSink: SampleSink
    private let micSink: SampleSink?
    private let tapGaps = GapFiller()
    private let tap: ProcessTapCapture
    private let mic: MicCapture?
    private var streams: [LiveStream] = []
    private var diarizeTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var observer: MeetObserver?
    /// What the meeting app shows (room, people, captions, events), refreshed as it changes.
    private(set) var context: MeetingContext?
    private var calendar: CalendarInfo?
    private var calendarCode: String?
    private var calendarTried = false
    private var contextWritten: MeetingContext?
    private var captionLanguage: String?
    private var selfMuted = false
    private var holding = false
    private var manifestWritten: MeetingManifest?
    private(set) var notes: [Note] = []
    private var hints: [SpeakerHint] = []
    private var warning: String?
    private var warned: Set<String> = []
    /// Diarizer speaker id → person, from captions and saved voices.
    private var speakerNames: [String: String] = [:]
    private var sleepObservers: [NSObjectProtocol] = []
    private(set) var lines: [Segment] = []
    private var hypotheses: [String: String] = [:]
    fileprivate var language: String?
    /// Picked by the user for this meeting: the caption language doesn't replace it.
    private let languagePinned: Bool
    /// Model of the latest live pass (Parakeet covers a non-English meeting until Whisper has loaded).
    fileprivate var liveModel: String?
    /// Diarizer speaker id → stable "Speaker N" label, numbered by first appearance.
    private var speakerNumbers: [String: Int] = [:]
    /// Diarizer speaker id → the name the user picked for it ("Who is this?"); wins over captions and voices.
    private var pinned: [String: String] = [:]
    private var skippedSpeakers: Set<String> = []
    /// Voice of each diarizer speaker id from the last pass.
    private var liveVoices: [String: [Float]] = [:]
    private var captionsNeedAccess = false
    /// Captions left off and the Meet page's health, from the observer.
    private var meetStatus = MeetTracker.Status()
    private var isStopping = false
    /// The speech model failed during the meeting (`asrDown`: right now); the transcript is made from the WAVs.
    private(set) var asrFailed = false
    private var asrDown = false
    static let speechModelWarning = "Speech model not available — recording continues, transcript will be made after the meeting."

    init(appBundle: String?, appName: String, platform: String, title: String, genericTitle: Bool = false, captureMic: Bool,
         origin: String = "meeting", save: Bool = true, call: DetectedMeeting? = nil, language: String? = nil) {
        let id = UUID().uuidString.lowercased(), now = Date()
        self.language = language ?? Settings.language
        self.languagePinned = language != nil
        self.id = id
        self.startedAt = now
        self.origin = origin
        self.save = save
        self.appBundle = appBundle
        self.appName = appName
        self.platform = platform
        self.title = title
        self.genericTitle = genericTitle
        self.captureMic = captureMic
        self.call = call?.key
        self.meetBundle = Self.meetBrowser(appBundle: appBundle, platform: platform, call: call)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let safe = title.replacingOccurrences(of: "/", with: "-").prefix(60)
        var name = "\(f.string(from: now)) \(safe)"
        if FileManager.default.fileExists(atPath: Paths.meetings.appendingPathComponent(name).path) { name += " \(id.prefix(6))" }
        folder = Paths.dir(Paths.meetings.appendingPathComponent(name, isDirectory: true))
        othersSink = SampleSink(fileURL: folder.appendingPathComponent("others.wav"))
        micSink = captureMic ? SampleSink(fileURL: folder.appendingPathComponent("me.wav")) : nil
        tap = ProcessTapCapture(mode: appBundle.map { .apps(MeetingApp.audioProcesses(of: $0)) } ?? .allSystemAudio,
                                sink: othersSink, gapFiller: tapGaps)
        mic = micSink.map { MicCapture(sink: $0, echoCancellation: Settings.echoCancellation) }
    }

    /// Recovery after a crash keeps what this session would keep at Stop.
    private var manifest: MeetingManifest {
        let keeps = save || keepsAsMeeting
        return MeetingManifest(id: id, title: title, appName: appName, appBundle: appBundle, platform: platform,
                               origin: save || !keeps ? origin : "meeting", startedAt: startedAt, captureMic: captureMic,
                               language: language, notes: notes, speakerHints: hints, discard: keeps ? nil : true,
                               languagePinned: languagePinned ? true : nil, speakerPicks: picks.isEmpty ? nil : picks)
    }

    /// The user's picks as the times each named voice talked, for the polish to find them again.
    private var picks: [SpeakerPick] {
        Dictionary(grouping: pinned, by: \.value).sorted { $0.key < $1.key }.map { name, clusters in
            let ids = Set(clusters.map(\.key))
            return SpeakerPick(name: name, spans: turns.filter { ids.contains($0.speaker) }.map { [$0.start, $0.end] })
        }
    }

    private func writeManifest() {
        let m = manifest
        guard m.title != manifestWritten?.title || m.origin != manifestWritten?.origin || m.discard != manifestWritten?.discard
                || m.language != manifestWritten?.language || m.notes != manifestWritten?.notes
                || m.speakerHints.count != manifestWritten?.speakerHints.count || m.speakerPicks != manifestWritten?.speakerPicks else { return }
        m.write(to: folder)
        manifestWritten = m
    }

    /// Live Captions of a call (a Meet page observed, or started while a call was detected) are saved as a meeting.
    var keepsAsMeeting: Bool {
        !save && origin == "captions" && Settings.keepLiveCaptionsOfCalls && (observer != nil || call != nil || context?.meetingCode != nil)
    }

    /// From here on this session is a meeting: saved, polished, in the library.
    func keep() {
        guard !save else { return }
        save = true
        kept = true
        origin = "meeting"
        if genericTitle, title == "Live Captions" {
            title = CalendarLookup.currentEventTitle() ?? "Meeting \(startedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        writeManifest()
        publish()
        EventBus.shared.publish("meeting.kept", ["meeting_id": id, "title": title])
    }

    /// The running meeting on screen; a stopping session no longer replaces a newer meeting's snapshot.
    private func publish() {
        guard MeetingController.shared.session === self || AppState.shared.meeting?.id == id else { return }
        AppState.shared.meeting = snapshot
    }

    /// Current point of the meeting on the transcript's clock (the meeting-audio track).
    private var now: Double { Double(othersSink.total) / SampleSink.rate }

    func addNote(_ text: String?, kind: String) -> Note {
        let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = Note(time: now, text: clean.isEmpty ? "Bookmark" : clean, kind: kind)
        notes.append(note)
        writeManifest()
        publish()
        EventBus.shared.publish("meeting.note", ["meeting_id": id, "kind": kind, "time": Formats.num(note.time), "text": note.text])
        return note
    }

    var snapshot: MeetingSnapshot {
        MeetingSnapshot(id: id, title: title, platform: platform, appName: appName, startedAt: startedAt,
                        lines: lines, hypotheses: hypotheses, capturingMic: micSink != nil,
                        notes: notes, warning: warning, readingCaptions: observer?.active ?? false,
                        captionsNeedAccess: captionsNeedAccess, stopping: isStopping, context: context,
                        selfMuted: selfMuted && Settings.respectMute && micSink != nil, captionsOff: meetStatus.captionsOff,
                        meetHealth: Settings.meetHealthWarnings ? meetStatus.health : nil, kept: kept, skippedSpeakers: skippedSpeakers)
    }

    var othersLabel: String { Settings.participantsName }

    func start() throws {
        // One clock for both tracks, so "me" and "others" line up.
        let clock = mach_absolute_time()
        othersSink.origin = clock
        micSink?.origin = clock
        try tap.start()
        if let mic {
            do { try mic.start() } catch { tap.stop(); throw error }
        }
        streams = [LiveStream(id: "app", speaker: othersLabel, sink: othersSink, session: self)]
        if let micSink { streams.append(LiveStream(id: "mic", speaker: Settings.myName, sink: micSink, session: self)) }
        streams.forEach { $0.start() }
        MeetingController.shared.sessionActive(true)
        if Settings.diarizeMeetings { scheduleDiarization() }
        startObserver()
        // Unsaved sessions (Live Captions) get a manifest too, so recovery deletes their WAVs after a crash.
        writeManifest()
        watch()

        // Sleep: capture pauses and the asleep period is cut from recording and transcript. Synchronous, so no
        // post-wake buffer arrives before the sinks know about the sleep.
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.othersSink.resync()
                self.micSink?.resync()
                EventBus.shared.publish("meeting.resumed_after_sleep", ["meeting_id": self.id])
            }
        })
    }

    /// start() failed: nothing was recorded, remove the folder.
    func discard() {
        closeFiles()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Finalizes both WAV headers (idempotent).
    func closeFiles() {
        othersSink.close()
        micSink?.close()
    }

    /// `diarize`: settle live speaker labels over the whole recording (skipped when polish diarizes anyway).
    func stop(diarize: Bool) async -> Transcript {
        isStopping = true
        publish()
        diarizeTask?.cancel()
        watchTask?.cancel()
        contextChanged()
        observer?.stop()
        writeContext()
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        sleepObservers = []
        tap.stop()
        mic?.stop()
        for s in streams { await s.finish() }
        await MeetingController.shared.sessionActive(false).value
        closeFiles()
        hypotheses = [:]
        if diarize, Settings.diarizeMeetings {
            await diarizeNow(live: false)
            // No polish follows to learn them: remember the voices the user named now.
            if Settings.rememberVoices { for (id, name) in pinned { if let v = liveVoices[id] { Store.shared.learnVoice(name, v) } } }
        }
        lines.sort { $0.start < $1.start }
        let segments = SpeakerPipeline.merge(lines)
        let recorded = Double(max(othersSink.total, micSink?.total ?? 0)) / SampleSink.rate
        return Transcript(
            id: id, createdAt: startedAt, title: title, sourcePath: folder.path, origin: origin,
            model: liveModel ?? Engine.modelID(for: language), language: language,
            duration: recorded > 0 ? recorded : Date().timeIntervalSince(startedAt), processingSeconds: 0,
            text: Formats.speakerText(segments), segments: segments, notes: notes.isEmpty ? nil : notes, context: context
        )
    }

    // MARK: The meeting app: room, people, captions, mute and end (Google Meet in a browser)

    /// The browser showing the Meet call this session records: its own app, or for system audio the browser of the
    /// call detected at start.
    private let meetBundle: String?

    private static func meetBrowser(appBundle: String?, platform: String, call: DetectedMeeting?) -> String? {
        for id in [appBundle, call?.appBundleID].compactMap({ $0 }) where MeetingApp.browsers.contains(id) {
            if platform == "Google Meet" || call?.platform == "Google Meet" || MeetObserver.meetPage(bundleID: id) != nil { return id }
        }
        return nil
    }

    private func startObserver() {
        guard let meetBundle else { return }
        MeetObserver.requestTrust()
        let origin = othersSink.origin ?? mach_absolute_time()
        guard let o = MeetObserver(bundleID: meetBundle, clock: { HostTime.seconds(from: origin, to: HostTime.now) }) else { return }
        let gate = MuteGate(micSink)
        o.onSelfMute = { [weak self] muted in
            // Straight from the observer's thread: every millisecond of a mute is blanked.
            if Settings.respectMute { gate.set(muted) }
            Task { @MainActor in self?.selfMuteChanged(muted) }
        }
        o.onEnded = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.contextChanged()
                MeetingController.shared.observedMeetingEnded(self)
            }
        }
        o.onChange = { [weak self] in Task { @MainActor in self?.contextChanged() } }
        o.onCaptionSpeaker = { [weak self] name in
            Task { @MainActor in
                guard let self else { return }
                self.hints.append(SpeakerHint(time: self.now, name: name))
            }
        }
        o.autoEnableCaptions = Settings.autoEnableCaptions
        observer = o
        if PreJoinWatcher.shared.takeWebTree(meetBundle) { o.adoptWebTree() }
        if Settings.respectMute, MeetObserver.trusted {
            holdMic()
            // You may have joined muted: nothing is recorded until the page says, for up to 5 s.
            gate.closeUntilRead(seconds: 5)
        }
        o.start()
        contextChanged()
    }

    /// The pre-join watcher's page tree for this session's browser: the observer switches it off when it stops.
    func adoptWebTree(_ bundle: String) -> Bool {
        guard bundle == meetBundle, let observer else { return false }
        observer.adoptWebTree()
        return true
    }

    /// The mic track runs 0.75 s behind, so a mute also blanks the words just before it was noticed.
    private func holdMic() {
        guard !holding, let micSink else { return }
        holding = true
        micSink.hold(seconds: 0.75)
    }

    private func selfMuteChanged(_ muted: Bool) {
        if !Settings.respectMute { micSink?.gate(muted: false) }
        guard muted != selfMuted else { return }
        selfMuted = muted
        LiveDebug.log("[meet] self \(muted ? "muted" : "unmuted") at \(String(format: "%.2f", now))")
        EventBus.shared.publish(muted ? "meeting.mic_muted" : "meeting.mic_unmuted",
                                ["meeting_id": id, "time": Formats.num(now), "recording": !(muted && Settings.respectMute)])
        publish()
    }

    private func contextChanged() {
        guard let observer else { return }
        var c = observer.context
        if !calendarTried || (calendarCode == nil && c.meetingCode != nil) {
            calendarTried = true
            calendarCode = c.meetingCode
            calendar = MeetingDetector.calendarInfo(code: c.meetingCode, title: c.title, at: startedAt) ?? calendar
        }
        c.calendar = c.calendar ?? calendar
        if Settings.respectMute, observer.active { holdMic() }
        let status = observer.status
        if status != meetStatus {
            meetStatus = status
            publish()
        }
        if Settings.followMeetingLanguage, !languagePinned, let code = c.captionLanguage.flatMap(MeetingController.languageCode), code != captionLanguage {
            captionLanguage = code
            if code != language.flatMap(MeetingController.languageCode) {
                LiveDebug.log("[meet] caption language \(code): live passes switch to it")
                language = code
                streams.forEach { $0.languageChanged() }
            }
        }
        if genericTitle, let better = [c.title, c.calendar?.title].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty && $0 != c.meetingCode }) {
            title = better
            genericTitle = false
        }
        guard c != context else { return }
        context = c
        if save || keepsAsMeeting { writeManifest() }
        publish()
    }

    private func writeContext() {
        guard let context, context != contextWritten else { return }
        MeetingContextFile.write(context, to: folder)
        contextWritten = context
    }

    // MARK: Watchdog: stalled capture, silent tracks, periodic manifest

    private func watch() {
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.checkAudio()
                if self.save || self.keepsAsMeeting { self.writeManifest() }
                self.writeContext()
            }
        }
    }

    private func checkAudio() {
        // A capture that delivers nothing at all is broken (device vanished, coreaudiod restarted): rebuild it.
        if othersSink.secondsSinceData > 8 {
            tap.restart()
            EventBus.shared.publish("meeting.capture_restarted", ["meeting_id": id, "stream": "app"])
        }
        if let mic, mic.secondsSinceBuffer > 8 {
            mic.restart()
            EventBus.shared.publish("meeting.capture_restarted", ["meeting_id": id, "stream": "mic"])
        }
        updateWarning()
    }

    private func updateWarning() {
        let elapsed = Date().timeIntervalSince(startedAt)
        var kind: String?, message: String?
        if Settings.audioWarnings {
            if let mic, elapsed > 60, mic.secondsSinceInput > 60 {
                kind = "mic"
                message = "Your microphone has sent only silence for a minute. Check the input device in System Settings → Sound."
            } else if elapsed > 120, othersSink.secondsSinceSound > 120 {
                kind = "app"
                message = "No sound from \(appName) for 2 minutes. If people are talking, make sure the call is running in \(appName)."
            }
        }
        if message == nil, asrDown {
            kind = "speech_model"
            message = Self.speechModelWarning
        }
        let readingCaptions = observer?.active ?? false
        let needAccess = observer != nil && !MeetObserver.trusted
        guard message != warning || readingCaptions != snapshotCaptions || needAccess != captionsNeedAccess else { return }
        snapshotCaptions = readingCaptions
        captionsNeedAccess = needAccess
        if message != warning {
            warning = message
            if let kind, let message {
                EventBus.shared.publish("meeting.warning", ["meeting_id": id, "kind": kind, "message": message])
                if warned.insert(kind).inserted {
                    Notifier.post(kind == "speech_model" ? "Live transcript paused" : "Check your meeting audio", body: message)
                }
            }
        }
        publish()
    }

    private var snapshotCaptions = false

    fileprivate func speechModelFailed() {
        asrFailed = true
        guard !asrDown else { return }
        asrDown = true
        updateWarning()
    }

    fileprivate func speechModelRecovered() {
        guard asrDown else { return }
        asrDown = false
        updateWarning()
    }

    // MARK: Stream callbacks

    /// Lines from the microphone track (everything else is the meeting app's audio).
    private func isMine(_ s: Segment) -> Bool { s.speaker == streams.last(where: { $0.id == "mic" })?.speaker }

    fileprivate func confirmed(_ line: Segment, stream: LiveStream) {
        var line = line
        if stream.id == "mic" {
            let theirs = lines.filter { !isMine($0) && $0.end >= line.start - 3 }
            if MeetingController.isEcho(line, others: theirs) {
                LiveDebug.log("[echo] dropped mic line: \(line.text)")
                return
            }
        } else {
            if let label = speakerLabel(at: line) { line.speaker = label }
            // The echo of this line may already be on screen as yours.
            let theirs = lines.filter { !isMine($0) && $0.end >= line.start - 6 } + [line]
            lines.removeAll { isMine($0) && $0.end >= line.start - 3 && MeetingController.isEcho($0, others: theirs) }
        }
        lines.append(line)
        EventBus.shared.publish("meeting.segment", ["meeting_id": id, "stream": stream.id, "speaker": line.speaker ?? "",
                                                    "start": Formats.num(line.start), "end": Formats.num(line.end), "text": line.text])
        publish()
    }

    fileprivate func hypothesis(_ text: String, stream: LiveStream) {
        guard hypotheses[stream.speaker, default: ""] != text else { return }
        hypotheses[stream.speaker] = text
        publish()
        EventBus.shared.publish("meeting.partial", ["meeting_id": id, "stream": stream.id, "speaker": stream.speaker, "text": text])
    }

    // MARK: Live speaker labels: pyannote over the app recording so far, re-run as it grows, revising
    // lines already on screen.

    private var turns: [SpeakerTurn] = []

    /// The others track's lines as words, spread evenly over each line (for lining captions up with what was heard).
    private var liveWords: [LiveWord] {
        lines.filter { !isMine($0) }.flatMap { l -> [LiveWord] in
            let parts = l.text.split(separator: " ")
            let step = (l.end - l.start) / Double(max(1, parts.count))
            return parts.enumerated().map { i, w in LiveWord(text: " " + w, start: l.start + Double(i) * step, end: l.start + Double(i + 1) * step) }
        }
    }

    /// Each pass covers the whole recording, so passes are spaced out as it grows (and by how long the last one
    /// took) to leave the engine to live transcription.
    private func scheduleDiarization() {
        diarizeTask = Task { @MainActor [weak self] in
            var lastSeconds = 0.0, cost = 0.0
            while !Task.isCancelled {
                let recorded = self.map { Double($0.othersSink.total) / SampleSink.rate } ?? 0
                try? await Task.sleep(for: .seconds(max(20, 3 * cost, recorded / 15)))
                guard !Task.isCancelled, let self else { return }
                let seconds = Double(self.othersSink.total) / SampleSink.rate
                if seconds - lastSeconds >= 20, self.lines.contains(where: { !self.isMine($0) }) {
                    lastSeconds = seconds
                    let started = Date()
                    await self.diarizeNow(live: true)
                    cost = Date().timeIntervalSince(started)
                }
            }
        }
    }

    /// `live`: a periodic pass, dropped when the meeting stops meanwhile.
    private func diarizeNow(live: Bool) async {
        let url = othersSink.fileURL
        let context = context
        guard let samples = await Task.detached(priority: .utility, operation: { WAVReader.readMonoPCM16(url) }).value,
              !(live && Task.isCancelled), samples.count > Int(SampleSink.rate * 2) else { return }
        let bounds = SpeakerPipeline.range(context, duration: Double(samples.count) / SampleSink.rate)
        guard let result = try? await Engine.shared.diarizeDetailed(samples: samples, speakers: bounds), !(live && Task.isCancelled) else { return }
        let (newTurns, embeddings) = stabilised(Engine.clean(result, bounded: bounds != nil))
        turns = newTurns
        liveVoices = embeddings
        if Settings.autoNameSpeakers {
            var names = context.map { SpeakerPipeline.fromCaptions(turns: newTurns, context: $0, words: liveWords) } ?? [:]
            let hinted = SpeakerNaming.fromHints(turns: newTurns.filter { names[$0.speaker] == nil }, hints: hints)
            names.merge(hinted.filter { !names.values.contains($0.value) }) { a, _ in a }
            if Settings.rememberVoices {
                let unnamed = embeddings.filter { names[$0.key] == nil }
                names.merge(SpeakerNaming.fromVoices(unnamed, known: Store.shared.voices(), taken: Set(names.values).union(pinned.values))) { a, _ in a }
            }
            speakerNames = names
        }
        if !pinned.isEmpty { writeManifest() }
        var revised = 0
        var labels = lines.map(\.speaker)
        for i in lines.indices where !isMine(lines[i]) { labels[i] = speakerLabel(at: lines[i]) ?? labels[i] }
        // A short line between two lines of the same person is theirs (the others track only).
        let theirs = lines.indices.filter { !isMine(lines[$0]) }.sorted { lines[$0].start < lines[$1].start }
        if theirs.count > 2 {
            for k in 1..<(theirs.count - 1) {
                let a = theirs[k - 1], b = theirs[k], c = theirs[k + 1]
                if labels[a] == labels[c], labels[b] != labels[a], lines[b].end - lines[b].start < SpeakerPipeline.flicker,
                   lines[b].start - lines[a].end < 1, lines[c].start - lines[b].end < 1 { labels[b] = labels[a] }
            }
        }
        for i in lines.indices where !isMine(lines[i]) && labels[i] != lines[i].speaker {
            lines[i].speaker = labels[i]
            revised += 1
        }
        if revised > 0 {
            publish()
            EventBus.shared.publish("meeting.speakers_revised", ["meeting_id": id, "revised": revised,
                                                                 "segments": lines.map { ["start": Formats.num($0.start), "end": Formats.num($0.end), "speaker": $0.speaker ?? "", "text": $0.text] }])
        }
    }

    /// Every pass clusters from scratch, so its ids mean nothing across passes: give each new cluster the id of the
    /// previous cluster it overlaps most, so "Speaker 2" stays the same person for lines already on screen.
    private func stabilised(_ result: SpeakerTurns) -> ([(start: Double, end: Double, speaker: String)], [String: [Float]]) {
        guard !turns.isEmpty else { return (result.turns, result.embeddings) }
        var overlap: [String: [String: Double]] = [:]
        var j = 0
        let old = turns.sorted { $0.start < $1.start }
        for n in result.turns.sorted(by: { $0.start < $1.start }) {
            while j < old.count, old[j].end <= n.start { j += 1 }
            var k = j
            while k < old.count, old[k].start < n.end {
                let o = min(n.end, old[k].end) - max(n.start, old[k].start)
                if o > 0 { overlap[n.speaker, default: [:]][old[k].speaker, default: 0] += o }
                k += 1
            }
        }
        var map: [String: String] = [:], used = Set<String>()
        let pairs = overlap.flatMap { n, olds in olds.map { (new: n, old: $0.key, seconds: $0.value) } }.sorted { $0.seconds > $1.seconds }
        for p in pairs where map[p.new] == nil && !used.contains(p.old) {
            map[p.new] = p.old
            used.insert(p.old)
        }
        let taken = used.union(old.map(\.speaker)).union(speakerNumbers.keys)
        var next = 0
        for id in Set(result.turns.map(\.speaker)).union(result.embeddings.keys).sorted() where map[id] == nil {
            var fresh: String
            repeat { next += 1; fresh = "c\(next)" } while taken.contains(fresh) || used.contains(fresh)
            map[id] = fresh
            used.insert(fresh)
        }
        let turns = result.turns.map { (start: $0.start, end: $0.end, speaker: map[$0.speaker] ?? $0.speaker) }
        let embeddings = Dictionary(result.embeddings.map { (map[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { a, _ in a })
        return (turns, embeddings)
    }

    /// "Who is this?" in the panel: `label` ("Speaker 2") is `name` from now on, in the lines on screen, in later passes
    /// and at polish. Naming two labels alike makes them one person.
    func nameSpeaker(_ label: String, _ name: String) {
        guard let n = Int(label.dropFirst("Speaker ".count)), SpeakerPicker.isUnnamed(label),
              let cluster = speakerNumbers.first(where: { $0.value == n })?.key else { return }
        pinned[cluster] = name
        speakerNames[cluster] = nil
        for i in lines.indices where lines[i].speaker == label { lines[i].speaker = name }
        LiveDebug.log("[speakers] named a voice (\(label))")
        EventBus.shared.publish("meeting.speaker_named", ["meeting_id": id, "speaker": label, "name": name])
        writeManifest()
        publish()
    }

    func skipSpeaker(_ label: String) {
        guard skippedSpeakers.insert(label).inserted else { return }
        publish()
    }

    private func speakerLabel(at line: Segment) -> String? {
        var overlap: [String: Double] = [:]
        for t in turns {
            let o = min(t.end, line.end) - max(t.start, line.start)
            if o > 0 { overlap[t.speaker, default: 0] += o }
        }
        guard let best = overlap.max(by: { $0.value < $1.value })?.key else { return nil }
        if let name = pinned[best] ?? speakerNames[best] { return name }
        if speakerNumbers[best] == nil { speakerNumbers[best] = speakerNumbers.count + 1 }
        return "Speaker \(speakerNumbers[best]!)"
    }
}

/// One live transcription stream (one per audio source).
/// - voice-triggered: EnergyVAD(frameLength 0.1 s, threshold 0.02) gates passes; transcribeInterval 0.1 s
/// - confirmation by agreement across passes: 3 confirmations,
///   ≥ 30 common tokens (≈ 12 words), punctuation rule (confirm only up to a sentence end);
///   2.0 s of silence closes the utterance, buffers over 60 s force a pass
/// - the buffer is trimmed at the confirmed time; only the unconfirmed tail is re-decoded
/// - on Whisper (non-English, ≈ 1 s per pass): at most one pass per 2 s per stream, 2 confirmations, and the
///   window is capped at 20 s (everything but its last second is confirmed then)
@MainActor
final class LiveStream {
    static let transcribeInterval = 0.1
    static let minCommonPrefix = 12
    static let tokenConfirmationsNeeded = 3
    static let usePunctuationRule = true
    static let endpointAfter = 2.0
    static let forcePassAfter = 60.0
    static let whisperInterval = 2.0
    static let whisperConfirmations = 2
    static let whisperWindow = 20.0

    let id: String
    let speaker: String
    let sink: SampleSink
    private weak var session: MeetingSession?
    private let vad = EnergyVAD(frameLength: 0.1, threshold: 0.02)
    private var task: Task<Void, Never>?
    /// Absolute sample index where the unconfirmed audio starts.
    private var pendingStart = 0
    private var lastPassTotal = 0
    private var previous: [LiveWord] = []
    private var agreements = 0
    /// Confirmed words of a sentence that hasn't ended yet (absolute times); emitted as one line.
    private var openLine: [LiveWord] = []
    private var lastConfirmed: LiveWord?
    /// Consecutive failed passes (model missing, offline) and when to try again (5 s doubling to 60 s).
    private var failures = 0
    private var retryAt = Date.distantPast
    /// End of the last Whisper pass (passes are spaced from there, leaving the engine to the other stream).
    private var whisperPassAt = Date.distantPast
    /// The window waits, undecoded, for more speech (a session's first words on Whisper).
    private var held = false

    init(id: String, speaker: String, sink: SampleSink, session: MeetingSession) {
        self.id = id
        self.speaker = speaker
        self.sink = sink
        self.session = session
    }

    func start() {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.transcribeInterval))
                guard let self else { return }
                await self.pass(final: false)
            }
        }
    }

    /// The session's language changed (the meeting's captions): what the other engine decoded no longer agrees.
    func languageChanged() {
        previous = []
        agreements = 0
    }

    func finish() async {
        task?.cancel()
        _ = await task?.value
        await pass(final: true)
        session?.hypothesis("", stream: self)
    }

    private func pass(final: Bool) async {
        let language = session?.language, context = session?.context
        let whisper = Engine.usesWhisper(language: language) ? await Engine.shared.liveUsesWhisper(language) : false
        if whisper, !final, Date().timeIntervalSince(whisperPassAt) < Self.whisperInterval { return }
        let rate = SampleSink.rate
        let total = sink.total
        if failures > 0, !final, Date() < retryAt {
            // No speech model: the audio is on disk for the transcript after the meeting; keep only the last 30 s.
            trim(to: total - Int(30 * rate))
            return
        }
        let fresh = total - lastPassTotal
        if !final && Double(fresh) < 0.1 * rate { return }
        let window = sink.read(from: pendingStart)
        let seconds = Double(window.count) / rate
        guard seconds >= (final ? 0.3 : 0.5) else { return }

        let activity = vad.voiceActivity(in: window)
        let newFrames = max(1, Int(Double(fresh) / (0.1 * rate)))
        let newVoice = activity.suffix(newFrames).contains(true)
        let trailingSilence = Double(activity.reversed().prefix { !$0 }.count) * 0.1
        let anyVoice = activity.contains(true)
        let hasPending = !previous.isEmpty || !openLine.isEmpty || held
        let endpoint = trailingSilence >= Self.endpointAfter || (!anyVoice && hasPending && seconds >= Self.endpointAfter)
        let cap = whisper ? Self.whisperWindow : Self.forcePassAfter
        let force = seconds >= cap
        let closing = final || endpoint || force

        if !anyVoice && !hasPending {
            // Silence only: nothing to transcribe; keep a short lead-in.
            if seconds > 1 { trim(to: max(pendingStart, total - Int(0.5 * rate))) }
            lastPassTotal = total
            session?.hypothesis("", stream: self)
            return
        }
        // Voice-triggered: re-decode only when new speech arrived, or to close an utterance.
        guard newVoice || final || force || (endpoint && hasPending) else { return }

        lastPassTotal = total
        let windowStart = Double(pendingStart) / rate
        let result: (words: [LiveWord], language: String?, decoded: Bool)
        do {
            defer { if whisper { whisperPassAt = Date() } }
            result = try await Engine.shared.transcribeStream(window, language: language, whisper: whisper, context: context, at: windowStart,
                                                              session: session?.id, closing: closing, mic: id == "mic")
        } catch {
            held = false
            failures += 1
            retryAt = Date().addingTimeInterval(min(60, 5 * pow(2, Double(min(failures, 5) - 1))))
            previous = []
            agreements = 0
            trim(to: total - Int(30 * rate))
            session?.speechModelFailed()
            return
        }
        if failures > 0 {
            failures = 0
            session?.speechModelRecovered()
        }
        // Too little speech yet: the window stays, to be decoded with what follows or once it closes.
        held = !result.decoded
        if held { return }
        if session?.language == nil, let l = result.language { session?.language = l }
        session?.liveModel = whisper ? Engine.whisperID : Engine.modelID

        // Skip what is already confirmed: everything up to the last confirmed word (matched by text near the
        // confirmed time, falling back to timing).
        let confirmedRel = confirmedUntil - windowStart
        var startIdx = result.words.firstIndex { $0.start >= confirmedRel - 0.05 } ?? result.words.count
        if let last = lastConfirmed,
           let anchor = result.words.lastIndex(where: { $0.key == last.key && abs($0.end - confirmedRel) < 0.6 }) {
            startIdx = anchor + 1
        }
        let words = Array(result.words[min(startIdx, result.words.count)...])

        var confirmCount = 0
        defer {
            LiveDebug.log("[\(id)] t=\(String(format: "%.2f", Double(total) / rate)) win=\(String(format: "%.2f", seconds)) start=\(String(format: "%.2f", windowStart)) conf=\(String(format: "%.2f", confirmedUntil)) endpoint=\(endpoint) final=\(final) prev=\(previous.count) words=\(words.map { "\($0.text.trimmingCharacters(in: .whitespaces))@\(String(format: "%.2f", $0.start))" }.joined(separator: " ")) confirm=\(confirmCount)")
        }
        if closing {
            confirmCount = words.count
            // Whisper's capped window: keep the last second open, its word may be cut off.
            if whisper, force, !final, !endpoint, let i = words.lastIndex(where: { $0.end <= seconds - 1 }) { confirmCount = i + 1 }
        } else {
            var common = zip(previous, words).prefix { $0.key == $1.key }.count
            if Self.usePunctuationRule {
                // Parakeet punctuates the end of every window; only a sentence end inside the agreed prefix counts.
                common = (words.prefix(common).lastIndex { w in
                    let t = w.text.trimmingCharacters(in: .whitespaces)
                    return t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!")
                }).map { $0 + 1 } ?? 0
                if common == words.count { common = 0 } // the pass's own last sentence may still grow
            }
            if common >= Self.minCommonPrefix || (Self.usePunctuationRule && common > 0) {
                agreements += 1
                if agreements >= (whisper ? Self.whisperConfirmations : Self.tokenConfirmationsNeeded) { confirmCount = common }
            } else {
                agreements = 0
            }
        }

        if confirmCount > 0 {
            let done = Array(words.prefix(confirmCount))
            lastConfirmed = done.last
            confirmedUntil = windowStart + done.last!.end
            openLine += done.map { LiveWord(text: $0.text, start: windowStart + $0.start, end: windowStart + $0.end) }
            emitLines(closeAll: closing)
            agreements = 0
        }
        previous = Array(words.dropFirst(confirmCount))

        if closing && previous.isEmpty {
            // Utterance over: drop the buffer.
            trim(to: total)
            lastConfirmed = nil
        } else if let gap = Self.lastSilentGap(activity, before: confirmedUntil - windowStart) {
            // Trim only inside real silence that lies before the confirmed time — never through a word.
            trim(to: pendingStart + Int(gap * rate))
        } else if seconds > cap / 2, confirmCount > 0 {
            trim(to: pendingStart + Int(Self.bestCut(in: window, from: confirmedUntil - windowStart, to: confirmedUntil - windowStart + 0.2) * rate))
        }
        let pending = (openLine + previous).map(\.text).joined().trimmingCharacters(in: .whitespaces)
        session?.hypothesis(pending, stream: self)
    }

    /// Absolute time up to which words are confirmed.
    private var confirmedUntil: Double = 0

    private func trim(to index: Int) {
        guard index > pendingStart else { return }
        pendingStart = index
        sink.discard(before: pendingStart)
    }

    /// Middle (s, relative) of the latest run of ≥ 3 silent VAD frames (0.3 s) that ends before `limit`.
    static func lastSilentGap(_ activity: [Bool], before limit: Double) -> Double? {
        var best: Double?
        var runStart: Int?
        for (i, voiced) in activity.enumerated() {
            if !voiced { if runStart == nil { runStart = i } } else if let r = runStart {
                if i - r >= 3, Double(i) * 0.1 <= limit { best = Double(r + i) / 2 * 0.1 }
                runStart = nil
            }
        }
        return best
    }

    /// Emits finished sentences from the confirmed words; the unfinished tail stays open.
    private func emitLines(closeAll: Bool) {
        var lines = Self.lines(from: openLine, offset: 0, speaker: speaker)
        guard !lines.isEmpty else { return }
        if !closeAll, let last = lines.last, !(last.text.hasSuffix(".") || last.text.hasSuffix("?") || last.text.hasSuffix("!")) {
            lines.removeLast()
            openLine = openLine.filter { $0.start >= last.start }
        } else {
            openLine = []
        }
        for line in lines { session?.confirmed(line, stream: self) }
    }

    /// Start time (s) of the lowest-energy 20 ms frame in [from, to].
    static func bestCut(in samples: [Float], from: Double, to: Double) -> Double {
        let rate = SampleSink.rate, frame = Int(0.02 * rate), hop = Int(0.01 * rate)
        let a = max(0, Int(from * rate)), b = min(samples.count - frame, Int(to * rate))
        guard b > a else { return max(0, min(from, Double(samples.count) / rate)) }
        var best = a, bestEnergy = Float.greatestFiniteMagnitude
        var i = a
        while i <= b {
            var e: Float = 0
            for k in i..<(i + frame) { e += samples[k] * samples[k] }
            if e < bestEnergy { bestEnergy = e; best = i }
            i += hop
        }
        return Double(best + frame / 2) / rate
    }

    /// Confirmed words → transcript lines, split at sentence ends and pauses.
    nonisolated static func lines(from words: [LiveWord], offset: Double, speaker: String?) -> [Segment] {
        var out: [Segment] = []
        var current: [LiveWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            if !text.isEmpty, !Engine.hallucinations.contains(text.lowercased()) {
                out.append(Segment(start: offset + first.start, end: offset + last.end, text: text, speaker: speaker))
            }
            current = []
        }
        for w in words {
            if let last = current.last, w.start - last.end > 1.0 { flush() }
            current.append(w)
            let t = w.text.trimmingCharacters(in: .whitespaces)
            if t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") { flush() }
        }
        flush()
        return out
    }
}

/// Reads the 16-bit mono WAV a SampleSink is still writing (header sizes are stale until close).
enum WAVReader {
    static func readMonoPCM16(_ url: URL) -> [Float]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count > 44 else { return nil }
        var i = 12
        while i + 8 <= data.count {
            let id = String(decoding: data[i..<i + 4], as: UTF8.self)
            let size = Int(data[i + 4]) | Int(data[i + 5]) << 8 | Int(data[i + 6]) << 16 | Int(data[i + 7]) << 24
            if id == "data" {
                let body = data[(i + 8)...]
                let n = body.count / 2
                var out = [Float](repeating: 0, count: n)
                body.withUnsafeBytes { raw in
                    let p = raw.bindMemory(to: Int16.self)
                    for k in 0..<n { out[k] = Float(Int16(littleEndian: p[k])) / 32768 }
                }
                return out
            }
            i += 8 + size + (size & 1)
        }
        return nil
    }

    /// Seconds of 16-bit mono audio, from the file size past the data chunk header (no decoding).
    static func duration(_ url: URL) -> Double? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4096), head.count > 12, let size = try? h.seekToEnd() else { return nil }
        let bytes = [UInt8](head)
        var i = 12
        while i + 8 <= bytes.count {
            let id = String(decoding: bytes[i..<i + 4], as: UTF8.self)
            let chunk = Int(bytes[i + 4]) | Int(bytes[i + 5]) << 8 | Int(bytes[i + 6]) << 16 | Int(bytes[i + 7]) << 24
            if id == "data" { return Double(max(0, Int(size) - i - 8) / 2) / SampleSink.rate }
            i += 8 + chunk + (chunk & 1)
        }
        return nil
    }
}

enum LiveDebug {
    static let enabled = UserDefaults.standard.bool(forKey: "liveDebug")
    static let url = Paths.support.appendingPathComponent("live-debug.log")
    static func log(_ line: String) {
        guard enabled else { return }
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? data.write(to: url) }
    }
}

/// Respect mute's gate on the mic track, from the observer's thread. Closed until the first read of your mute state;
/// open again if none comes within the timeout, so a page that can't be read doesn't silence you for good.
private final class MuteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var known = false
    private let sink: SampleSink?

    init(_ sink: SampleSink?) { self.sink = sink }

    func set(_ muted: Bool) { lock.withLock { known = true; sink?.gate(muted: muted) } }

    func closeUntilRead(seconds: Double) {
        guard sink != nil else { return }
        lock.withLock { if !known { sink?.gate(muted: true) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in
            lock.withLock { if !known { known = true; sink?.gate(muted: false) } }
        }
    }
}

/// Energy voice-activity detector (0.1 s frames, RMS threshold 0.02).
struct EnergyVAD {
    let frameLength: Double
    let threshold: Float

    func voiceActivity(in samples: [Float]) -> [Bool] {
        let n = Int(frameLength * SampleSink.rate)
        guard n > 0 else { return [] }
        return stride(from: 0, to: samples.count, by: n).map { start in
            let end = min(start + n, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            return (sum / Float(max(1, end - start))).squareRoot() > threshold
        }
    }
}
