import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Transcript history in a small SQLite database (one table, segments stored as JSON).
/// Every statement runs under `lock`; the connection is also opened in serialized mode.
final class Store: @unchecked Sendable {
    static let shared = Store()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Bumped by every write, so what is computed from the library can be cached until it changes.
    private var changes = 0
    private var seriesCache: (changes: Int, index: Series.Index)?

    var generation: Int { lock.withLock { changes } }

    private init() {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(Paths.database.path, &db, flags, nil) != SQLITE_OK {
            NSLog("Earshot: cannot open \(Paths.database.path): \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory")")
            sqlite3_close(db)
            db = nil
            return
        }
        sqlite3_busy_timeout(db, 5000)
        exec("PRAGMA journal_mode=WAL")
        exec("""
        CREATE TABLE IF NOT EXISTS transcripts (
            id TEXT PRIMARY KEY,
            created REAL NOT NULL,
            title TEXT NOT NULL,
            source_path TEXT,
            origin TEXT NOT NULL,
            model TEXT NOT NULL,
            language TEXT,
            duration REAL,
            processing REAL NOT NULL,
            text TEXT NOT NULL,
            segments TEXT NOT NULL
        )
        """)
        exec("CREATE INDEX IF NOT EXISTS transcripts_created ON transcripts(created DESC)")
        // v0.4: Recently Deleted, folders, people (ALTERs fail harmlessly once the column exists)
        exec("ALTER TABLE transcripts ADD COLUMN deleted REAL")
        exec("ALTER TABLE transcripts ADD COLUMN folder TEXT")
        exec("CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0)")
        exec("ALTER TABLE transcripts ADD COLUMN ai TEXT")
        exec("CREATE TABLE IF NOT EXISTS people (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE)")
        // v0.7: meeting notes, remembered voices, full-text search
        exec("ALTER TABLE transcripts ADD COLUMN notes TEXT")
        exec("CREATE TABLE IF NOT EXISTS voices (name TEXT PRIMARY KEY, embedding TEXT NOT NULL, samples INTEGER NOT NULL DEFAULT 1)")
        // v0.10: meeting context (room, calendar event, participants, events) as JSON
        exec("ALTER TABLE transcripts ADD COLUMN context TEXT")
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2')")
        exec("""
        INSERT INTO search (id, title, body)
        SELECT id, title, text || ' ' || COALESCE(notes, '') FROM transcripts WHERE id NOT IN (SELECT id FROM search)
        """)
        exec("DELETE FROM search WHERE id NOT IN (SELECT id FROM transcripts)")
    }

