import XCTest
@testable import CleanAppCacheLib

final class DuplicateCoverageTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("duplicate-coverage-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: root)
    }

    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: 8192).write(to: url)
        return url
    }

    func testMissingRootReportsIncompleteCoverage() async {
        let missing = root.appendingPathComponent("missing")
        let result = await DuplicateFinder.shared.findDuplicates(in: missing, minSize: 1) { _, _ in }
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(result.skipped.needsNotice)
        XCTAssertEqual(result.skipped.paths.first?.path, missing.path)
        XCTAssertGreaterThan(result.skipped.counts[.unreadable] ?? 0, 0)
    }

    func testReadableEmptyRootIsComplete() async {
        let result = await DuplicateFinder.shared.findDuplicates(in: root, minSize: 1) { _, _ in }
        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertFalse(result.skipped.needsNotice)
    }

    func testUnreadableSubfolderDoesNotHideReadableDuplicateGroup() async throws {
        _ = try file("first")
        _ = try file("second")
        let hiddenFile = try file("restricted/third")
        let restricted = hiddenFile.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }

        let result = await DuplicateFinder.shared.findDuplicates(in: root, minSize: 1) { _, _ in }

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups.first?.files.count, 2)
        XCTAssertTrue(result.skipped.needsNotice)
        XCTAssertTrue(result.skipped.paths.contains {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == restricted.resolvingSymlinksInPath().path
                && $0.reason == .unreadable
        })
    }

    func testUnreadableHashCandidateIsReported() async throws {
        _ = try file("readable")
        let blocked = try file("unreadable")
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path) }

        let result = await DuplicateFinder.shared.findDuplicates(in: root, minSize: 1) { _, _ in }

        XCTAssertTrue(result.groups.isEmpty)
        XCTAssertTrue(result.skipped.needsNotice)
        XCTAssertEqual(result.skipped.counts[.unreadable], 1)
        XCTAssertEqual(result.skipped.paths.first.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path },
                       blocked.resolvingSymlinksInPath().path)
    }
}
