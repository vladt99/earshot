import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Transcript history in a small SQLite database (one table, segments stored as JSON).
final class Store: @unchecked Sendable {
    static let shared = Store()

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init() {
        sqlite3_open(Paths.database.path, &db)
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
        // v0.4: Recently Deleted, folders, people
        exec("ALTER TABLE transcripts ADD COLUMN deleted REAL")
        exec("ALTER TABLE transcripts ADD COLUMN folder TEXT")
        exec("CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL DEFAULT 0)")
        exec("ALTER TABLE transcripts ADD COLUMN ai TEXT")
        exec("CREATE TABLE IF NOT EXISTS people (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE)")
        // v0.7: meeting notes, remembered voices, full-text search
        exec("ALTER TABLE transcripts ADD COLUMN notes TEXT")
        exec("CREATE TABLE IF NOT EXISTS voices (name TEXT PRIMARY KEY, embedding TEXT NOT NULL, samples INTEGER NOT NULL DEFAULT 1)")
        exec("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2')")
        exec("""
        INSERT INTO search (id, title, body)
        SELECT id, title, text || ' ' || COALESCE(notes, '') FROM transcripts WHERE id NOT IN (SELECT id FROM search)
        """)
    }

    func insert(_ t: Transcript) {
        lock.lock(); defer { lock.unlock() }
        let sql = "INSERT OR REPLACE INTO transcripts (id, created, title, source_path, origin, model, language, duration, processing, text, segments, deleted, folder, ai, notes) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
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
        bind(st, 11, String(data: (try? encoder.encode(t.segments)) ?? Data("[]".utf8), encoding: .utf8))
        if let d = t.deletedAt { sqlite3_bind_double(st, 12, d.timeIntervalSince1970) } else { sqlite3_bind_null(st, 12) }
        bind(st, 13, t.folderID)
        sqlite3_bind_null(st, 14)
        bind(st, 15, t.notes.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) })
        sqlite3_step(st)
        index(t)
    }

    /// Keeps the full-text index in step with the row (caller holds the lock).
    private func index(_ t: Transcript) {
        let notes = (t.notes ?? []).map(\.text).joined(separator: " ")
        for (sql, args) in [("DELETE FROM search WHERE id = ?", [t.id]),
                            ("INSERT INTO search (id, title, body) VALUES (?, ?, ?)", [t.id, t.title, t.text + " " + notes])] {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { continue }
            for (i, a) in args.enumerated() { bind(st, Int32(i + 1), a) }
            sqlite3_step(st)
            sqlite3_finalize(st)
        }
    }

    func list(limit: Int = 50, offset: Int = 0, query: String? = nil, origin: String? = nil, deleted: Bool = false) -> [Transcript] {
        lock.lock(); defer { lock.unlock() }
        var sql = "SELECT \(Self.columns) FROM transcripts WHERE deleted IS \(deleted ? "NOT NULL" : "NULL")"
        let match = query.flatMap(Self.ftsQuery)
        if match != nil { sql += " AND id IN (SELECT id FROM search WHERE search MATCH ?1)" } else if query != nil { sql += " AND (text LIKE ?1 OR title LIKE ?1)" }
        if origin != nil { sql += " AND origin = ?2" }
        sql += " ORDER BY created DESC LIMIT \(max(1, min(limit, 500))) OFFSET \(max(0, offset))"
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
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(Self.columns) FROM transcripts WHERE id = ?", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, 1, id)
        return sqlite3_step(st) == SQLITE_ROW ? row(st) : nil
    }

    @discardableResult
    func delete(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM transcripts WHERE id = ?", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        bind(st, 1, id)
        sqlite3_step(st)
        let changed = sqlite3_changes(db) > 0
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM search WHERE id = ?", -1, &del, nil) == SQLITE_OK {
            bind(del, 1, id)
            sqlite3_step(del)
            sqlite3_finalize(del)
        }
        return changed
    }

    private static let columns = "id, created, title, source_path, origin, model, language, duration, processing, text, segments, deleted, folder, ai, notes"

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
            out.append(Hit(transcript: t, snippet: text(st, 15) ?? "", segments: Array(lines.prefix(5))))
        }
        return out
    }

    // MARK: Voices

    /// Saved voice embeddings, one running average per person name.
    func voices() -> [String: [Float]] {
        Dictionary(query("SELECT name, embedding FROM voices") { st -> (String, [Float]) in
            (self.text(st, 0) ?? "", (try? self.decoder.decode([Float].self, from: Data((self.text(st, 1) ?? "[]").utf8))) ?? [])
        }.filter { !$0.0.isEmpty && !$0.1.isEmpty }, uniquingKeysWith: { a, _ in a })
    }

    /// Folds a new sample of `name`'s voice into the saved average.
    func learnVoice(_ name: String, _ embedding: [Float]) {
        guard !embedding.isEmpty else { return }
        let existing = query("SELECT embedding, samples FROM voices WHERE name = '\(name.replacingOccurrences(of: "'", with: "''"))'") { st in
            ((try? self.decoder.decode([Float].self, from: Data((self.text(st, 0) ?? "[]").utf8))) ?? [], Int(sqlite3_column_int(st, 1)))
        }.first
        var merged = embedding
        var count = 1
        if let (old, n) = existing, old.count == embedding.count {
            let w = Float(min(n, 20))
            merged = zip(old, embedding).map { ($0 * w + $1) / (w + 1) }
            count = n + 1
        }
        let json = String(data: (try? encoder.encode(merged)) ?? Data(), encoding: .utf8)
        run("INSERT OR REPLACE INTO voices (name, embedding, samples) VALUES (?, ?, ?)", [name, json, String(count)])
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
        sqlite3_step(st)
    }

    /// Items in Recently Deleted for more than 30 days are removed for good.
    func purgeExpired() {
        exec("DELETE FROM transcripts WHERE deleted IS NOT NULL AND deleted < \(Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970)")
    }

    // MARK: Folders

    func folders() -> [Folder] {
        query("SELECT id, name FROM folders ORDER BY position, name") { Folder(id: self.text($0, 0) ?? "", name: self.text($0, 1) ?? "") }
    }

    func saveFolder(_ f: Folder) { run("INSERT OR REPLACE INTO folders (id, name) VALUES (?, ?)", [f.id, f.name]) }

    func deleteFolder(_ id: String) {
        run("UPDATE transcripts SET folder = NULL WHERE folder = ?", [id])
        run("DELETE FROM folders WHERE id = ?", [id])
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
        query("SELECT id, name FROM people ORDER BY name COLLATE NOCASE") { Person(id: self.text($0, 0) ?? "", name: self.text($0, 1) ?? "") }
    }

    func savePerson(_ p: Person) { run("INSERT OR REPLACE INTO people (id, name) VALUES (?, ?)", [p.id, p.name]) }
    func deletePerson(_ id: String) { run("DELETE FROM people WHERE id = ?", [id]) }

    // MARK: Helpers

    private func query<T>(_ sql: String, _ map: (OpaquePointer?) -> T) -> [T] {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        var out: [T] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(map(st)) }
        return out
    }

    private func run(_ sql: String, _ args: [String?]) {
        lock.lock(); defer { lock.unlock() }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        for (i, a) in args.enumerated() { bind(st, Int32(i + 1), a) }
        sqlite3_step(st)
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
            notes: text(st, 14).flatMap { try? decoder.decode([Note].self, from: Data($0.utf8)) }
        )
    }

    private func text(_ st: OpaquePointer?, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(st, i, value, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(st, i) }
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
