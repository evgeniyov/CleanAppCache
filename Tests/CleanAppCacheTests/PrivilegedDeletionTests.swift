import XCTest
import Darwin
@testable import CleanAppCacheLib

/// The root delete, the Finder hand-off and the write-bit repair act with
/// more rights than the user's own deletes, so what they may reach is pinned
/// down here. Nothing escalates: the commands run as the test's own user.
final class PrivilegedDeletionTests: XCTestCase {

    private func scratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            _ = Self.run("/bin/chmod -R u+rwx '\(dir.path)'")
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    @discardableResult
    private static func run(_ command: String) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    func testPinnedRemovalDeletesTheValidatedEntry() throws {
        let dir = try scratch("pinned_ok")
        let target = dir.appendingPathComponent("it's here")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(count: 10).write(to: target.appendingPathComponent("f"))

        XCTAssertEqual(Self.run(DeletionService.pinnedRemoval(target)), 0)
        XCTAssertTrue(RemovalCheck.isMissing(target))
    }

    /// The folder was validated, then swapped for a link while the password
    /// dialog was up: the command must refuse rather than follow it.
    func testPinnedRemovalRefusesAParentSwappedForALink() throws {
        let dir = try scratch("pinned_swap")
        let parent = dir.appendingPathComponent("Trash")
        let elsewhere = dir.appendingPathComponent("Elsewhere")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("victim"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("victim"),
                                                withIntermediateDirectories: true)
        let command = DeletionService.pinnedRemoval(parent.appendingPathComponent("victim"))

        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: elsewhere)

        XCTAssertNotEqual(Self.run(command), 0)
        XCTAssertFalse(RemovalCheck.isMissing(elsewhere.appendingPathComponent("victim")),
                       "the link's target must survive")
    }

    func testAdministratorBundleTargetRefusesALinkToAnotherApp() throws {
        let dir = try scratch("bundle_link")
        let real = dir.appendingPathComponent("Real.app")
        try writeTestApplication(real)
        let link = dir.appendingPathComponent("Other.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertNotNil(DeletionService.administratorBundleTarget(for: real, allowedRoots: [dir.path]))
        XCTAssertNil(DeletionService.administratorBundleTarget(for: link, allowedRoots: [dir.path]),
                     "a link must never hand root the app it points to")
    }

    /// A failed delete of a link must not change permissions inside the
    /// directory the link points to.
    func testWriteBitRepairNeverFollowsALink() throws {
        let dir = try scratch("repair_link")
        let target = dir.appendingPathComponent("target")
        let locked = target.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(locked.path, 0o555), 0)
        let parent = dir.appendingPathComponent("readonly")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(chmod(parent.path, 0o555), 0)

        let result = DeletionService.delete([link])

        XCTAssertEqual(result.failed, [link])
        var st = stat()
        XCTAssertEqual(lstat(locked.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o555, "the link's target was left as it was")
    }

    func testAFolderThatCannotBeReadCountsAsInUse() throws {
        let dir = try scratch("unreadable")
        let inner = dir.appendingPathComponent("private")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data(count: 1).write(to: inner.appendingPathComponent("live.sock"))
        // Old enough on the outside, unreadable inside.
        let old = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: inner.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
        XCTAssertEqual(chmod(inner.path, 0o311), 0)

        XCTAssertTrue(Scanner.touchedRecently(dir, within: 3600))
    }

    /// SIP's own territory and the `sunlnk` folders system services keep in
    /// the user's temp directory are reported as protected by the system —
    /// not as a privacy setting the user could change — and never offered.
    func testSystemProtectedItemsAreRecognised() throws {
        XCTAssertTrue(RemovalCheck.isSystemProtected(URL(fileURLWithPath: "/System/Library")))
        XCTAssertEqual(RemovalCheck.trashObstacle(at: URL(fileURLWithPath: "/System/Library")), .systemProtected)

        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).deletingLastPathComponent()
            .appendingPathComponent("T")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: nil)) ?? []
        guard let guarded = entries.first(where: { url in
            var st = stat()
            return lstat(url.path, &st) == 0 && st.st_flags & UInt32(SF_NOUNLINK) != 0
        }) else {
            throw XCTSkip("no sunlnk folder in \(temp.path) on this machine")
        }
        XCTAssertTrue(RemovalCheck.isSystemProtected(guarded))
        XCTAssertEqual(RemovalCheck.trashObstacle(at: guarded), .systemProtected)
    }

    func testAFolderOfTheUsersOwnIsNotSystemProtected() throws {
        let dir = try scratch("own")
        XCTAssertFalse(RemovalCheck.isSystemProtected(dir))
    }
}
