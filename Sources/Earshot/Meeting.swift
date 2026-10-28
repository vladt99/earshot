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
}

/// Starts/stops meeting sessions from detection, UI or API.
@MainActor
final class MeetingController {
    static let shared = MeetingController()

    private(set) var session: MeetingSession?
    private var startedFromDetection: String?
    private var dismissTask: Task<Void, Never>?
    private var stopCountdown: Task<Void, Never>?

    func meetingDetected(_ m: DetectedMeeting) {
        guard session == nil else { return }
        switch Settings.meetingMode {
        case "auto":
            _ = try? start(app: m.appBundleID, title: m.title, platform: m.platform, appName: m.appName, mic: true, fromDetection: m.key)
            Notifier.post("Transcribing \(m.title)", body: "\(m.appName) is using the microphone. Live transcript is running.")
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
                    MeetingPanel.shared.hide()
                }
            }
        default:
            break
        }
    }

    /// "Stop recording 10 seconds after a meeting ends. Dismiss the alert to keep recording."
    func detectedMeetingEnded(_ m: DetectedMeeting) {
        guard session != nil, startedFromDetection == m.key, Settings.autoStopAfterMeeting else { return }
        AppState.shared.stoppingAt = Date().addingTimeInterval(10)
        MeetingPanel.shared.show()
        stopCountdown?.cancel()
        stopCountdown = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, AppState.shared.stoppingAt != nil else { return }
            _ = await self.stop()
        }
    }

    func keepRecording() {
        stopCountdown?.cancel()
        AppState.shared.stoppingAt = nil
        startedFromDetection = nil
    }

    /// `app`: bundle id to capture ("com.google.Chrome"), or nil/"system" for all system audio.
    @discardableResult
    func start(app: String?, title: String?, platform: String? = nil, appName: String? = nil,
               mic: Bool = true, fromDetection: String? = nil, origin: String = "meeting", save: Bool = true) throws -> MeetingSnapshot {
        if let session { return session.snapshot }
        dismissTask?.cancel()
        let detected = MeetingDetector.shared.current
        let bundle = (app == "system") ? nil : (app ?? detected?.appBundleID)
        let name = appName ?? bundle.map { MeetingDetector.meeting(for: $0).appName } ?? "System audio"
        let s = MeetingSession(
            appBundle: bundle,
            appName: name,
            platform: platform ?? name,
            title: title ?? CalendarLookup.currentEventTitle()
                ?? (bundle == nil ? "Meeting \(Date().formatted(date: .abbreviated, time: .shortened))" : "\(name) meeting"),
            captureMic: mic,
            origin: origin,
            save: save
        )
        try s.start()
        session = s
        startedFromDetection = fromDetection ?? (detected?.key == bundle ? bundle : nil)
        AppState.shared.meeting = s.snapshot
        AppState.shared.detectedMeeting = nil
        AppState.shared.stoppingAt = nil
        MeetingPanel.shared.show()
        EventBus.shared.publish("meeting.started", Self.payload(s.snapshot))
        return s.snapshot
    }

    /// Stops capture, flushes both streams, settles speakers and saves (MeetingRecordingFinalizer: no automatic
    /// re-transcription — the live transcript is the result; re-transcribing is a separate, manual action).
    func stop() async -> Transcript? {
        guard let s = session else { return nil }
        session = nil
        startedFromDetection = nil
        stopCountdown?.cancel()
        AppState.shared.stoppingAt = nil
        let transcript = PostProcess.apply(await s.stop())
        AppState.shared.meeting = nil
        guard s.save else {
            try? FileManager.default.removeItem(at: s.folder)
            return transcript
        }
        guard !transcript.segments.isEmpty || FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("others.wav").path) else { return nil }
        Store.shared.insert(transcript)
        AppState.shared.didSave(transcript)
        MeetingManifest.markSaved(s.folder)
        EventBus.shared.publish("meeting.saved", ["meeting_id": transcript.id, "transcript_id": transcript.id, "title": transcript.title,
                                                  "polishing": Settings.polishAfterMeeting])
        if Settings.polishAfterMeeting {
            // The live text is saved; replace it with one clean pass over both recordings.
            Task { @MainActor in
                let final = (try? await self.retranscribe(transcript.id)) ?? transcript
                self.finalize(final)
            }
        } else {
            finalize(transcript)
        }
        return transcript
    }

    /// The meeting's transcript is final: export, webhook/SSE `meeting.finalized`, notification.
    func finalize(_ t: Transcript) {
        PostProcess.finished(t)
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
        guard var t = Store.shared.get(id), ["meeting", "podcast", "appaudio"].contains(t.origin), let folder = t.sourcePath.map(URL.init(fileURLWithPath:)) else {
            throw APIError(404, "No such meeting")
        }
        let others = folder.appendingPathComponent("others.wav"), me = folder.appendingPathComponent("me.wav")
        let fm = FileManager.default
        guard fm.fileExists(atPath: others.path) || fm.fileExists(atPath: me.path) else {
            throw APIError(409, "A meeting needs at least one recorded stream to transcribe")
        }
        AppState.shared.polishing.insert(id)
        defer { AppState.shared.polishing.remove(id) }
        EventBus.shared.publish("meeting.polishing", ["meeting_id": id, "transcript_id": id])
        let started = Date()
        let manifest = MeetingManifest.read(folder)
        let options = TranscribeOptions(model: nil, language: t.language, diarize: Settings.diarizeMeetings)
        var segments: [Segment] = []
        var model = t.model
        if fm.fileExists(atPath: others.path), let samples = WAVReader.readMonoPCM16(others) ?? (try? AudioPrep.loadSamples(others)) {
            let out = try await Engine.shared.transcribe(samples: samples, options: options, speakerPrefix: "Speaker")
            model = out.model
            var appSegments = out.segments.map { var s = $0; s.speaker = s.speaker ?? Settings.participantsName; return s }
            let names = Self.names(for: appSegments, voices: out.voices, hints: manifest?.speakerHints ?? [])
            appSegments = appSegments.map { var s = $0; if let n = s.speaker.flatMap({ names[$0] }) { s.speaker = n }; return s }
            var voices: [String: [Float]] = [:]
            for (label, v) in out.voices { voices[names[label] ?? label] = v }
            MeetingVoices.write(voices, to: folder)
            segments += appSegments
        }
        if fm.fileExists(atPath: me.path), let samples = WAVReader.readMonoPCM16(me) ?? (try? AudioPrep.loadSamples(me)) {
            var meOptions = options
            meOptions.diarize = false
            let out = try await Engine.shared.transcribe(samples: samples, options: meOptions)
            segments += out.segments.map { var s = $0; s.speaker = Settings.myName; return s }
        }
        segments.sort { $0.start < $1.start }
        t.segments = segments
        t.text = Formats.speakerText(segments)
        t.model = model
        t.notes = t.notes ?? manifest.flatMap { $0.notes.isEmpty ? nil : $0.notes }
        t.processingSeconds = Date().timeIntervalSince(started)
        t = PostProcess.apply(t)
        Store.shared.insert(t)
        AppState.shared.didSave(t)
        AppState.shared.reloadLibrary()
        EventBus.shared.publish("meeting.retranscribed", ["meeting_id": id, "transcript_id": id])
        return t
    }

    /// "Speaker N" → person: Meet captions first (they name whoever talks), then saved voices. Names learned from
    /// captions are remembered as voices and added to People.
    static func names(for segments: [Segment], voices: [String: [Float]], hints: [SpeakerHint]) -> [String: String] {
        guard Settings.autoNameSpeakers else { return [:] }
        let turns = segments.compactMap { s in s.speaker.map { (start: s.start, end: s.end, speaker: $0) } }
        var names = SpeakerNaming.fromHints(turns: turns, hints: hints)
        if Settings.rememberVoices {
            for (label, name) in names { if let v = voices[label] { Store.shared.learnVoice(name, v) } }
            let unnamed = voices.filter { names[$0.key] == nil }
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
    let id = UUID().uuidString.lowercased()
    let appBundle: String?
    let appName: String
    let platform: String
    let title: String
    let startedAt = Date()
    let folder: URL
    let captureMic: Bool
    let origin: String
    let save: Bool

    private let othersSink: SampleSink
    private let micSink: SampleSink?
    private let tapGaps = GapFiller()
    private let tap: ProcessTapCapture
    private let mic: MicCapture?
    private var streams: [LiveStream] = []
    private var diarizeTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var captions: MeetCaptionWatcher?
    private(set) var notes: [Note] = []
    private var hints: [SpeakerHint] = []
    private var hintsWritten = 0
    private var warning: String?
    private var warned: Set<String> = []
    /// Diarizer speaker id → person, from captions and saved voices.
    private var speakerNames: [String: String] = [:]
    private var sleepObservers: [NSObjectProtocol] = []
    private(set) var lines: [Segment] = []
    private var hypotheses: [String: String] = [:]
    fileprivate var language: String? = Settings.language
    /// Diarizer speaker id → stable "Speaker N" label, numbered by first appearance.
    private var speakerNumbers: [String: Int] = [:]

    init(appBundle: String?, appName: String, platform: String, title: String, captureMic: Bool, origin: String = "meeting", save: Bool = true) {
        self.origin = origin
        self.save = save
        self.appBundle = appBundle
        self.appName = appName
        self.platform = platform
        self.title = title
        self.captureMic = captureMic
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        let safe = title.replacingOccurrences(of: "/", with: "-").prefix(60)
        folder = Paths.dir(Paths.meetings.appendingPathComponent("\(f.string(from: startedAt)) \(safe)", isDirectory: true))
        othersSink = SampleSink(fileURL: folder.appendingPathComponent("others.wav"))
        micSink = captureMic ? SampleSink(fileURL: folder.appendingPathComponent("me.wav")) : nil
        tap = ProcessTapCapture(mode: appBundle.map { .apps([$0]) } ?? .allSystemAudio, sink: othersSink, gapFiller: tapGaps)
        mic = micSink.map { MicCapture(sink: $0, echoCancellation: Settings.echoCancellation) }
    }

    private var manifest: MeetingManifest {
        MeetingManifest(id: id, title: title, appName: appName, appBundle: appBundle, platform: platform, origin: origin,
                        startedAt: startedAt, captureMic: captureMic, language: language, notes: notes, speakerHints: hints)
    }

    /// Current point of the meeting on the transcript's clock (the meeting-audio track).
    private var now: Double { Double(othersSink.total) / SampleSink.rate }

    func addNote(_ text: String?, kind: String) -> Note {
        let clean = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = Note(time: now, text: clean.isEmpty ? "Bookmark" : clean, kind: kind)
        notes.append(note)
        if save { manifest.write(to: folder) }
        AppState.shared.meeting = snapshot
        EventBus.shared.publish("meeting.note", ["meeting_id": id, "kind": kind, "time": Formats.num(note.time), "text": note.text])
        return note
    }

    var snapshot: MeetingSnapshot {
        MeetingSnapshot(id: id, title: title, platform: platform, appName: appName, startedAt: startedAt,
                        lines: lines, hypotheses: hypotheses, capturingMic: micSink != nil,
                        notes: notes, warning: warning, readingCaptions: captions?.active ?? false)
    }

    var othersLabel: String { Settings.participantsName }

    func start() throws {
        try tap.start()
        if let mic {
            do { try mic.start() } catch { tap.stop(); throw error }
        }
        streams = [LiveStream(id: "app", speaker: othersLabel, sink: othersSink, session: self)]
        if let micSink { streams.append(LiveStream(id: "mic", speaker: Settings.myName, sink: micSink, session: self)) }
        streams.forEach { $0.start() }
        if Settings.diarizeMeetings { scheduleDiarization() }
        if save { manifest.write(to: folder) }
        startCaptions()
        watch()

        // Sleep: capture pauses and the asleep period is cut from recording and transcript.
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.tapGaps.cut()
                self?.mic?.cutTimeline()
                EventBus.shared.publish("meeting.resumed_after_sleep", ["meeting_id": self?.id ?? ""])
            }
        })
    }

    func stop() async -> Transcript {
        diarizeTask?.cancel()
        watchTask?.cancel()
        captions?.stop()
        sleepObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tap.stop()
        mic?.stop()
        for s in streams { await s.finish() }
        othersSink.close()
        micSink?.close()
        hypotheses = [:]
        if Settings.diarizeMeetings { await diarizeNow() }
        lines.sort { $0.start < $1.start }
        return Transcript(
            id: id, createdAt: startedAt, title: title, sourcePath: folder.path, origin: origin,
            model: Engine.modelID, language: language,
            duration: Date().timeIntervalSince(startedAt), processingSeconds: 0,
            text: Formats.speakerText(lines), segments: lines, notes: notes.isEmpty ? nil : notes
        )
    }

    // MARK: Speaker names from Meet captions

    private func startCaptions() {
        guard Settings.autoNameSpeakers, let appBundle, MeetingApp.browsers.contains(appBundle) else { return }
        MeetCaptionWatcher.requestTrust()
        captions = MeetCaptionWatcher(bundleID: appBundle) { [weak self] name in
            Task { @MainActor in
                guard let self else { return }
                self.hints.append(SpeakerHint(time: self.now, name: name))
            }
        }
        captions?.start()
    }

    // MARK: Watchdog: stalled capture, silent tracks, periodic manifest

    private func watch() {
        watchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.checkAudio()
                if self.save, self.hints.count != self.hintsWritten {
                    self.hintsWritten = self.hints.count
                    self.manifest.write(to: self.folder)
                }
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
        let readingCaptions = captions?.active ?? false
        guard message != warning || readingCaptions != snapshotCaptions else { return }
        snapshotCaptions = readingCaptions
        if message != warning {
            warning = message
            if let kind, let message {
                EventBus.shared.publish("meeting.warning", ["meeting_id": id, "kind": kind, "message": message])
                if warned.insert(kind).inserted { Notifier.post("Check your meeting audio", body: message) }
            }
        }
        AppState.shared.meeting = snapshot
    }

    private var snapshotCaptions = false

    // MARK: Stream callbacks

    fileprivate func confirmed(_ line: Segment, stream: LiveStream) {
        var line = line
        if stream.id == "app", let label = speakerLabel(at: line) { line.speaker = label }
        lines.append(line)
        EventBus.shared.publish("meeting.segment", ["meeting_id": id, "stream": stream.id, "speaker": line.speaker ?? "",
                                                    "start": Formats.num(line.start), "end": Formats.num(line.end), "text": line.text])
        AppState.shared.meeting = snapshot
    }

    fileprivate func hypothesis(_ text: String, stream: LiveStream) {
        guard hypotheses[stream.speaker, default: ""] != text else { return }
        hypotheses[stream.speaker] = text
        AppState.shared.meeting = snapshot
        EventBus.shared.publish("meeting.partial", ["meeting_id": id, "stream": stream.id, "speaker": stream.speaker, "text": text])
    }

    // MARK: Live speaker labels: pyannote over the app recording so far, re-run as it grows, revising
    // lines already on screen.

    private var turns: [(start: Double, end: Double, speaker: String)] = []

    private func scheduleDiarization() {
        diarizeTask = Task { @MainActor [weak self] in
            var lastSeconds = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self else { return }
                let seconds = Double(self.othersSink.total) / SampleSink.rate
                if seconds - lastSeconds >= 20, self.lines.contains(where: { $0.speaker != Settings.myName }) {
                    lastSeconds = seconds
                    await self.diarizeNow()
                }
            }
        }
    }

    private func diarizeNow() async {
        guard let samples = WAVReader.readMonoPCM16(othersSink.fileURL), samples.count > Int(SampleSink.rate * 2),
              let result = try? await Engine.shared.diarizeDetailed(samples: samples) else { return }
        turns = result.turns
        if Settings.autoNameSpeakers {
            var names = SpeakerNaming.fromHints(turns: result.turns, hints: hints)
            if Settings.rememberVoices {
                let unnamed = result.embeddings.filter { names[$0.key] == nil }
                names.merge(SpeakerNaming.fromVoices(unnamed, known: Store.shared.voices(), taken: Set(names.values))) { a, _ in a }
            }
            speakerNames = names
        }
        var revised = 0
        for i in lines.indices where lines[i].speaker != Settings.myName {
            if let label = speakerLabel(at: lines[i]), label != lines[i].speaker {
                lines[i].speaker = label
                revised += 1
            }
        }
        if revised > 0 {
            AppState.shared.meeting = snapshot
            EventBus.shared.publish("meeting.speakers_revised", ["meeting_id": id, "revised": revised,
                                                                 "segments": lines.map { ["start": Formats.num($0.start), "end": Formats.num($0.end), "speaker": $0.speaker ?? "", "text": $0.text] }])
        }
    }

    private func speakerLabel(at line: Segment) -> String? {
        var overlap: [String: Double] = [:]
        for t in turns {
            let o = min(t.end, line.end) - max(t.start, line.start)
            if o > 0 { overlap[t.speaker, default: 0] += o }
        }
        guard let best = overlap.max(by: { $0.value < $1.value })?.key else { return nil }
        if let name = speakerNames[best] { return name }
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
@MainActor
final class LiveStream {
    static let transcribeInterval = 0.1
    static let minCommonPrefix = 12
    static let tokenConfirmationsNeeded = 3
    static let usePunctuationRule = true
    static let endpointAfter = 2.0
    static let forcePassAfter = 60.0

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

    func finish() async {
        task?.cancel()
        _ = await task?.value
        await pass(final: true)
        session?.hypothesis("", stream: self)
    }

    private func pass(final: Bool) async {
        let rate = SampleSink.rate
        let total = sink.total
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
        let hasPending = !previous.isEmpty || !openLine.isEmpty
        let endpoint = trailingSilence >= Self.endpointAfter || (!anyVoice && hasPending && seconds >= Self.endpointAfter)
        let force = seconds >= Self.forcePassAfter

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
        guard let result = try? await Engine.shared.transcribeStream(window, language: session?.language) else { return }
        if session?.language == nil, let l = result.language { session?.language = l }

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
        let closing = final || endpoint || force
        if closing {
            confirmCount = words.count
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
                if agreements >= Self.tokenConfirmationsNeeded { confirmCount = common }
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
        } else if seconds > Self.forcePassAfter / 2, confirmCount > 0 {
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
