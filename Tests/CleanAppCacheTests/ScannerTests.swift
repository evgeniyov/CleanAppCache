import XCTest
import Darwin
@testable import CleanAppCacheLib

final class ScannerTests: XCTestCase {
    
    func testScanResultFormatting() {
        let items = [
            CleanableItem(
                url: URL(fileURLWithPath: "/tmp/test1"),
                category: .tempFiles,
                size: 1024,
                itemCount: 1
            ),
            CleanableItem(
                url: URL(fileURLWithPath: "/tmp/test2"),
                category: .tempFiles,
                size: 2048,
                itemCount: 1
            )
        ]

        let result = ScanResult(
            items: items,
            totalSize: 3072,
            duration: 1.0,
            categorySizes: [.tempFiles: 3072]
        )
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.totalSize, 3072)
        // Locale-independent: see the note in AppManagerTests.
        XCTAssertEqual(result.formattedTotalSize, Fmt.bytes(UInt64(3072)))
        XCTAssertTrue(result.formattedTotalSize.contains(where: { $0.isLetter }),
                      "formatted size lost its unit: \(result.formattedTotalSize)")
        XCTAssertEqual(result.items(for: .tempFiles).count, 2)
        XCTAssertEqual(result.size(for: .tempFiles), 3072)
        XCTAssertEqual(result.size(for: .logs), 0)
    }
    
    func testCalculateSizeForExistingFile() async {
        let scanner = Scanner.shared
        let tempDir = FileManager.default.temporaryDirectory
        let testFile = tempDir.appendingPathComponent("scanner_test_\(UUID().uuidString).txt")
        
        let content = "Hello, this is a test file for scanner."
        try? content.write(to: testFile, atomically: true, encoding: .utf8)
        
        let size = scanner.calculateSize(at: testFile)
        XCTAssertGreaterThan(size, 0)
        
        try? FileManager.default.removeItem(at: testFile)
    }
    
    func testCalculateSizeForNonExistentPath() async {
        let scanner = Scanner.shared
        let fakeURL = URL(fileURLWithPath: "/nonexistent/path/that/should/not/exist")
        let size = scanner.calculateSize(at: fakeURL)
        XCTAssertEqual(size, 0)
    }
    
    func testCleanableItemEquality() {
        let url = URL(fileURLWithPath: "/tmp/test")
        let item1 = CleanableItem(url: url, category: .userCache, size: 100, itemCount: 1)
        let item2 = CleanableItem(url: url, category: .userCache, size: 100, itemCount: 1)

        XCTAssertEqual(item1, item2)
        XCTAssertEqual(item1.name, "test")
        XCTAssertEqual(item1.path, "/tmp/test")
    }

    func testRiskyCategoriesAreNotAutoCleaned() {
        XCTAssertFalse(ScanCategory.systemCache.isSafeToAutoClean)
        XCTAssertFalse(ScanCategory.trash.isSafeToAutoClean)
        XCTAssertFalse(ScanCategory.browserJunk.isSafeToAutoClean)
        XCTAssertFalse(ScanCategory.installers.isSafeToAutoClean)
        XCTAssertTrue(ScanCategory.userCache.isSafeToAutoClean)
    }

    func testDeletionServicePermanentlyDeletes() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deletion_test_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("victim.txt")
        try "some bytes".write(to: file, atomically: true, encoding: .utf8)

        let result = DeletionService.delete([file])

        XCTAssertEqual(result.deleted, [file])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: file.path))

        try? fm.removeItem(at: dir)
    }

    func testDeletionServiceBatchReportsPartialResults() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deletion_batch_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appendingPathComponent("a.bin")
        let b = dir.appendingPathComponent("b.bin")
        let missing = dir.appendingPathComponent("missing.bin")
        try Data(count: 64_000).write(to: a)
        try Data(count: 64_000).write(to: b)

        let result = DeletionService.delete([a, missing, b])

        XCTAssertEqual(result.deleted, [a, b])
        XCTAssertEqual(result.alreadyGone, [missing], "a file that is already gone is not a failure")
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.blocked.isEmpty)
        XCTAssertGreaterThan(result.freedBytes, 0)
        XCTAssertTrue(fm.fileExists(atPath: dir.path), "only the listed URLs are deleted")
        let remaining = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertTrue(remaining.isEmpty)

        try? fm.removeItem(at: dir)
    }

    func testDeletionServiceReportsMissingItemsAsAlreadyGone() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        let result = DeletionService.delete([missing])
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.alreadyGone, [missing])
    }

    func testDeletionServiceNamesALockedFileAsTheObstacle() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("deletion_locked_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("locked.bin")
        try Data(count: 1024).write(to: file)
        XCTAssertEqual(chflags(file.path, UInt32(UF_IMMUTABLE)), 0)
        addTeardownBlock {
            chflags(file.path, 0)
            try? FileManager.default.removeItem(at: dir)
        }

        let result = DeletionService.delete([file])

        XCTAssertEqual(result.failed, [file])
        XCTAssertEqual(result.obstacles[file], .locked)
        XCTAssertTrue(fm.fileExists(atPath: file.path))
    }

    /// Package managers leave read-only trees (the Go module cache is the
    /// common one). The owner may make them writable, so the delete must not
    /// stop half-way through one.
    func testDeletionServiceRemovesAReadOnlyTreeTheUserOwns() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("deletion_readonly_\(UUID().uuidString)")
        let inner = root.appendingPathComponent("pkg@v1.0/sub")
        try fm.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data(count: 2048).write(to: inner.appendingPathComponent("a.go"))
        for dir in [inner, inner.deletingLastPathComponent(), root] {
            XCTAssertEqual(chmod(dir.path, 0o555), 0)
        }
        addTeardownBlock {
            for dir in [root, inner.deletingLastPathComponent(), inner] { chmod(dir.path, 0o755) }
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertNil(RemovalCheck.deleteObstacle(at: root), "no administrator is needed for the user's own tree")

        let result = DeletionService.delete([root])

        XCTAssertEqual(result.deleted, [root])
        XCTAssertFalse(fm.fileExists(atPath: root.path))
    }

    // MARK: - Administrator delete scope

    func testAdministratorDeleteReachesOnlyItsThreePlaces() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func allowed(_ relative: String) -> Bool {
            DeletionService.administratorTarget(for: home.appendingPathComponent(relative)) != nil
        }
        XCTAssertTrue(allowed(".Trash/Shottr.app"))
        XCTAssertTrue(allowed(".Trash/folder/inner"))
        XCTAssertTrue(allowed("Library/Caches/com.example.app"))
        XCTAssertTrue(allowed("Library/Group Containers/ABCDE12345.com.example.app"))
        XCTAssertTrue(allowed("Library/Preferences/ByHost/com.example.app.1234.plist"))

        XCTAssertFalse(allowed(".Trash"), "the Trash itself")
        XCTAssertFalse(allowed("Library/Caches"), "a search folder itself")
        XCTAssertFalse(allowed("Library/Caches/com.example.app/nested"), "deeper than one app's entry")
        XCTAssertFalse(allowed("Library/Keychains/login.keychain-db"))
        XCTAssertFalse(allowed("Documents/report.pdf"))
        XCTAssertFalse(allowed("Library/Caches/../Keychains"))
        XCTAssertNil(DeletionService.administratorTarget(for: URL(fileURLWithPath: "/usr/bin/true")))
        XCTAssertNil(DeletionService.administratorTarget(for: URL(fileURLWithPath: "/Library/Caches/x")))
    }
}
