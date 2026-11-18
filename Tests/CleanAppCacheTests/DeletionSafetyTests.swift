import XCTest
import Darwin
@testable import CleanAppCacheLib

/// Covers the safety-critical, destructive paths: reversible trashing/undo,
/// duplicate detection (whose results are auto-selected for deletion), and the
/// size-cache invalidation that keeps the Storage view honest after a cleanup.
final class DeletionSafetyTests: XCTestCase {

    // MARK: - TrashService (reversible delete + undo)

    func testTrashServiceMovesToTrashAndRestores() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("trash_rt_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let file = dir.appendingPathComponent("note.txt")
        try "hello world".write(to: file, atomically: true, encoding: .utf8)

        let trash = dir.appendingPathComponent("ScratchTrash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let result = TrashService.trash([file], mover: { original in
            let destination = trash.appendingPathComponent(original.lastPathComponent)
            try fm.moveItem(at: original, to: destination)
            return destination
        })
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertGreaterThan(result.freedBytes, 0)
        XCTAssertFalse(fm.fileExists(atPath: file.path), "file should have left its original location")

        let restored = TrashService.restore(result.trashed)
        XCTAssertEqual(restored, 1)
        XCTAssertTrue(fm.fileExists(atPath: file.path), "undo should put the file back")
    }

    func testTrashServiceReportsAMissingFileAsAlreadyGone() {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")
        let result = TrashService.trash([missing])
        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.alreadyGone, [missing])
    }

    /// Moving a directory to another folder rewrites its `..` entry, so it
    /// needs write access to the directory itself — the preflight must say
    /// so rather than promise a move that fails.
    func testTrashPreflightNeedsWriteAccessToADirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("trash_probe_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            chmod(dir.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertNil(RemovalCheck.trashObstacle(at: dir))
        XCTAssertEqual(chmod(dir.path, 0o555), 0)
        XCTAssertEqual(RemovalCheck.trashObstacle(at: dir), .needsAdmin)
    }

    // MARK: - DuplicateFinder (auto-selected for deletion → must be exact)

    func testDuplicateFinderGroupsOnlyTrueDuplicates() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dup_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // a and b are byte-identical; c is the SAME SIZE but different content —
        // it must NOT be grouped (that would auto-select a unique file to delete).
        let identical = Data(repeating: 0xAB, count: 4096)
        try identical.write(to: dir.appendingPathComponent("a.bin"))
        try identical.write(to: dir.appendingPathComponent("b.bin"))
        try Data(repeating: 0xCD, count: 4096).write(to: dir.appendingPathComponent("c.bin"))

        let result = await DuplicateFinder.shared.findDuplicates(in: dir, minSize: 1) { _, _ in }

        XCTAssertEqual(result.groups.count, 1, "exactly one duplicate group expected")
        XCTAssertEqual(result.groups.first?.count, 2, "only a.bin and b.bin are duplicates")
        XCTAssertEqual(result.groups.first?.wastedBytes, 4096)
        XCTAssertEqual(result.totalReclaimable, 4096)
    }

    /// The 64 KB partial hash only narrows; the full hash decides. Files that
    /// agree for their first 64 KB and differ after it are not duplicates, and
    /// files of different sizes that share a prefix never meet in one group.
    func testDuplicateFinderSeparatesSharedPrefixes() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dup_prefix_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let prefix = Data(repeating: 0x5A, count: 65_536)
        func file(_ name: String, tail: UInt8, tailLength: Int) throws {
            try (prefix + Data(repeating: tail, count: tailLength))
                .write(to: dir.appendingPathComponent(name))
        }
        // Same size, same prefix, different tails: one pair of true copies
        // (a1, a2) and one file that only looks like them (a3).
        try file("a1.bin", tail: 1, tailLength: 4096)
        try file("a2.bin", tail: 1, tailLength: 4096)
        try file("a3.bin", tail: 2, tailLength: 4096)
        // A longer pair with the same prefix: its own group, its own size.
        try file("b1.bin", tail: 1, tailLength: 8192)
        try file("b2.bin", tail: 1, tailLength: 8192)
        // Same size as b, same prefix, different tail, no copy of its own.
        try file("c1.bin", tail: 3, tailLength: 8192)

        let result = await DuplicateFinder.shared.findDuplicates(in: dir, minSize: 1) { _, _ in }

        let groups = result.groups
            .map { group in (group.size, Set(group.files.map(\.name))) }
            .sorted { $0.0 < $1.0 }
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.0, UInt64(65_536 + 4096))
        XCTAssertEqual(groups.first?.1, ["a1.bin", "a2.bin"])
        XCTAssertEqual(groups.last?.0, UInt64(65_536 + 8192))
        XCTAssertEqual(groups.last?.1, ["b1.bin", "b2.bin"])
    }

    func testDuplicateFinderIgnoresUniqueSizes() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dup_uniq_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try Data(repeating: 1, count: 1000).write(to: dir.appendingPathComponent("x.bin"))
        try Data(repeating: 2, count: 2000).write(to: dir.appendingPathComponent("y.bin"))

        let result = await DuplicateFinder.shared.findDuplicates(in: dir, minSize: 1) { _, _ in }
        XCTAssertTrue(result.groups.isEmpty)
    }

    // MARK: - DiskCacheManager invalidation

    func testDiskCacheInvalidateUnderPrefix() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskCacheManager(directory: dir)
        let root = "/tmp/cac_test_\(UUID().uuidString)"
        await cache.setSize(1000, for: root + "/a", isDirectory: false)
        await cache.setSize(2000, for: root + "/sub/b", isDirectory: true)

        let a = await cache.getSize(for: root + "/a")
        XCTAssertEqual(a, 1000)

        await cache.invalidate(under: root)

        let a2 = await cache.getSize(for: root + "/a")
        let b2 = await cache.getSize(for: root + "/sub/b")
        XCTAssertNil(a2, "prefix invalidation should drop nested entries")
        XCTAssertNil(b2)
    }

    func testDiskCacheInvalidateExactPaths() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = DiskCacheManager(directory: dir)
        let key = "/tmp/cac_exact_\(UUID().uuidString)"
        await cache.setSize(500, for: key, isDirectory: false)
        // The awaits are hoisted out of the assertions: XCTAssert's autoclosure
        // is not async, so `XCTAssertEqual(await …)` does not compile.
        let stored = await cache.getSize(for: key)
        XCTAssertEqual(stored, 500)

        await cache.invalidate(paths: [key])
        let afterInvalidation = await cache.getSize(for: key)
        XCTAssertNil(afterInvalidation)
    }
}
