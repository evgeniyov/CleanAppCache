import XCTest
@testable import CleanAppCacheLib

final class LogTests: XCTestCase {

    private let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("log_\(UUID().uuidString)", isDirectory: true)

    private var fileURL: URL { dir.appendingPathComponent("app.log") }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func permissions(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testAppendsToExistingFile() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("first\n".utf8).write(to: fileURL)

        Log.append(Data("second\n".utf8), to: fileURL)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "first\nsecond\n")
    }

    func testCreatesMissingFileOwnerOnly() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        Log.append(Data("line\n".utf8), to: fileURL)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "line\n")
        XCTAssertEqual(try permissions(fileURL), 0o600)
    }

    func testRecreatesDeletedDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        Log.append(Data("before\n".utf8), to: fileURL)
        try fm.removeItem(at: dir)

        Log.append(Data("after\n".utf8), to: fileURL)

        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "after\n")
        XCTAssertEqual(try permissions(dir), 0o700)
        XCTAssertEqual(try permissions(fileURL), 0o600)
    }

    func testScannerNeverOffersTheLogFolder() throws {
        let logs = try XCTUnwrap(Log.directory)
        XCTAssertEqual(logs.lastPathComponent, "CleanAppCache")
        XCTAssertTrue(Scanner.excludedChildPaths.contains(logs.standardizedFileURL.path))
    }
}
