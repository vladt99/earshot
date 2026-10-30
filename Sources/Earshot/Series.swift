import Foundation

/// Meetings of one recurring series: the calendar's series id when there is one, otherwise the title with case,
/// digits and dates stripped ("Weekly Sync 12.03" and "weekly sync" are one series). Two or more make a series.
enum Series {
    /// The calendar series id, or "title:<normalised title>"; nil for titles that normalise to nothing or that Earshot
    /// made up ("Zoom meeting", "Meeting Oct 29, 2026 at 10:00 AM"), which would make one series of unrelated meetings.
    static func key(_ t: Transcript) -> String? {
        if let id = t.context?.calendar?.seriesID?.trimmingCharacters(in: .whitespaces), !id.isEmpty { return id }
        return titleKey(title(t)).map { "title:" + $0 }
    }

    private static func title(_ t: Transcript) -> String { t.context?.calendar?.title ?? t.title }

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
                                 "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec"]
    private static let days = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
                               "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun", "at", "am", "pm"]
    private static let drop = Set(months + days)

    /// The default titles: "<app> meeting" (MeetingController, MeetingDetector), "Meeting <date>" (system audio),
    /// "Live Captions", and Meet's own name.
    private static let generic: Set<String> = Set(
        (["Meeting", "Live Captions", "System audio", "Google Meet", "Meet", "Untitled"]
            + (MeetingApp.known.map(\.name) + ["Google Meet", "Meet", "System audio"]).map { "\($0) meeting" })
            .compactMap(normalized))

    static func isGeneric(_ title: String) -> Bool { normalized(title).map(generic.contains) ?? true }

    private static func normalized(_ title: String) -> String? {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = folded.split { !$0.isLetter }.map(String.init).filter { !drop.contains($0) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    static func titleKey(_ title: String) -> String? {
        guard let k = normalized(title), !generic.contains(k) else { return nil }
        return k
    }

    /// Series of a library, for the API (cached by Store).
    struct Index: Sendable {
        /// Series key → meeting ids, newest first.
        var groups: [String: [String]] = [:]
        /// Meeting id → its series key.
        var byMeeting: [String: String] = [:]
        /// "title:<key>" → the series of that title: a calendar series is keyed by its id, so a title finds it here.
        var titles: [String: String] = [:]
        /// Meeting id → title, to filter a series by words without loading its meetings.
        var names: [String: String] = [:]
    }

    /// Series key → meeting ids (newest first), only for keys shared by two or more meetings. Meetings without a
    /// calendar series join the calendar series whose events carry the same title.
    static func groups(_ meetings: [Transcript]) -> [String: [String]] { build(meetings).groups }

    static func build(_ meetings: [Transcript]) -> Index {
        let sorted = meetings.filter { $0.origin == "meeting" && $0.deletedAt == nil }.sorted { $0.createdAt > $1.createdAt }
        var keys: [String: String] = [:]
        var titleToSeries: [String: Set<String>] = [:]
        for t in sorted {
            guard let k = key(t) else { continue }
            keys[t.id] = k
            if !k.hasPrefix("title:"), let tk = titleKey(title(t)) { titleToSeries["title:" + tk, default: []].insert(k) }
        }
        var out: [String: [String]] = [:]
        for t in sorted {
            guard var k = keys[t.id] else { continue }
            if k.hasPrefix("title:"), let series = titleToSeries[k], series.count == 1 { k = series.first! }
            keys[t.id] = k
            out[k, default: []].append(t.id)
        }
        var index = Index(groups: out.filter { $0.value.count >= 2 })
        index.byMeeting = keys.filter { index.groups[$0.value] != nil }
        for t in sorted {
            guard let k = index.byMeeting[t.id] else { continue }
            index.names[t.id] = t.title
            // Newest first: a title shared by two calendar series finds the latest one.
            for tk in Set([title(t), t.title].compactMap(titleKey)) where index.titles["title:" + tk] == nil { index.titles["title:" + tk] = k }
        }
        return index
    }

    /// meeting id → its series key, for meetings that are in a series.
    static func index(_ groups: [String: [String]]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, ids) in groups { for id in ids { out[id] = k } }
        return out
    }

    /// Matches `/v1/meetings?series=`: a key as listed, a calendar series id, or a title (normalised the same way).
    static func find(_ query: String, in groups: [String: [String]], titles: [String: String] = [:]) -> [String]? {
        if let ids = groups[query] { return ids }
        guard let tk = titleKey(query.hasPrefix("title:") ? String(query.dropFirst(6)) : query) else { return nil }
        return groups["title:" + tk] ?? titles["title:" + tk].flatMap { groups[$0] }
    }

    static func find(_ query: String, in index: Index) -> [String]? { find(query, in: index.groups, titles: index.titles) }

    /// A readable name for a series: the newest meeting's title.
    static func name(_ ids: [String], in all: [Transcript]) -> String {
        all.first { $0.id == ids.first }.map { $0.context?.calendar?.title ?? $0.title } ?? "Series"
    }
}
