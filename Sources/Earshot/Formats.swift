import Foundation

enum Formats {
    static let all = ["json", "text", "txt", "srt", "vtt", "verbose_json"]

    static func render(_ t: Transcript, as format: String) -> HTTPResponse {
        switch format {
        case "text", "txt": return .text(text(t))
        case "srt": return .text(srt(t), contentType: "application/x-subrip; charset=utf-8")
        case "vtt": return .text(vtt(t), contentType: "text/vtt; charset=utf-8")
        case "json": return .json(["text": text(t)])
        default: return .json(verbose(t))
        }
    }

    /// OpenAI `verbose_json` shape plus our own fields (id, model, title, …).
    static func verbose(_ t: Transcript) -> [String: Any] {
        var d: [String: Any] = [
            "id": t.id,
            "task": "transcribe",
            "text": text(t),
            "title": t.title,
            "model": t.model,
            "origin": t.origin,
            "created_at": iso(t.createdAt),
            "processing_seconds": num(t.processingSeconds),
            "segments": t.segments.enumerated().map { i, s in
                var d: [String: Any] = ["id": i, "start": num(s.start), "end": num(s.end), "text": s.text]
                d["speaker"] = s.speaker
                return d
            },
            "speakers": Array(Set(t.segments.compactMap(\.speaker))).sorted(),
        ]
        d["language"] = t.language
        d["duration"] = t.duration.map(num)
        d["source_path"] = t.sourcePath
        d["notes"] = (t.notes ?? []).map(note)
        d["context"] = t.context.map { context($0) }
        return d
    }

    /// The transcript as speaker paragraphs (stored `text` for transcripts without segments).
    static func text(_ t: Transcript) -> String { t.segments.isEmpty ? t.text : speakerText(t.segments) }

    /// A meeting's room, calendar event, participants and events in snake_case. Caption turns are left out
    /// (`captions: true` adds them): they are only used to name speakers.
    static func context(_ c: MeetingContext, captions: Bool = false) -> [String: Any] {
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(c), var d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        if !captions { d.removeValue(forKey: "captions") }
        d["platform_name"] = platformName(c.platform)
        return d
    }

    static func platformName(_ p: String?) -> String? {
        guard let p, !p.isEmpty else { return nil }
        return ["meet": "Google Meet", "google meet": "Google Meet", "zoom": "Zoom", "teams": "Microsoft Teams", "webex": "Webex",
                "slack": "Slack", "facetime": "FaceTime"][p.lowercased()] ?? p
    }

    /// People shown in the call: everyone but presentation tiles.
    static func people(_ c: MeetingContext?) -> [MeetingParticipant] { (c?.participants ?? []).filter { !$0.presentation } }

    /// "Ana, Bob (guest), Fathom Notetaker (bot)"
    static func peopleLine(_ c: MeetingContext?) -> String {
        people(c).map { $0.name + ($0.bot ? " (bot)" : $0.external ? " (guest)" : "") }.joined(separator: ", ")
    }

    static func note(_ n: Note) -> [String: Any] {
        ["id": n.id, "time": num(n.time), "kind": n.kind, "text": n.text]
    }

