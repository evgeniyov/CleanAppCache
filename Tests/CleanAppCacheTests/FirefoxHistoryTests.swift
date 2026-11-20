import XCTest
import SQLite3
@testable import CleanAppCacheLib

/// Firefox keeps bookmarks in the same places.sqlite as history. These tests
/// build a small database with the tables the clear touches and check that
/// history goes, bookmarks stay, and a failure leaves every row in place.
final class FirefoxHistoryTests: XCTestCase {

    private var directory: URL!
    private var database: URL { directory.appendingPathComponent("places.sqlite") }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("places_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixture

    /// The Firefox tables and columns the clear reads or writes, in WAL mode
    /// as Firefox keeps them.
    private static let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE moz_origins (id INTEGER PRIMARY KEY, prefix TEXT NOT NULL, host TEXT NOT NULL,
            frecency INTEGER NOT NULL, recalc_frecency INTEGER NOT NULL DEFAULT 0, UNIQUE (prefix, host));
        CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
            visit_count INTEGER DEFAULT 0, frecency INTEGER DEFAULT -1 NOT NULL,
            last_visit_date INTEGER, guid TEXT, foreign_count INTEGER DEFAULT 0 NOT NULL,
            origin_id INTEGER REFERENCES moz_origins(id), recalc_frecency INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE moz_historyvisits (id INTEGER PRIMARY KEY, from_visit INTEGER, place_id INTEGER,
            visit_date INTEGER, visit_type INTEGER, session INTEGER);
        CREATE TABLE moz_inputhistory (place_id INTEGER NOT NULL, input LONGVARCHAR NOT NULL,
            use_count INTEGER, PRIMARY KEY (place_id, input));
        CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER DEFAULT NULL,
            parent INTEGER, position INTEGER, title LONGVARCHAR, guid TEXT);
        CREATE TABLE moz_keywords (id INTEGER PRIMARY KEY AUTOINCREMENT, keyword TEXT UNIQUE,
            place_id INTEGER, post_data TEXT);
        CREATE TABLE moz_annos (id INTEGER PRIMARY KEY, place_id INTEGER NOT NULL,
            anno_attribute_id INTEGER, content LONGVARCHAR);
        CREATE TABLE moz_places_metadata (id INTEGER PRIMARY KEY, place_id INTEGER NOT NULL,
            total_view_time INTEGER NOT NULL DEFAULT 0);
        """

    /// Place 1 is bookmarked, place 2 is only visited, place 3 has a keyword.
    private static let rows = """
        INSERT INTO moz_origins (id, prefix, host, frecency) VALUES
            (1, 'https://', 'bookmarked.example', 100),
            (2, 'https://', 'visited.example', 100),
            (3, 'https://', 'keyword.example', 100);
        INSERT INTO moz_places (id, url, title, visit_count, last_visit_date, foreign_count, origin_id) VALUES
            (1, 'https://bookmarked.example/', 'Bookmarked', 5, 1700000000000000, 1, 1),
            (2, 'https://visited.example/secret', 'Visited', 3, 1700000000000001, 0, 2),
            (3, 'https://keyword.example/?q=%s', 'Keyword', 2, 1700000000000002, 1, 3);
        INSERT INTO moz_historyvisits (place_id, visit_date, visit_type) VALUES
            (1, 1700000000000000, 1), (2, 1700000000000001, 1), (2, 1700000000000003, 1),
            (3, 1700000000000002, 1);
        INSERT INTO moz_inputhistory (place_id, input, use_count) VALUES (2, 'vis', 1);
        INSERT INTO moz_bookmarks (id, type, fk, parent, position, title) VALUES
            (1, 2, NULL, 0, 0, 'root'), (2, 1, 1, 1, 0, 'Bookmarked');
        INSERT INTO moz_keywords (keyword, place_id) VALUES ('kw', 3);
        INSERT INTO moz_annos (place_id, anno_attribute_id, content) VALUES
            (1, 1, 'kept note'), (2, 1, 'downloads/destinationFileURI');
        INSERT INTO moz_places_metadata (place_id, total_view_time) VALUES (1, 10), (2, 20);
        """

    private func makeDatabase() throws {
        try execute(Self.schema + Self.rows)
    }

    private func execute(_ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            defer { sqlite3_free(error) }
            throw NSError(domain: "sqlite", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: error.map { String(cString: $0) } ?? "?"])
        }
    }

    private func column(_ sql: String) throws -> [String] {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK, sql)
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "NULL")
        }
        return values
    }

    func testScanOmitsEmptyHistoryAndReportsUnreadableDatabase() throws {
        try makeDatabase()
        let unknown = directory.appendingPathComponent("unreadable.sqlite")
        let missing = directory.appendingPathComponent("missing.sqlite")
        try Data("invalid database".utf8).write(to: unknown)

        var scan = PrivacyManager.probeHistoryDatabases([database, unknown, missing])
        XCTAssertEqual(scan.available, [database])
        XCTAssertEqual(scan.unreadable, [unknown])

        guard case .cleared = FirefoxHistory.clear(database: database) else {
            return XCTFail("fixture history should clear")
        }
        scan = PrivacyManager.probeHistoryDatabases([database, unknown, missing])
        XCTAssertEqual(scan.available, [])
        XCTAssertEqual(scan.unreadable, [unknown])
        XCTAssertEqual(FirefoxHistory.clear(database: database), .nothingToClear)
        XCTAssertEqual(try column("SELECT title FROM moz_bookmarks ORDER BY id"), ["root", "Bookmarked"])
    }

    func testProbeFindsMetadataWithoutVisits() throws {
        try execute(Self.schema + "INSERT INTO moz_places_metadata (place_id) VALUES (1)")
        XCTAssertEqual(FirefoxHistory.probe(database: database), .available)
    }

    // MARK: - Clearing

    func testHistoryGoesAndBookmarksAndKeywordsStay() throws {
        try makeDatabase()

        guard case .cleared = FirefoxHistory.clear(database: database) else {
            return XCTFail("the clear should succeed on a known schema")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path), "the file is never deleted")
        XCTAssertEqual(try column("SELECT id FROM moz_places ORDER BY id"), ["1", "3"],
                       "the bookmarked and the keyword page stay; the visited-only page goes")
        XCTAssertEqual(try column("SELECT count(*) FROM moz_historyvisits"), ["0"])
        XCTAssertEqual(try column("SELECT count(*) FROM moz_inputhistory"), ["0"])
        XCTAssertEqual(try column("SELECT count(*) FROM moz_places_metadata"), ["0"])
        XCTAssertEqual(try column("SELECT DISTINCT visit_count FROM moz_places"), ["0"])
        XCTAssertEqual(try column("SELECT DISTINCT ifnull(last_visit_date, 'NULL') FROM moz_places"), ["NULL"])
        XCTAssertEqual(try column("SELECT id FROM moz_origins ORDER BY id"), ["1", "3"])
        XCTAssertEqual(try column("SELECT content FROM moz_annos"), ["kept note"],
                       "a bookmarked page keeps its annotations; the deleted page's go")
        XCTAssertEqual(try column("SELECT title FROM moz_bookmarks ORDER BY id"), ["root", "Bookmarked"])
        XCTAssertEqual(try column("SELECT keyword FROM moz_keywords"), ["kw"])
        XCTAssertEqual(try column("SELECT DISTINCT recalc_frecency FROM moz_places"), ["1"])
    }

    func testAPageABookmarkPointsAtStaysEvenWithAStaleCounter() throws {
        try makeDatabase()
        try execute("UPDATE moz_places SET foreign_count = 0")

        _ = FirefoxHistory.clear(database: database)

        XCTAssertEqual(try column("SELECT id FROM moz_places ORDER BY id"), ["1", "3"])
    }

    func testUnknownSchemaTouchesNothing() throws {
        try makeDatabase()
        // Without the counter there is no telling which pages bookmarks use.
        try execute("ALTER TABLE moz_places DROP COLUMN foreign_count")

        XCTAssertEqual(FirefoxHistory.probe(database: database), .unknown)
        guard case .failed = FirefoxHistory.clear(database: database) else {
            return XCTFail("a schema without moz_places.foreign_count must not be cleared")
        }
        XCTAssertEqual(try column("SELECT count(*) FROM moz_historyvisits"), ["4"])
        XCTAssertEqual(try column("SELECT count(*) FROM moz_places"), ["3"])
    }

    func testAFailingStatementRollsBackTheWholeClear() throws {
        try makeDatabase()
        // Stands in for a Firefox trigger this connection cannot run. It fires
        // after the visits are already deleted inside the transaction.
        try execute("""
            CREATE TRIGGER refuse BEFORE DELETE ON moz_places
            BEGIN SELECT RAISE(ABORT, 'refused'); END;
            """)

        guard case .failed(let reason) = FirefoxHistory.clear(database: database) else {
            return XCTFail("the clear must report the failure")
        }
        XCTAssertTrue(reason.contains("refused"), reason)
        XCTAssertEqual(try column("SELECT count(*) FROM moz_historyvisits"), ["4"],
                       "visits deleted earlier in the transaction are back")
        XCTAssertEqual(try column("SELECT count(*) FROM moz_inputhistory"), ["1"])
        XCTAssertEqual(try column("SELECT DISTINCT visit_count FROM moz_places ORDER BY 1"), ["2", "3", "5"])
    }

    func testALockedDatabaseFailsWithoutChanges() throws {
        try makeDatabase()
        var holder: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &holder), SQLITE_OK)
        defer { sqlite3_close(holder) }
        XCTAssertEqual(sqlite3_exec(holder, "BEGIN EXCLUSIVE", nil, nil, nil), SQLITE_OK)

        guard case .failed = FirefoxHistory.clear(database: database, busyTimeout: 50) else {
            return XCTFail("a database another process holds must not be cleared")
        }
        XCTAssertEqual(sqlite3_exec(holder, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(try column("SELECT count(*) FROM moz_historyvisits"), ["4"])
    }

    func testAMissingDatabaseIsNotCreated() {
        guard case .failed = FirefoxHistory.clear(database: database) else {
            return XCTFail("there is nothing to clear")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
    }
}
