import AppKit
import Carbon.HIToolbox
import Foundation

/// "This person was speaking at `time`" (seconds on the meeting-audio clock), read from Meet's captions.
struct SpeakerHint: Codable, Sendable {
    var time: Double
    var name: String
}

/// meeting.json in every meeting folder, written while recording. If Earshot quits mid-meeting, the next
/// launch finds `saved == false` and transcribes what was recorded.
struct MeetingManifest: Codable {
    var id: String
    var title: String
    var appName: String
    var appBundle: String?
    var platform: String
    var origin: String
    var startedAt: Date
    var captureMic: Bool
    var language: String?
    var notes: [Note] = []
    var speakerHints: [SpeakerHint] = []
    var saved = false

    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("meeting.json") }

    func write(to folder: URL) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Self.url(folder), options: .atomic)
    }

    static func read(_ folder: URL) -> MeetingManifest? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url(folder))).flatMap { try? d.decode(MeetingManifest.self, from: $0) }
    }

    static func markSaved(_ folder: URL) {
        guard var m = read(folder) else { return }
        m.saved = true
        m.write(to: folder)
    }
}

/// speakers.json: speaker label → voice embedding for one meeting, so naming a speaker later teaches Earshot
/// that person's voice.
enum MeetingVoices {
    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("speakers.json") }

    static func read(_ folder: URL) -> [String: [Float]] {
        (try? Data(contentsOf: url(folder))).flatMap { try? JSONDecoder().decode([String: [Float]].self, from: $0) } ?? [:]
    }

    static func write(_ voices: [String: [Float]], to folder: URL) {
        try? JSONEncoder().encode(voices).write(to: url(folder), options: .atomic)
    }

    /// A speaker was renamed in the editor: remember the voice under the new name.
    static func renamed(in folder: URL, from old: String, to new: String) {
        var voices = read(folder)
        guard let voice = voices.removeValue(forKey: old) else { return }
        voices[new] = voice
        write(voices, to: folder)
        if Settings.rememberVoices { Store.shared.learnVoice(new, voice) }
    }
}

/// Turns speaker clusters ("Speaker 1") into names.
enum SpeakerNaming {
    /// Meet captions name whoever is talking; a caption appears ~0.3–3 s after the words. Each hint votes for the
    /// speaker whose turns overlap that window; a speaker gets a name with ≥ 2 s of votes and ≥ 60 % of its votes.
    static func fromHints(turns: [(start: Double, end: Double, speaker: String)], hints: [SpeakerHint]) -> [String: String] {
        var votes: [String: [String: Double]] = [:]
        for h in hints {
            let a = h.time - 3.0, b = h.time - 0.2
            for t in turns {
                let o = min(t.end, b) - max(t.start, a)
                if o > 0 { votes[t.speaker, default: [:]][h.name, default: 0] += o }
            }
        }
        let candidates = votes.flatMap { speaker, byName -> [(String, String, Double)] in
            let total = byName.values.reduce(0, +)
            return byName.filter { $0.value >= 2 && $0.value / total >= 0.6 }.map { (speaker, $0.key, $0.value) }
        }
        return assignUnique(candidates)
    }

    /// Saved voices: cosine similarity ≥ 0.7 and clearly better (by 0.08) than the next person.
    static func fromVoices(_ voices: [String: [Float]], known: [String: [Float]], taken: Set<String>) -> [String: String] {
        var candidates: [(String, String, Double)] = []
        for (speaker, v) in voices {
            let scored = known.filter { !taken.contains($0.key) }.map { ($0.key, cosine(v, $0.value)) }.sorted { $0.1 > $1.1 }
            guard let best = scored.first, best.1 >= 0.7, best.1 - (scored.dropFirst().first?.1 ?? 0) >= 0.08 else { continue }
            candidates.append((speaker, best.0, best.1))
        }
        return assignUnique(candidates)
    }

    /// Strongest pairs first; each speaker and each name used once.
    private static func assignUnique(_ candidates: [(speaker: String, name: String, score: Double)]) -> [String: String] {
        var out: [String: String] = [:]
        var used = Set<String>()
        for c in candidates.sorted(by: { $0.score > $1.score }) where out[c.speaker] == nil && !used.contains(c.name) {
            out[c.speaker] = c.name
            used.insert(c.name)
        }
        return out
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return na > 0 && nb > 0 ? Double(dot / (na.squareRoot() * nb.squareRoot())) : 0
    }
}

/// Meetings whose recording never reached the library (Earshot quit, crashed or lost power mid-call).
enum MeetingRecovery {
    @MainActor
    static func run() async {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Paths.meetings, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            guard let m = MeetingManifest.read(folder), !m.saved, Store.shared.get(m.id) == nil,
                  MeetingController.shared.session?.folder != folder else { continue }
            let tracks = ["others.wav", "me.wav"].map { folder.appendingPathComponent($0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            tracks.forEach(WAVRepair.fix)
            let seconds = tracks.compactMap { WAVReader.readMonoPCM16($0) }.map { Double($0.count) / SampleSink.rate }.max() ?? 0
            guard seconds >= 1 else { continue }
            let t = Transcript(id: m.id, createdAt: m.startedAt, title: m.title, sourcePath: folder.path, origin: m.origin,
                               model: Engine.modelID, language: m.language, duration: seconds, processingSeconds: 0,
                               text: "", segments: [], notes: m.notes.isEmpty ? nil : m.notes)
            Store.shared.insert(t)
            AppState.shared.didSave(t)
            MeetingManifest.markSaved(folder)
            Notifier.post("Recovering \(m.title)", body: "Earshot stopped during this meeting. Transcribing what was recorded…")
            EventBus.shared.publish("meeting.recovered", ["meeting_id": m.id, "title": m.title, "duration": Formats.num(seconds)])
            if let final = try? await MeetingController.shared.retranscribe(m.id) { MeetingController.shared.finalize(final) }
        }
    }
}

/// A WAV whose writer never closed has zero/stale sizes in its header; patch them to the real file length.
enum WAVRepair {
    static func fix(_ url: URL) {
        guard let h = try? FileHandle(forUpdating: url), let data = try? h.read(upToCount: 4096), data.count > 12 else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var i = 12
        while i + 8 <= data.count {
            let id = String(decoding: data[i..<i + 4], as: UTF8.self)
            let chunk = data[i + 4..<i + 8].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            if id == "data" {
                let dataSize = UInt32(clamping: Int(size) - i - 8)
                guard chunk != Int(dataSize) else { return }
                write(h, at: 4, UInt32(clamping: Int(size) - 8))
                write(h, at: UInt64(i + 4), dataSize)
                return
            }
            i += 8 + chunk + (chunk & 1)
        }
    }

    private static func write(_ h: FileHandle, at offset: UInt64, _ value: UInt32) {
        var le = value.littleEndian
        try? h.seek(toOffset: offset)
        h.write(Data(bytes: &le, count: 4))
    }
}

/// ⌃⌘B from any app: bookmark the running meeting.
@MainActor
final class BookmarkHotkey {
    static let shared = BookmarkHotkey()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func update() {
        Settings.bookmarkHotkey ? install() : uninstall()
    }

    private func install() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        if handler == nil {
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                Task { @MainActor in MeetingController.shared.addNote(nil, kind: "bookmark") }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5357_4842), id: 1) // 'SWHB'
        RegisterEventHotKey(UInt32(kVK_ANSI_B), UInt32(cmdKey | controlKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    private func uninstall() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }
}