    /// Meeting notes as Markdown for a notes app (Obsidian, Bear…): front matter, bookmarks and notes, then the
    /// transcript as speaker paragraphs with timestamps and the meeting chat in place.
    static func markdown(_ t: Transcript, obsidian: Bool = Settings.obsidianLinks) -> String {
        let speakers = Array(Set(t.segments.compactMap(\.speaker))).sorted()
        let c = t.context, people = people(c)
        // Obsidian: people as [[Name]] links, lists in block style (what its Properties view writes).
        let person: (String) -> String = { obsidian && linkable($0) && $0 != "Me" ? wikilink($0) : $0 }
        let list: ([String]) -> String = { names in
            obsidian ? "\n" + names.map { "  - \(yaml($0))" }.joined(separator: "\n") : " [\(names.map(yaml).joined(separator: ", "))]"
        }
        var out = "---\n"
        out += "title: \(yaml(t.title))\n"
        out += "date: \(iso(t.createdAt))\n"
        if let d = t.duration { out += "duration: \(clock(d))\n" }
        if !people.isEmpty {
            out += "participants:\(list(people.map { $0.bot ? $0.name : person($0.name) }))\n"
            let guests = people.filter { $0.external && !$0.bot }, bots = people.filter(\.bot)
            if !guests.isEmpty { out += "guests:\(list(guests.map { person($0.name) }))\n" }
            if !bots.isEmpty { out += "bots:\(list(bots.map(\.name)))\n" }
            if !speakers.isEmpty { out += "speakers:\(list(speakers.map(person)))\n" }
        } else if !speakers.isEmpty {
            out += "participants:\(list(speakers.map(person)))\n"
        }
        if let p = platformName(c?.platform) { out += "platform: \(yaml(p))\n" }
        if let code = c?.meetingCode { out += "meeting_code: \(yaml(code))\n" }
        if let url = c?.url { out += "meeting_url: \(yaml(url))\n" }
        if let title = c?.calendar?.title { out += "calendar_title: \(yaml(title))\n" }
        if let organizer = c?.calendar?.organizer { out += "organizer: \(yaml(organizer))\n" }
        out += "source: earshot\nid: \(t.id)\n---\n\n# \(t.title)\n\n"
        if let agenda = c?.calendar?.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !agenda.isEmpty {
            out += "## Agenda\n\n\(agenda)\n\n"
        }
        let notes = (t.notes ?? []).sorted { $0.time < $1.time }
        if !notes.isEmpty {
            out += "## Notes\n\n" + notes.map { "- **\(clock($0.time))** \($0.kind == "bookmark" ? "🔖 " : "")\($0.text)" }.joined(separator: "\n") + "\n\n"
        }
        let found = links(c)
        if !found.isEmpty {
            out += "## Links\n\n" + found.map { l in
                let label = l.url.scheme == "mailto" ? "[\(l.label)](\(l.url.absoluteString))" : "<\(l.url.absoluteString)>"
                return "- \(label)\(l.who.map { " — \(person($0))" } ?? ""), \(clock(l.t))"
            }.joined(separator: "\n") + "\n\n"
        }
        out += "## Transcript\n\n"
        let chat = chats(c)
        var blocks: [(Double, String)] = paragraphs(t.segments, breaks: chat.map(\.t)).map { p in
            (t.segments[p[0]].start, "**\(clock(t.segments[p[0]].start))**\(t.segments[p[0]].speaker.map { " **\(person($0)):**" } ?? "") "
                + p.map { t.segments[$0].text }.joined(separator: " "))
        }
        blocks += chat.map { e in (e.t, "> **\(clock(e.t))** 💬 \(e.who.map { "**\(person($0)):** " } ?? "")\(e.text ?? "")") }
        out += blocks.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element.1).joined(separator: "\n\n")
        return out + "\n"
    }

    /// "[[Name]]", without the characters that end or split a wikilink.
    static func wikilink(_ name: String) -> String {
        "[[" + name.filter { !"[]|#^".contains($0) }.trimmingCharacters(in: .whitespaces) + "]]"
    }

    /// Real names only: not "Speaker 2", the shared participants label or "Unknown".
    static func linkable(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && !SpeakerPicker.isUnnamed(n) && n != Settings.participantsName && n != "Unknown"
    }

    struct Link: Hashable {
        var url: URL
        /// The text as written in the chat (the address for an email).
        var label: String
        var who: String?
        var t: Double
    }

    /// Web links and email addresses sent in a meeting's chat, first mention only, in time order.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func links(_ c: MeetingContext?) -> [Link] {
        guard let detector = linkDetector else { return [] }
        var seen = Set<String>(), out: [Link] = []
        for e in chats(c) {
            let text = e.text ?? ""
            for m in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard var url = m.url, let r = Range(m.range, in: text) else { continue }
                var label = String(text[r])
                if url.scheme == "mailto" {
                    label = label.replacingOccurrences(of: "mailto:", with: "", options: [.caseInsensitive, .anchored])
                } else if url.scheme == nil || !["http", "https"].contains(url.scheme!.lowercased()) {
                    guard url.scheme == nil, let web = URL(string: "https://" + label) else { continue }
                    url = web
                }
                guard seen.insert(url.absoluteString.lowercased()).inserted else { continue }
                out.append(Link(url: url, label: label, who: e.who, t: e.t))
            }
        }
        return out
    }

    /// Chat messages of a meeting, in time order.
    static func chats(_ c: MeetingContext?) -> [MeetingEvent] {
        (c?.events ?? []).filter { $0.kind == .chat && !($0.text ?? "").isEmpty }.sorted { $0.t < $1.t }
    }

    /// The TXT export: a short header (title, date, participants) above the speaker paragraphs.
    static func plainText(_ t: Transcript, header: Bool = Settings.txtHeader) -> String {
        let body = paragraphText(t.segments, fallback: t.text)
        guard header else { return body }
        var head = [t.title, t.createdAt.formatted(date: .abbreviated, time: .shortened) + (t.duration.map { " · " + clock($0) } ?? "")]
        let names = peopleLine(t.context)
        if !names.isEmpty {
            head.append("Participants: " + names)
        } else {
            let speakers = Array(Set(t.segments.compactMap(\.speaker))).sorted()
            if !speakers.isEmpty { head.append("Speakers: " + speakers.joined(separator: ", ")) }
        }
        return head.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    /// YAML double-quoted scalar.
    static func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    /// 0:42, 12:03, 1:02:09
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// A list item; `series` (meeting id → series key, from `Series.index`) adds `series_id`.
    static func summary(_ t: Transcript, series: [String: String]) -> [String: Any] {
        var d = summary(t)
        d["series_id"] = series[t.id]
        return d
    }

    static func summary(_ t: Transcript) -> [String: Any] {
        var d: [String: Any] = [
            "id": t.id,
            "title": t.title,
            "model": t.model,
            "origin": t.origin,
            "created_at": iso(t.createdAt),
            "preview": String(t.text.prefix(200)),
        ]
        d["language"] = t.language
        d["duration"] = t.duration
        if let c = t.context {
            d["participants"] = people(c).map(\.name)
            d["meeting_code"] = c.meetingCode
            d["meeting_url"] = c.url
            d["platform"] = platformName(c.platform)
        }
        return d
    }

    /// "Me: …\n\nSpeaker 1: …": one paragraph per speaker turn (see `paragraphs`). Without speakers, the plain
    /// text on one line as before (dictation, OpenAI-style `text`).
    static func speakerText(_ segments: [Segment]) -> String {
        guard segments.contains(where: { $0.speaker != nil }) else { return segments.map(\.text).joined(separator: " ") }
        return paragraphText(segments)
    }

    /// Speaker paragraphs separated by blank lines, "Name: " in front when the transcript has speakers.
    static func paragraphText(_ segments: [Segment], fallback: String = "") -> String {
        guard !segments.isEmpty else { return fallback }
        let named = segments.contains { $0.speaker != nil }
        return paragraphs(segments).map { p in
            let text = p.map { segments[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
            return named ? "\(segments[p[0]].speaker ?? "Unknown"): \(text)" : text
        }.joined(separator: "\n\n")
    }

    /// A pause longer than this starts a new paragraph even for the same speaker.
    static let paragraphPause = 10.0
    /// Past this length a paragraph ends at the next sentence end; `paragraphMax` ends it regardless.
    static let paragraphLength = 120.0
    static let paragraphMax = 180.0

    /// Groups consecutive segments (indices into `segments`) into paragraphs: a new one starts when the speaker
    /// changes, after a pause over 10 s, once a paragraph is ~2 min long and the previous segment ended a
    /// sentence, or at any time in `breaks` (chat messages, notes).
    static func paragraphs(_ segments: [Segment], breaks: [Double] = []) -> [[Int]] {
        paragraphs(Array(segments.indices), breaks: breaks) { segments[$0] }
    }

    static func paragraphs<T>(_ items: [T], breaks: [Double] = [], segment: (T) -> Segment) -> [[T]] {
        let breaks = breaks.sorted()
        var out: [[T]] = []
        var first: Segment?, last: Segment?
        for item in items {
            let s = segment(item)
            if let f = first, let l = last, out.last != nil, l.speaker == s.speaker, s.start - l.end <= paragraphPause,
               !(s.start - f.start >= paragraphLength && endsSentence(l.text)), s.start - f.start < paragraphMax,
               !breaks.contains(where: { $0 > l.start && $0 <= s.start }) {
                out[out.count - 1].append(item)
            } else {
                out.append([item])
                first = s
            }
            last = s
        }
        return out
    }

    static func endsSentence(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’)»")))
        return t.last.map { ".?!…。？！".contains($0) } ?? false
    }

    private static func label(_ s: Segment) -> String { s.speaker.map { "\($0): \(s.text)" } ?? s.text }

    static func srt(_ t: Transcript) -> String {
        t.segments.enumerated().map { i, s in
            "\(i + 1)\n\(stamp(s.start, sep: ",")) --> \(stamp(s.end, sep: ","))\n\(label(s))\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ t: Transcript) -> String {
        "WEBVTT\n\n" + t.segments.map { s in
            "\(stamp(s.start, sep: ".")) --> \(stamp(s.end, sep: "."))\n\(s.speaker.map { "<v \(cue($0))>" } ?? "")\(cue(s.text))\n"
        }.joined(separator: "\n")
    }

    /// WebVTT cue text: `&`, `<` and `>` are markup.
    static func cue(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func stamp(_ seconds: Double, sep: String) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60000) % 60, (ms / 1000) % 60, sep, ms % 1000)
    }

    /// Two-decimal number that serializes as 4.58, not 4.5800000000000001.
    static func num(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", x)) }

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}
