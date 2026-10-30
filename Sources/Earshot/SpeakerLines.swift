import Foundation
import os

/// One person's lines across the library (`GET /v1/speakers/{name}/lines`) and every named speaker (`GET /v1/speakers`).
/// Names match case- and diacritic-insensitively, and through the meeting's participants: "Ana" finds the label
/// "Ana Pop" when Ana Pop was in the call, an email finds that participant's lines, and you are your own label.
enum SpeakerLines {
    static func fold(_ s: String) -> String {
        SpeakerPicker.key(s).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The speaker labels in `t` that are the person `name`.
    static func labels(for name: String, in t: Transcript) -> Set<String> {
        let q = fold(name)
        guard !q.isEmpty else { return [] }
        let all = Set(t.segments.compactMap(\.speaker))
        var keys: Set<String> = [q]
        for p in t.context?.participants ?? [] where !p.bot && !p.presentation {
            let pk = fold(p.name)
            guard !pk.isEmpty else { continue }
            let first = pk.split(separator: " ").first.map(String.init) ?? pk
            guard pk == q || p.email.map(fold) == q || pk.hasPrefix(q + " ") || q.hasPrefix(pk + " ") else { continue }
            keys.insert(pk)
            if first != pk, !all.contains(where: { fold($0) == pk }) { keys.insert(first) }
            if p.isSelf { keys.insert(fold(Settings.myName)) }
        }
        return all.filter { keys.contains(fold($0)) }
    }

    /// Newest first. `since` limits to transcripts created then or later; `query` keeps lines containing every word.
    /// `meetings` counts every meeting with a matching line, so the library is read past `limit` (only the transcripts
    /// with speakers, since `since`, of `origin`).
    static func lines(_ name: String, limit: Int = 50, since: Date? = nil, origin: String? = nil, query: String? = nil) -> (lines: [[String: Any]], meetings: Int) {
        let words = (query ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        var found: [(Double, [String: Any])] = []
        var meetings = Set<String>()
        for t in Store.shared.withSpeakers(since: since, origin: origin) {
            let labels = labels(for: name, in: t)
            guard !labels.isEmpty else { continue }
            for s in t.segments {
                guard let who = s.speaker, labels.contains(who),
                      words.allSatisfy({ s.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) else { continue }
                meetings.insert(t.id)
                found.append((t.createdAt.timeIntervalSince1970 + s.start, [
                    "meeting_id": t.id, "title": t.title, "date": Formats.iso(t.createdAt), "origin": t.origin, "speaker": who,
                    "start": Formats.num(s.start), "end": Formats.num(s.end), "text": s.text,
                ]))
            }
        }
        let n = max(1, min(limit, 1000))
        return (found.sorted { $0.0 > $1.0 }.prefix(n).map(\.1), meetings.count)
    }

    private struct Entry: Sendable { var name: String; var meetings = 0; var lines = 0; var last = Date.distantPast }
    private static let cache = OSAllocatedUnfairLock<(generation: Int, entries: [Entry])?>(initialState: nil)

    /// Every named speaker (not "Speaker 2" or the shared participants label): meetings, lines and when last heard.
    /// Without filters it's cached until the library changes.
    static func all(since: Date? = nil, origin: String? = nil) -> [[String: Any]] {
        let generation = Store.shared.generation
        let cached = since == nil && origin == nil ? cache.withLock { $0?.generation == generation ? $0?.entries : nil } : nil
        let entries = cached ?? summarize(Store.shared.withSpeakers(since: since, origin: origin))
        if cached == nil, since == nil, origin == nil { cache.withLock { $0 = (generation, entries) } }
        return entries.map { ["name": $0.name, "meetings": $0.meetings, "lines": $0.lines, "last_seen": Formats.iso($0.last)] }
    }

    private static func summarize(_ transcripts: [Transcript]) -> [Entry] {
        var byKey: [String: Entry] = [:]
        for t in transcripts {
            var counts: [String: (String, Int)] = [:]
            for s in t.segments {
                guard let who = s.speaker, Formats.linkable(who) else { continue }
                let k = fold(who)
                counts[k] = (who, (counts[k]?.1 ?? 0) + 1)
            }
            for (k, (who, n)) in counts {
                var e = byKey[k] ?? Entry(name: who)
                e.meetings += 1
                e.lines += n
                // The list is newest first, so the first spelling seen is the newest.
                e.last = max(e.last, t.createdAt)
                byKey[k] = e
            }
        }
        return byKey.values.sorted { $0.meetings != $1.meetings ? $0.meetings > $1.meetings : $0.name < $1.name }
    }

    /// "2026-10-01" or a full ISO 8601 date.
    static func date(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
