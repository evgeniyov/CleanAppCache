import Foundation
import SQLite3

/// Clears the browsing history inside a Firefox `places.sqlite` and leaves the
/// file, its bookmarks, keywords and the annotations of bookmarked pages where
/// they are.
///
/// Firefox keeps bookmarks in the same database as history, so the file is
/// never deleted — not even as a fallback when the clear fails. Everything
/// runs in one transaction: a statement that fails (a schema this code does
/// not know, a trigger that calls a Firefox-only SQL function, a database
/// still locked) rolls the whole clear back and the database is as it was.
///
/// The caller runs this only while Firefox is not running. Firefox also holds
/// `places.sqlite` under an exclusive lock while it runs, so a copy that comes
/// back mid-clear makes `BEGIN IMMEDIATE` fail here rather than race it.
enum FirefoxHistory {

    enum Outcome: Equatable {
        /// History is gone. `reclaimedBytes` is how much the database and its
        /// sidecar files shrank on disk. It is often 0: SQLite keeps freed pages
        /// inside the file for reuse unless the database uses auto-vacuum.
        case cleared(reclaimedBytes: UInt64)
        case failed(reason: String)
    }

    /// Tables and columns the clear relies on. A database missing any of them
    /// is not a schema this code knows, and nothing in it is touched.
    static let requiredSchema: [(table: String, columns: [String])] = [
        ("moz_places", ["id", "visit_count", "last_visit_date", "foreign_count", "origin_id"]),
        ("moz_historyvisits", ["place_id"]),
        ("moz_inputhistory", ["place_id"]),
        ("moz_origins", ["id"]),
        ("moz_bookmarks", ["fk"]),
        ("moz_keywords", ["place_id"]),
    ]

    /// One statement of the clear. `onlyIf` names a table and column that some
    /// Firefox versions have and others do not; the statement runs only when
    /// the column exists. Without `onlyIf` the statement always runs, and its
    /// tables are covered by `requiredSchema`.
    struct Step: Sendable {
        let sql: String
        var onlyIf: (table: String, column: String)?
    }

    /// The clear, in order. Rows that hang off a visit or a page go before the
    /// pages themselves.
    static let steps: [Step] = [
        Step(sql: "DELETE FROM moz_historyvisits"),
        Step(sql: "DELETE FROM moz_historyvisits_extra",
             onlyIf: ("moz_historyvisits_extra", "visit_id")),
        Step(sql: "DELETE FROM moz_inputhistory"),
        // Time spent on pages and the search terms that led to them.
        Step(sql: "DELETE FROM moz_places_metadata",
             onlyIf: ("moz_places_metadata", "place_id")),
        Step(sql: "DELETE FROM moz_places_metadata_search_queries",
             onlyIf: ("moz_places_metadata_search_queries", "id")),
        // `foreign_count` counts the bookmarks and keywords that point at a
        // page. The two subqueries keep such a page even if that counter has
        // drifted: a page deleted from under a bookmark breaks the bookmark.
        Step(sql: """
            DELETE FROM moz_places
            WHERE foreign_count = 0
              AND id NOT IN (SELECT fk FROM moz_bookmarks WHERE fk IS NOT NULL)
              AND id NOT IN (SELECT place_id FROM moz_keywords WHERE place_id IS NOT NULL)
            """),
        // Annotations of the pages just deleted; a bookmarked page keeps its own.
        Step(sql: "DELETE FROM moz_annos WHERE place_id NOT IN (SELECT id FROM moz_places)",
             onlyIf: ("moz_annos", "place_id")),
        Step(sql: "DELETE FROM moz_places_extra WHERE place_id NOT IN (SELECT id FROM moz_places)",
             onlyIf: ("moz_places_extra", "place_id")),
        // Firefox maintains these with temporary triggers that exist only on
        // its own connection, so they are reset here by hand.
        Step(sql: "UPDATE moz_places SET visit_count = 0, last_visit_date = NULL"),
        Step(sql: """
            DELETE FROM moz_origins
            WHERE id NOT IN (SELECT DISTINCT origin_id FROM moz_places WHERE origin_id IS NOT NULL)
            """),
        // Ranking in the address bar was computed from the visits; these flags
        // make Firefox recompute it for the bookmarks that remain.
        Step(sql: "UPDATE moz_places SET recalc_frecency = 1",
             onlyIf: ("moz_places", "recalc_frecency")),
        Step(sql: "UPDATE moz_places SET recalc_alt_frecency = 1",
             onlyIf: ("moz_places", "recalc_alt_frecency")),
        Step(sql: "UPDATE moz_origins SET recalc_frecency = 1",
             onlyIf: ("moz_origins", "recalc_frecency")),
        Step(sql: "UPDATE moz_origins SET recalc_alt_frecency = 1",
             onlyIf: ("moz_origins", "recalc_alt_frecency")),
    ]

