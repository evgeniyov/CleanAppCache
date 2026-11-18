import XCTest
@testable import CleanAppCacheLib

/// `SystemJunkManager.clean` against a scratch Trash: what moves, what is
/// refused, and what a partial failure leaves behind.
final class SystemJunkCleanTests: XCTestCase {
    private let fm = FileManager.default

    private struct Fixture {
        let root: URL
        let trash: URL
        func mover() -> (URL) throws -> URL {
            { [trash] url in
                let dest = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            }
        }
    }

    private func fixture() throws -> Fixture {
        let root = fm.temporaryDirectory.appendingPathComponent("system-junk-clean-\(UUID().uuidString)")
        let trash = root.appendingPathComponent("Trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(root: root, trash: trash)
    }

    private func folder(_ name: String, in root: URL, payload: String = "junk") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(payload.utf8).write(to: url.appendingPathComponent("file"))
        return url
    }

    func testCleanMovesEveryItemAndReportsWhereItWent() async throws {
        let box = try fixture()
        let a = try folder("a", in: box.root)
        let b = try folder("b", in: box.root)
        let entry = SystemJunkEntry(category: .quickLookCache, urls: [a, b], totalSize: 8)

        let result = await SystemJunkManager.shared.clean(entry, mover: box.mover())

        XCTAssertEqual(Set(result.trashed.map(\.original)), [a, b])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertGreaterThan(result.freedBytes, 0)
        XCTAssertFalse(fm.fileExists(atPath: a.path))
        XCTAssertFalse(fm.fileExists(atPath: b.path))
        for moved in result.trashed {
            XCTAssertTrue(fm.fileExists(atPath: moved.trashed.appendingPathComponent("file").path))
        }
    }

    func testReplacedItemIsRefusedAsChangedAndLeftInPlace() async throws {
        let box = try fixture()
        let kept = try folder("kept", in: box.root)
        let swapped = try folder("swapped", in: box.root)
        let entry = SystemJunkEntry(category: .quickLookCache, urls: [kept, swapped], totalSize: 8)
        try fm.moveItem(at: swapped, to: box.root.appendingPathComponent("held"))
        _ = try folder("swapped", in: box.root, payload: "user data")

        let result = await SystemJunkManager.shared.clean(entry, mover: box.mover())

        XCTAssertEqual(result.trashed.map(\.original), [kept])
        XCTAssertEqual(result.failed, [swapped])
        XCTAssertEqual(result.obstacles[swapped], .changedSinceScan)
        XCTAssertEqual(try String(contentsOf: swapped.appendingPathComponent("file")), "user data")
    }

    func testProtectedLocationIsBlockedAndNeverReachesTheMover() async throws {
        let box = try fixture()
        let home = fm.homeDirectoryForCurrentUser
        let entry = SystemJunkEntry(category: .xcodeDeviceLogs, urls: [home], totalSize: 1)

        let result = await SystemJunkManager.shared.clean(entry) { _ in
            XCTFail("PathGuard must stop the home folder before any move")
            return box.trash
        }

        XCTAssertEqual(result.blocked, [home])
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: home.path))
    }

    func testPartialFailureKeepsSurvivorsWithTheSameRowIdentity() async throws {
        let box = try fixture()
        let moved = try folder("moved", in: box.root)
        let stuck = try folder("stuck", in: box.root)
        let entry = SystemJunkEntry(category: .quickLookCache, urls: [moved, stuck], totalSize: 8)
        let real = box.mover()

        let result = await SystemJunkManager.shared.clean(entry) { url in
            if url == stuck { throw CocoaError(.fileWriteUnknown) }
            return try real(url)
        }

        XCTAssertEqual(result.trashed.map(\.original), [moved])
        XCTAssertEqual(result.failed, [stuck])
        XCTAssertTrue(fm.fileExists(atPath: stuck.path))

        let survivor = entry.keeping(urls: result.failed, totalSize: 4)
        XCTAssertEqual(survivor.id, entry.id)
        XCTAssertEqual(survivor.urls, [stuck])
        XCTAssertTrue(survivor.matches(stuck))
        XCTAssertFalse(survivor.matches(moved))
    }

    func testMissingItemCountsAsAlreadyGoneNotFailure() async throws {
        let box = try fixture()
        let present = try folder("present", in: box.root)
        let gone = box.root.appendingPathComponent("gone")
        let entry = SystemJunkEntry(category: .quickLookCache, urls: [present, gone], totalSize: 8)
        try fm.removeItem(at: present)

        let result = await SystemJunkManager.shared.clean(entry, mover: box.mover())

        XCTAssertEqual(Set(result.alreadyGone), [present, gone])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.trashed.isEmpty)
    }
}