    /// Writes the row and its search entry in one transaction. False when nothing was saved.
    @discardableResult
    func insert(_ t: Transcript) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return transaction {
            let sql = "INSERT OR REPLACE INTO transcripts (id, created, title, source_path, origin, model, language, duration, processing, text, segments, deleted, folder, ai, notes, context) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(st) }
            bind(st, 1, t.id)
            sqlite3_bind_double(st, 2, t.createdAt.timeIntervalSince1970)
            bind(st, 3, t.title)
            bind(st, 4, t.sourcePath)
            bind(st, 5, t.origin)
            bind(st, 6, t.model)
            bind(st, 7, t.language)
            if let d = t.duration { sqlite3_bind_double(st, 8, d) } else { sqlite3_bind_null(st, 8) }
            sqlite3_bind_double(st, 9, t.processingSeconds)
            bind(st, 10, t.text)
            guard let segments = try? encoder.encode(t.segments) else { return false }
            bind(st, 11, String(data: segments, encoding: .utf8))
            if let d = t.deletedAt { sqlite3_bind_double(st, 12, d.timeIntervalSince1970) } else { sqlite3_bind_null(st, 12) }
            bind(st, 13, t.folderID)
            sqlite3_bind_null(st, 14)
            bind(st, 15, t.notes.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) })
            bind(st, 16, encoded(t.context))
            return step(st) && index(t)
        }
    }

    /// Replaces only the content of an existing row (never recreates a deleted one). nil arguments keep the stored value,
    /// so notes and the meeting context survive a re-transcription.
    @discardableResult
    func updateContent(id: String, segments: [Segment], text: String, model: String? = nil, processingSeconds: Double? = nil,
                       duration: Double? = nil, language: String? = nil, context: MeetingContext? = nil) -> Bool {
        guard let json = (try? encoder.encode(segments)).flatMap({ String(data: $0, encoding: .utf8) }) else { return false }
        lock.lock(); defer { lock.unlock() }
        return transaction {
            let sql = """
            UPDATE transcripts SET segments = ?1, text = ?2, model = COALESCE(?3, model), processing = COALESCE(?4, processing),
                duration = COALESCE(?5, duration), language = COALESCE(?6, language), context = COALESCE(?8, context) WHERE id = ?7
            """
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(st) }
            bind(st, 1, json)
            bind(st, 2, text)
            bind(st, 3, model)
            if let processingSeconds { sqlite3_bind_double(st, 4, processingSeconds) } else { sqlite3_bind_null(st, 4) }
            if let duration { sqlite3_bind_double(st, 5, duration) } else { sqlite3_bind_null(st, 5) }
            bind(st, 6, language)
            bind(st, 7, id)
            bind(st, 8, encoded(context))
            guard step(st), sqlite3_changes(db) > 0, let t = getLocked(id) else { return false }
            return index(t)
        }
    }

    /// Sets the meeting context of a stored transcript (nil clears it).
    @discardableResult
    func setContext(_ id: String, _ context: MeetingContext?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return transaction {
            guard runLocked("UPDATE transcripts SET context = ? WHERE id = ?", [encoded(context), id]), sqlite3_changes(db) > 0,
                  let t = getLocked(id) else { return false }
            return index(t)
        }
    }

    /// Keeps the full-text index in step with the row (caller holds the lock). The meeting and calendar titles count
    /// as title words; participant names and chat as body, so "Maya" finds the meetings she attended.
    private func index(_ t: Transcript) -> Bool {
        let notes = (t.notes ?? []).map(\.text).joined(separator: " ")
        let c = t.context
        let titles = [c?.title, c?.calendar?.title].compactMap { $0 }.filter { $0 != t.title && !$0.isEmpty }
        var extra = (c?.participants ?? []).map(\.name) + (c?.calendar?.attendees ?? []).compactMap(\.name)
        extra += Formats.chats(c).compactMap(\.text)
        if let code = c?.meetingCode { extra.append(code) }
        let title = ([t.title] + titles).joined(separator: " ")
        let body = ([t.text, notes] + extra).filter { !$0.isEmpty }.joined(separator: " ")
        return runLocked("DELETE FROM search WHERE id = ?", [t.id])
            && runLocked("INSERT INTO search (id, title, body) VALUES (?, ?, ?)", [t.id, title, body])
    }

    private func encoded<T: Encodable>(_ value: T?) -> String? {
        value.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// `limit` nil = everything (the app's own library); the API passes its page size.
    func list(limit: Int? = 50, offset: Int = 0, query: String? = nil, origin: String? = nil, deleted: Bool = false) -> [Transcript] {
        lock.lock(); defer { lock.unlock() }
        var sql = "SELECT \(Self.columns) FROM transcripts WHERE deleted IS \(deleted ? "NOT NULL" : "NULL")"
        let match = query.flatMap(Self.ftsQuery)
        if match != nil { sql += " AND id IN (SELECT id FROM search WHERE search MATCH ?1)" } else if query != nil { sql += " AND (text LIKE ?1 OR title LIKE ?1)" }
        if origin != nil { sql += " AND origin = ?2" }
        sql += " ORDER BY created DESC LIMIT \(limit.map { max(1, min($0, 500)) } ?? -1) OFFSET \(max(0, offset))"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        if let match { bind(st, 1, match) } else if let query { bind(st, 1, "%\(query)%") }
        if let origin { bind(st, 2, origin) }
        var out: [Transcript] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(row(st)) }
        return out
    }

    func get(_ id: String) -> Transcript? {
        lock.lock(); defer { lock.unlock() }
        return getLocked(id)
    }

    private func getLocked(_ id: String) -> Transcript? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(Self.columns) FROM transcripts WHERE id = ?", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, 1, id)
        return sqlite3_step(st) == SQLITE_ROW ? row(st) : nil
    }

    /// Permanent delete: row, search entry and the recording when Earshot made it.
    @discardableResult
    func delete(_ id: String) -> Bool { purge("id = ?", [id]) > 0 }

    /// Empties Recently Deleted in one statement.
    @discardableResult
    func deleteTrashed() -> Int { purge("deleted IS NOT NULL", []) }

    private static let columns = "id, created, title, source_path, origin, model, language, duration, processing, text, segments, deleted, folder, ai, notes, context"

    // MARK: Search

    struct Hit {
        var transcript: Transcript
        var snippet: String
        var segments: [Segment]
    }

    /// Every word becomes a prefix term ("budg rev" finds "budget review"), all of them required.
    static func ftsQuery(_ q: String) -> String? {
        let words = q.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return words.isEmpty ? nil : words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// Ids of every transcript (active or deleted) whose title, text or notes match.
    func searchIDs(_ q: String) -> Set<String> {
        guard let match = Self.ftsQuery(q) else { return [] }
        return Set(query("SELECT id FROM search WHERE search MATCH ?", [match]) { self.text($0, 0) }.compactMap { $0 })
    }

    /// Ranked full-text search over titles, transcripts and notes, with the matching lines of each hit.
    func search(_ q: String, limit: Int = 20, origin: String? = nil) -> [Hit] {
        guard let match = Self.ftsQuery(q) else { return [] }
        lock.lock(); defer { lock.unlock() }
        var sql = """
        SELECT \(Self.columns.split(separator: ",").map { "t." + $0.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")),
               snippet(search, 2, '[', ']', '…', 16)
        FROM search JOIN transcripts t ON t.id = search.id
        WHERE search MATCH ?1 AND t.deleted IS NULL
        """
        if origin != nil { sql += " AND t.origin = ?2" }
        sql += " ORDER BY bm25(search, 0, 5, 1) LIMIT \(max(1, min(limit, 200)))"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, 1, match)
        if let origin { bind(st, 2, origin) }
        let terms = q.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var out: [Hit] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let t = row(st)
            let lines = t.segments.filter { s in
                terms.allSatisfy { s.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            out.append(Hit(transcript: t, snippet: text(st, 16) ?? "", segments: Array(lines.prefix(5))))
        }
        return out
    }

    // MARK: Voices

    /// Saved voice embeddings, one running average per person name.
    func voices() -> [String: [Float]] {
        Dictionary(query("SELECT name, embedding FROM voices", []) { st -> (String, [Float]) in
            (self.text(st, 0) ?? "", (try? self.decoder.decode([Float].self, from: Data((self.text(st, 1) ?? "[]").utf8))) ?? [])
        }.filter { !$0.0.isEmpty && !$0.1.isEmpty }, uniquingKeysWith: { a, _ in a })
    }

    /// Folds a new sample of `name`'s voice into the saved average.
    func learnVoice(_ name: String, _ embedding: [Float]) {
        guard !embedding.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let existing = queryLocked("SELECT embedding, samples FROM voices WHERE name = ?", [name]) { st in
            ((try? self.decoder.decode([Float].self, from: Data((self.text(st, 0) ?? "[]").utf8))) ?? [], Int(sqlite3_column_int(st, 1)))
        }.first
        var merged = embedding
        var count = 1
        if let (old, n) = existing, old.count == embedding.count {
            let w = Float(min(n, 20))
            merged = zip(old, embedding).map { ($0 * w + $1) / (w + 1) }
            count = n + 1
        }
        guard let json = (try? encoder.encode(merged)).flatMap({ String(data: $0, encoding: .utf8) }) else { return }
        runLocked("INSERT OR REPLACE INTO voices (name, embedding, samples) VALUES (?, ?, ?)", [name, json, String(count)])
    }

    func forgetVoice(_ name: String) { run("DELETE FROM voices WHERE name = ?", [name]) }

    // MARK: Recently Deleted

    func setDeleted(_ id: String, _ deleted: Bool) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE transcripts SET deleted = ? WHERE id = ?", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        if deleted { sqlite3_bind_double(st, 1, Date().timeIntervalSince1970) } else { sqlite3_bind_null(st, 1) }
        bind(st, 2, id)
        step(st)
    }

    /// Items in Recently Deleted for more than 30 days are removed for good.
    func purgeExpired() {
        purge("deleted IS NOT NULL AND deleted < \(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970)", [])
    }

    /// Deletes the matching rows and their search entries, then the recordings no remaining row points at.
    @discardableResult
    private func purge(_ condition: String, _ args: [String?]) -> Int {
        lock.lock()
        let paths = queryLocked("SELECT source_path FROM transcripts WHERE \(condition)", args) { self.text($0, 0) }.compactMap { $0 }
        var removed = 0
        let ok = transaction {
            guard runLocked("DELETE FROM transcripts WHERE \(condition)", args) else { return false }
            removed = Int(sqlite3_changes(db))
            return execLocked("DELETE FROM search WHERE id NOT IN (SELECT id FROM transcripts)")
        }
        let orphaned = ok ? Set(paths).filter { queryLocked("SELECT 1 FROM transcripts WHERE source_path = ? LIMIT 1", [$0]) { _ in 1 }.isEmpty } : []
        lock.unlock()
        orphaned.forEach(Self.removeRecording)
        return ok ? removed : 0
    }

    /// Removes a meeting folder (inside Paths.meetings) or a recording (inside Paths.media). Anything elsewhere is the user's.
    static func removeRecording(_ path: String) {
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        for root in [Paths.meetings, Paths.media] {
            let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            guard target.hasPrefix(base), let first = target.dropFirst(base.count).split(separator: "/").first,
                  first != ".", first != ".." else { continue }
            try? FileManager.default.removeItem(atPath: base + first)
            return
        }
    }

    // MARK: Meetings across the library

    /// Every active meeting with only what groups it into series: id, date, title and its calendar event's series id
    /// and title (not the whole context with its captions and events).
    func meetingHeaders() -> [Transcript] {
        query("""
        SELECT id, created, title, CASE WHEN json_valid(context) THEN json_extract(context, '$.calendar.seriesID') END,
               CASE WHEN json_valid(context) THEN json_extract(context, '$.calendar.title') END
        FROM transcripts WHERE deleted IS NULL AND origin = 'meeting' ORDER BY created DESC
        """, []) { st in
            let series = self.text(st, 3), calendar = self.text(st, 4)
            var context: MeetingContext?
            if series != nil || calendar != nil {
                context = MeetingContext()
                context?.calendar = CalendarInfo(title: calendar, seriesID: series)
            }
            return Transcript(id: self.text(st, 0) ?? "", createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)), title: self.text(st, 2) ?? "",
                              sourcePath: nil, origin: "meeting", model: "", language: nil, duration: nil, processingSeconds: 0, text: "", segments: [],
                              context: context)
        }
    }

    /// The library's series, rebuilt only after a write.
    func seriesIndex() -> Series.Index {
        let (cached, now) = lock.withLock { (seriesCache?.changes == changes ? seriesCache?.index : nil, changes) }
        if let cached { return cached }
        let index = Series.build(meetingHeaders())
        lock.withLock { if changes == now { seriesCache = (now, index) } }
        return index
    }

    /// Transcripts with at least one speaker label, newest first, for the speaker routes.
    func withSpeakers(since: Date? = nil, origin: String? = nil) -> [Transcript] {
        var sql = "SELECT \(Self.columns) FROM transcripts WHERE deleted IS NULL AND segments LIKE '%\"speaker\":%'"
        var args: [String?] = []
        if let since { sql += " AND created >= \(since.timeIntervalSince1970)" }
        if let origin { sql += " AND origin = ?"; args.append(origin) }
        return query(sql + " ORDER BY created DESC", args) { self.row($0) }
    }

    /// Recordings whose oldest transcript is older than `cutoff` and that no transcript with a favourite line points at.
    func recordingsOlder(than cutoff: Date) -> [(path: String, ids: [String])] {
        query("""
        SELECT source_path, GROUP_CONCAT(id) FROM transcripts WHERE source_path IS NOT NULL GROUP BY source_path
        HAVING MIN(created) < \(cutoff.timeIntervalSince1970) AND SUM(segments LIKE '%"favorite":true%') = 0
        """, []) { st in self.text(st, 0).map { ($0, (self.text(st, 1) ?? "").split(separator: ",").map(String.init)) } }.compactMap { $0 }
    }

    // MARK: Folders

    func folders() -> [Folder] {
        query("SELECT id, name FROM folders ORDER BY position, name", []) { Folder(id: self.text($0, 0) ?? "", name: self.text($0, 1) ?? "") }
    }

    func saveFolder(_ f: Folder) { run("INSERT OR REPLACE INTO folders (id, name) VALUES (?, ?)", [f.id, f.name]) }

    func deleteFolder(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        transaction {
            runLocked("UPDATE transcripts SET folder = NULL WHERE folder = ?", [id]) && runLocked("DELETE FROM folders WHERE id = ?", [id])
        }
    }

    func setFolder(_ transcriptID: String, _ folderID: String?) { run("UPDATE transcripts SET folder = ? WHERE id = ?", [folderID, transcriptID]) }

    func list(folder: String) -> [Transcript] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(Self.columns) FROM transcripts WHERE deleted IS NULL AND folder = ? ORDER BY created DESC", -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st, 1, folder)
        var out: [Transcript] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(row(st)) }
        return out
    }

    // MARK: People

    func people() -> [Person] {
        query("SELECT id, name FROM people ORDER BY name COLLATE NOCASE", []) { Person(id: self.text($0, 0) ?? "", name: self.text($0, 1) ?? "") }
    }

    func savePerson(_ p: Person) { run("INSERT OR REPLACE INTO people (id, name) VALUES (?, ?)", [p.id, p.name]) }
    func deletePerson(_ id: String) { run("DELETE FROM people WHERE id = ?", [id]) }

    // MARK: Helpers

    private func query<T>(_ sql: String, _ args: [String?], _ map: (OpaquePointer?) -> T) -> [T] {
        lock.lock(); defer { lock.unlock() }
        return queryLocked(sql, args, map)
    }

    private func queryLocked<T>(_ sql: String, _ args: [String?], _ map: (OpaquePointer?) -> T) -> [T] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { bind(st, Int32(i + 1), a) }
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(map(st)) }
        return out
    }

    @discardableResult
    private func run(_ sql: String, _ args: [String?]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return runLocked(sql, args)
    }

    @discardableResult
    private func runLocked(_ sql: String, _ args: [String?]) -> Bool {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { bind(st, Int32(i + 1), a) }
        return step(st)
    }

    /// BEGIN IMMEDIATE … COMMIT, rolled back when `body` fails (caller holds the lock).
    @discardableResult
    private func transaction(_ body: () -> Bool) -> Bool {
        guard execLocked("BEGIN IMMEDIATE") else { return false }
        if body(), execLocked("COMMIT") { return true }
        execLocked("ROLLBACK")
        return false
    }

    @discardableResult
    private func step(_ st: OpaquePointer?) -> Bool {
        if sqlite3_stmt_readonly(st) == 0 { changes += 1 }
        let rc = sqlite3_step(st)
        if rc != SQLITE_DONE && rc != SQLITE_ROW { NSLog("Earshot: SQLite step failed (\(rc)): \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "")") }
        return rc == SQLITE_DONE || rc == SQLITE_ROW
    }

    private func row(_ st: OpaquePointer?) -> Transcript {
        let segJSON = text(st, 10) ?? "[]"
        return Transcript(
            id: text(st, 0) ?? "",
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
            title: text(st, 2) ?? "",
            sourcePath: text(st, 3),
            origin: text(st, 4) ?? "",
            model: text(st, 5) ?? "",
            language: text(st, 6),
            duration: sqlite3_column_type(st, 7) == SQLITE_NULL ? nil : sqlite3_column_double(st, 7),
            processingSeconds: sqlite3_column_double(st, 8),
            text: text(st, 9) ?? "",
            segments: (try? decoder.decode([Segment].self, from: Data(segJSON.utf8))) ?? [],
            deletedAt: sqlite3_column_type(st, 11) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(st, 11)),
            folderID: text(st, 12),
            notes: text(st, 14).flatMap { try? decoder.decode([Note].self, from: Data($0.utf8)) },
            context: text(st, 15).flatMap { try? decoder.decode(MeetingContext.self, from: Data($0.utf8)) }
        )
    }

    private func text(_ st: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(st, i, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, i) }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return execLocked(sql)
    }

    @discardableResult
    private func execLocked(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
}