    /// Clears the history in the database at `url`. `busyTimeout` is how long,
    /// in milliseconds, to wait for another connection's lock before failing.
    static func clear(database url: URL, busyTimeout: Int32 = 2_000) -> Outcome {
        let before = footprint(of: url)
        if let reason = run(database: url, busyTimeout: busyTimeout) {
            return .failed(reason: reason)
        }
        // Measured after the connection is closed: closing the last connection
        // checkpoints the write-ahead log and removes it.
        let after = footprint(of: url)
        return .cleared(reclaimedBytes: before > after ? before - after : 0)
    }

    /// Nil on success, otherwise why the clear was rolled back or never began.
    private static func run(database url: URL, busyTimeout: Int32) -> String? {
        if let reason = PathGuard.reject(url) { return "protected database: \(reason)" }
        guard let pointer = realpath(url.path, nil) else { return "database is missing or inaccessible" }
        let physicalPath = String(cString: pointer)
        free(pointer)
        let target = URL(fileURLWithPath: physicalPath)
        guard PathGuard.reject(target) == nil,
              let snapshot = FileSnapshot(at: target), snapshot.isRegularFile else {
            return "database target could not be verified"
        }
        var handle: OpaquePointer?
        // Read-write on an existing file only: without CREATE a missing
        // database is an error rather than a new empty one. Resolve a legitimate
        // profile symlink first, then refuse new symlinks anywhere in that
        // physical path. The schema check limits the statements to Firefox history.
        guard sqlite3_open_v2(physicalPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let db = handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            sqlite3_close_v2(handle)
            return reason
        }
        defer { sqlite3_close_v2(db) }
        guard snapshot.matches(target), PathGuard.reject(target) == nil else {
            return "database changed before opening"
        }
        sqlite3_busy_timeout(db, busyTimeout)

        // Deleted rows are overwritten with zeros instead of staying readable
        // in the file's free pages. Foreign keys stay off, as on Firefox's own
        // connection, so the order of the steps decides what goes first.
        _ = exec(db, "PRAGMA secure_delete = ON")
        _ = exec(db, "PRAGMA foreign_keys = OFF")

        if let error = exec(db, "BEGIN IMMEDIATE") { return error }
        if let error = clearInTransaction(db) ?? exec(db, "COMMIT") {
            _ = exec(db, "ROLLBACK")
            return error
        }

        // Best effort once the history is committed: give freed pages back to
        // the file system when the database uses incremental auto-vacuum, and
        // fold the write-ahead log, which still holds the old pages, into the
        // main file.
        _ = exec(db, "PRAGMA incremental_vacuum")
        _ = exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        return nil
    }

    private static func clearInTransaction(_ db: OpaquePointer) -> String? {
        var columns: [String: Set<String>] = [:]
        func has(_ table: String, _ column: String) -> Bool {
            if columns[table] == nil { columns[table] = self.columns(of: table, in: db) }
            return columns[table]?.contains(column) == true
        }

        for (table, required) in requiredSchema {
            for column in required where !has(table, column) {
                return "unknown places.sqlite schema: \(table).\(column) is missing"
            }
        }
        for step in steps {
            if let condition = step.onlyIf, !has(condition.table, condition.column) { continue }
            if let error = exec(db, step.sql) { return error }
        }
        return nil
    }

    /// The table's column names; empty when the table does not exist.
    private static func columns(of table: String, in db: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        // `table` is always one of the constant names above, never input.
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                names.insert(String(cString: name))
            }
        }
        return names
    }

    /// Nil on success, otherwise SQLite's error message.
    private static func exec(_ db: OpaquePointer, _ sql: String) -> String? {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK else { return nil }
        defer { sqlite3_free(error) }
        return error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
    }

    /// Allocated size of the database with every sidecar SQLite may keep.
    private static func footprint(of url: URL) -> UInt64 {
        let fm = FileManager.default
        return ["", "-wal", "-shm", "-journal"].reduce(UInt64(0)) { total, suffix in
            let file = URL(fileURLWithPath: url.path + suffix)
            return total &+ ((try? fm.allocatedSize(of: file)) ?? 0)
        }
    }
}
