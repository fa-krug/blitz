import Foundation
import SQLite3

// Spelled as the C macro in sqlite3.h, which isn't imported into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Recognized screenshot text. Each call opens its own connection, so any task may make one.
struct ScreenshotTextStore: Sendable {
    let url: URL

    /// Trigram FTS cannot match a shorter term, which falls back to a scan of the table.
    static let minimumIndexedTerm = 3

    private static let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        CREATE TABLE IF NOT EXISTS screenshots(
          path TEXT NOT NULL UNIQUE, modified REAL NOT NULL, text TEXT NOT NULL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS screenshots_fts USING fts5(
          text, content='screenshots', content_rowid='rowid', tokenize='trigram'
        );
        CREATE TRIGGER IF NOT EXISTS screenshots_ai AFTER INSERT ON screenshots BEGIN
          INSERT INTO screenshots_fts(rowid, text) VALUES(new.rowid, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS screenshots_ad AFTER DELETE ON screenshots BEGIN
          INSERT INTO screenshots_fts(screenshots_fts, rowid, text)
            VALUES('delete', old.rowid, old.text);
        END;
        CREATE TRIGGER IF NOT EXISTS screenshots_au AFTER UPDATE ON screenshots BEGIN
          INSERT INTO screenshots_fts(screenshots_fts, rowid, text)
            VALUES('delete', old.rowid, old.text);
          INSERT INTO screenshots_fts(rowid, text) VALUES(new.rowid, new.text);
        END;
        """

    /// Path to the modification time each row's text was read at.
    func stamps() -> [String: Double] {
        withDatabase(creating: false) { db in
            var stamps: [String: Double] = [:]
            Self.each(db, "SELECT path, modified FROM screenshots") { statement in
                stamps[Self.string(statement, 0)] = sqlite3_column_double(statement, 1)
            }
            return stamps
        } ?? [:]
    }

    /// An empty text is a completed read too, so a capture without words is not read again.
    @discardableResult
    func record(_ file: ScreenshotFile, text: String) -> Bool {
        withDatabase(creating: true) { db in
            Self.run(
                db,
                """
                INSERT INTO screenshots(path, modified, text) VALUES(?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET modified = excluded.modified, text = excluded.text
                """
            ) { statement in
                sqlite3_bind_text(statement, 1, file.path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(statement, 2, file.modified)
                sqlite3_bind_text(statement, 3, text, -1, SQLITE_TRANSIENT)
            }
        } ?? false
    }

    /// `vanished` is the filesystem's answer, injected so this file never touches one.
    @discardableResult
    func prune(where vanished: (String) -> Bool) -> Int {
        withDatabase(creating: false) { db in
            var gone: [String] = []
            Self.each(db, "SELECT path FROM screenshots") { statement in
                let path = Self.string(statement, 0)
                if vanished(path) { gone.append(path) }
            }
            guard !gone.isEmpty else { return 0 }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            for path in gone {
                Self.run(db, "DELETE FROM screenshots WHERE path = ?") { statement in
                    sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
                }
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
            return gone.count
        } ?? 0
    }

    /// Paths whose text holds every term, in any order and any case.
    func paths(matching terms: [String]) -> Set<String> {
        guard !terms.isEmpty else { return [] }
        return withDatabase(creating: false) { db in
            var paths = Set<String>()
            let indexed = terms.allSatisfy { $0.count >= Self.minimumIndexedTerm }
            let sql =
                indexed
                ? """
                SELECT s.path FROM screenshots_fts f JOIN screenshots s ON s.rowid = f.rowid
                WHERE screenshots_fts MATCH ?
                """
                : "SELECT path FROM screenshots WHERE "
                    + Array(repeating: "text LIKE ? ESCAPE '\\'", count: terms.count)
                    .joined(separator: " AND ")
            Self.each(db, sql, bind: { statement in
                if indexed {
                    let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                        .joined(separator: " ")
                    sqlite3_bind_text(statement, 1, match, -1, SQLITE_TRANSIENT)
                } else {
                    for (index, term) in terms.enumerated() {
                        sqlite3_bind_text(
                            statement, Int32(index + 1), "%" + Self.escapeLike(term) + "%", -1,
                            SQLITE_TRANSIENT)
                    }
                }
            }) { statement in
                paths.insert(Self.string(statement, 0))
            }
            return paths
        } ?? []
    }

    /// Nil unless the text was read from the file as it is now: an edited capture says otherwise.
    func text(at path: String, modified: Double) -> String? {
        withDatabase(creating: false) { db in
            var text: String?
            Self.each(
                db, "SELECT text FROM screenshots WHERE path = ? AND modified = ?",
                bind: { statement in
                    sqlite3_bind_text(statement, 1, path, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(statement, 2, modified)
                }
            ) { statement in
                text = Self.string(statement, 0)
            }
            return text
        }
    }

    /// A read never creates the file: search with nothing recognized yet stays a no-op on disk.
    private func withDatabase<Value>(
        creating: Bool, _ body: (OpaquePointer) -> Value?
    ) -> Value? {
        guard creating || FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (creating ? SQLITE_OPEN_CREATE : 0)
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else { return nil }
        sqlite3_busy_timeout(db, 5_000)
        guard sqlite3_exec(db, Self.schema, nil, nil, nil) == SQLITE_OK else { return nil }
        return body(db)
    }

    @discardableResult
    private static func run(
        _ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void
    ) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private static func each(
        _ db: OpaquePointer, _ sql: String, bind: (OpaquePointer) -> Void = { _ in },
        row: (OpaquePointer) -> Void
    ) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func escapeLike(_ term: String) -> String {
        var escaped = ""
        for character in term {
            if character == "\\" || character == "%" || character == "_" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
}
