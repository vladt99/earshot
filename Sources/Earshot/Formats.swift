import Foundation

enum Formats {
    static let all = ["json", "text", "txt", "srt", "vtt", "verbose_json"]

    static func render(_ t: Transcript, as format: String) -> HTTPResponse {
        switch format {
        case "text", "txt": return .text(t.text)
        case "srt": return .text(srt(t), contentType: "application/x-subrip; charset=utf-8")
        case "vtt": return .text(vtt(t), contentType: "text/vtt; charset=utf-8")
        case "json": return .json(["text": t.text])
        default: return .json(verbose(t))
        }
    }

    /// OpenAI `verbose_json` shape plus our own fields (id, model, title, …).
    static func verbose(_ t: Transcript) -> [String: Any] {
        var d: [String: Any] = [
            "id": t.id,
            "task": "transcribe",
            "text": t.text,
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
        return d
    }

    static func note(_ n: Note) -> [String: Any] {
        ["id": n.id, "time": num(n.time), "kind": n.kind, "text": n.text]
    }

    /// Meeting notes as Markdown for a notes app (Obsidian, Bear…): front matter, bookmarks and notes, then the
    /// transcript as speaker paragraphs with timestamps.
    static func markdown(_ t: Transcript) -> String {
        let speakers = Array(Set(t.segments.compactMap(\.speaker))).sorted()
        var out = "---\n"
        out += "title: \"\(t.title.replacingOccurrences(of: "\"", with: "'"))\"\n"
        out += "date: \(iso(t.createdAt))\n"
        if let d = t.duration { out += "duration: \(clock(d))\n" }
        if !speakers.isEmpty { out += "participants: [\(speakers.map { "\"\($0)\"" }.joined(separator: ", "))]\n" }
        out += "source: earshot\nid: \(t.id)\n---\n\n# \(t.title)\n\n"
        let notes = (t.notes ?? []).sorted { $0.time < $1.time }
        if !notes.isEmpty {
            out += "## Notes\n\n" + notes.map { "- **\(clock($0.time))** \($0.kind == "bookmark" ? "🔖 " : "")\($0.text)" }.joined(separator: "\n") + "\n\n"
        }
        out += "## Transcript\n\n"
        var paragraphs: [(String?, Double, String)] = []
        for s in t.segments {
            if let last = paragraphs.last, last.0 == s.speaker, s.start - last.1 < 120 { paragraphs[paragraphs.count - 1].2 += " " + s.text }
            else { paragraphs.append((s.speaker, s.start, s.text)) }
        }
        out += paragraphs.map { who, start, text in "**\(clock(start))**\(who.map { " **\($0):**" } ?? "") \(text)" }.joined(separator: "\n\n")
        return out + "\n"
    }

    /// 0:42, 12:03, 1:02:09
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
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
        return d
    }

    /// "Me: …\nSpeaker 1: …" with consecutive lines of the same speaker merged.
    static func speakerText(_ segments: [Segment]) -> String {
        guard segments.contains(where: { $0.speaker != nil }) else { return segments.map(\.text).joined(separator: " ") }
        var out: [(String, String)] = []
        for s in segments {
            let who = s.speaker ?? "Unknown"
            if let last = out.last, last.0 == who { out[out.count - 1].1 += " " + s.text } else { out.append((who, s.text)) }
        }
        return out.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    private static func label(_ s: Segment) -> String { s.speaker.map { "\($0): \(s.text)" } ?? s.text }

    static func srt(_ t: Transcript) -> String {
        t.segments.enumerated().map { i, s in
            "\(i + 1)\n\(stamp(s.start, sep: ",")) --> \(stamp(s.end, sep: ","))\n\(label(s))\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ t: Transcript) -> String {
        "WEBVTT\n\n" + t.segments.map { s in
            "\(stamp(s.start, sep: ".")) --> \(stamp(s.end, sep: "."))\n\(s.speaker.map { "<v \($0)>" } ?? "")\(s.text)\n"
        }.joined(separator: "\n")
    }

    static func stamp(_ seconds: Double, sep: String) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60000) % 60, (ms / 1000) % 60, sep, ms % 1000)
    }

    /// Two-decimal number that serializes as 4.58, not 4.5800000000000001.
    static func num(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.2f", x)) }

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }
}
