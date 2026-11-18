import XCTest
import Darwin
@testable import CleanAppCacheLib

final class RemovalBoundaryIdentityTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("removal-boundary-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func file(_ relative: String, text: String = "selected") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func replace(_ url: URL) throws {
        try fm.moveItem(at: url, to: root.appendingPathComponent("held-\(UUID().uuidString)"))
        try Data("replacement".utf8).write(to: url)
    }

    func testPermanentDeleteKeepsObjectReplacedDuringValidation() throws {
        let selected = try file("selected")
        let result = DeletionService.delete([selected], validation: { url in
            do { try self.replace(url) } catch { XCTFail("\(error)") }
            return true
        })

        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.failed, [selected])
        XCTAssertEqual(result.obstacles[selected], .changedSinceScan)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertEqual(try String(contentsOf: selected), "replacement")
    }

    func testTrashKeepsObjectReplacedDuringValidation() throws {
        let selected = try file("selected")
        var moved = false
        let result = TrashService.trash([selected], validation: { url in
            do { try self.replace(url) } catch { XCTFail("\(error)") }
            return true
        }, mover: { url in
            moved = true
            let destination = self.root.appendingPathComponent("scratch-trash")
            try self.fm.moveItem(at: url, to: destination)
            return destination
        })

        XCTAssertFalse(moved)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.failed, [selected])
        XCTAssertEqual(result.validationRejected, [selected])
        XCTAssertEqual(result.obstacles[selected], .changedSinceScan)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertEqual(try String(contentsOf: selected), "replacement")
    }

    func testPermanentDeletePinsTheWholeBatchBeforeProcessingItsFirstItem() throws {
        let first = try file("first")
        let second = try file("second")
        let result = DeletionService.delete([first, second], validation: { url in
            if url == first {
                do { try self.replace(second) } catch { XCTFail("\(error)") }
            }
            return true
        })

        XCTAssertEqual(result.deleted, [first])
        XCTAssertEqual(result.failed, [second])
        XCTAssertEqual(result.obstacles[second], .changedSinceScan)
        XCTAssertEqual(try String(contentsOf: second), "replacement")
    }

    func testTrashPinsTheWholeBatchBeforeProcessingItsFirstItem() throws {
        let first = try file("first")
        let second = try file("second")
        let result = TrashService.trash([first, second], validation: { url in
            if url == first {
                do { try self.replace(second) } catch { XCTFail("\(error)") }
            }
            return true
        }, mover: { url in
            let destination = self.root.appendingPathComponent("trash-" + url.lastPathComponent)
            try self.fm.moveItem(at: url, to: destination)
            return destination
        })

        XCTAssertEqual(result.trashed.map(\.original), [first])
        XCTAssertEqual(result.failed, [second])
        XCTAssertEqual(result.validationRejected, [second])
        XCTAssertEqual(result.obstacles[second], .changedSinceScan)
        XCTAssertEqual(try String(contentsOf: second), "replacement")
    }

    func testPermanentDeleteKeepsTargetAfterParentRedirection() throws {
        let selected = try file("parent/selected")
        let replacement = try file("other/selected", text: "replacement")
        let parent = selected.deletingLastPathComponent()
        let result = DeletionService.delete([selected], validation: { _ in
            do {
                try self.fm.moveItem(at: parent, to: self.root.appendingPathComponent("held-parent"))
                try self.fm.createSymbolicLink(at: parent, withDestinationURL: replacement.deletingLastPathComponent())
            } catch { XCTFail("\(error)") }
            return true
        })

        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.obstacles[selected], .changedSinceScan)
        XCTAssertEqual(try String(contentsOf: replacement), "replacement")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("held-parent/selected")), "selected")
    }

    func testTrashKeepsTargetAfterParentRedirection() throws {
        let selected = try file("parent/selected")
        let replacement = try file("other/selected", text: "replacement")
        let parent = selected.deletingLastPathComponent()
        var moved = false
        let result = TrashService.trash([selected], validation: { _ in
            do {
                try self.fm.moveItem(at: parent, to: self.root.appendingPathComponent("held-parent"))
                try self.fm.createSymbolicLink(at: parent, withDestinationURL: replacement.deletingLastPathComponent())
            } catch { XCTFail("\(error)") }
            return true
        }, mover: { url in moved = true; return url })

        XCTAssertFalse(moved)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.obstacles[selected], .changedSinceScan)
        XCTAssertEqual(try String(contentsOf: replacement), "replacement")
    }

    func testFinderDispatchKeepsObjectReplacedDuringValidation() throws {
        let selected = try file("selected")
        var dispatched = false
        let result = TrashService.trashWithFinder([selected], knownSizes: [:], allowing: [], validation: { url in
            do { try self.replace(url) } catch { XCTFail("\(error)") }
            return true
        }, dispatch: { _ in
            dispatched = true
            return .init(status: 1, stdout: "", stderr: "fixture must not dispatch", timedOut: false)
        })

        XCTAssertFalse(dispatched)
        XCTAssertEqual(result.failed, [selected])
        XCTAssertEqual(result.validationRejected, [selected])
        XCTAssertEqual(result.obstacles[selected], .changedSinceScan)
        XCTAssertEqual(try String(contentsOf: selected), "replacement")
    }

    func testFinderDispatchRechecksEarlierItemsAfterTheBatchValidation() throws {
        let first = try file("first")
        let second = try file("second")
        var dispatched: [String] = []
        let result = TrashService.trashWithFinder([first, second], knownSizes: [:], allowing: [], validation: { url in
            if url == second {
                do { try self.replace(first) } catch { XCTFail("\(error)") }
            }
            return true
        }, dispatch: { paths in
            dispatched = paths
            return .init(status: 1, stdout: "", stderr: "fixture", timedOut: false)
        })

        XCTAssertEqual(dispatched, [second.path])
        XCTAssertTrue(result.validationRejected.contains(first))
        XCTAssertEqual(result.obstacles[first], .changedSinceScan)
        XCTAssertEqual(try String(contentsOf: first), "replacement")
    }

    func testFinderEscalationRetainsTheIdentityFromTheOrdinaryAttempt() throws {
        let selected = try file("selected")
        let identities = RemovalIdentity.capture([selected])
        let first = TrashService.Result(trashed: [], failed: [selected],
                                       obstacles: [selected: .needsAdmin], freedBytes: 0)
        try replace(selected)
        var dispatched = false
        let result = TrashService.escalate(first, knownSizes: [:], allowing: [], validation: { _ in true },
                                          identities: identities, dispatch: { _ in
            dispatched = true
            return .init(status: 1, stdout: "", stderr: "fixture must not dispatch", timedOut: false)
        })

        XCTAssertFalse(dispatched)
        XCTAssertEqual(result.failed, [selected])
        XCTAssertEqual(result.validationRejected, [selected])
        XCTAssertEqual(result.obstacles[selected], .changedSinceScan)
        XCTAssertEqual(try String(contentsOf: selected), "replacement")
    }

    func testMissingSuppliedIdentityCannotBeRecapturedForTrash() throws {
        let selected = try file("selected")
        var moved = false
        let result = TrashService.trash([selected], identities: [:], mover: { url in moved = true; return url })

        XCTAssertFalse(moved)
        XCTAssertEqual(result.obstacles[selected], .changedSinceScan)
        XCTAssertEqual(try String(contentsOf: selected), "selected")
    }

    func testPermissionRollbackCannotFollowAReplacementParentLink() throws {
        guard geteuid() != 0 else { throw XCTSkip("root bypasses scratch POSIX permissions") }
        let selectedFile = try file("selected/locked/file")
        let locked = selectedFile.deletingLastPathComponent()
        let selected = locked.deletingLastPathComponent()
        let otherFile = try file("other/locked/file", text: "unrelated")
        let otherLocked = otherFile.deletingLastPathComponent()
        let held = root.appendingPathComponent("held")
        XCTAssertEqual(chmod(locked.path, 0o555), 0)
        XCTAssertEqual(chmod(otherLocked.path, 0o755), 0)
        defer {
            _ = chmod(locked.path, 0o755)
            _ = chmod(held.appendingPathComponent("locked").path, 0o755)
            _ = chmod(otherLocked.path, 0o755)
        }
        var validations = 0
        let result = DeletionService.delete([selected], validation: { _ in
            validations += 1
            if validations == 3 {
                do {
                    try self.fm.moveItem(at: selected, to: held)
                    try self.fm.createSymbolicLink(at: selected, withDestinationURL: otherLocked.deletingLastPathComponent())
                } catch { XCTFail("\(error)") }
            }
            return true
        })

        XCTAssertEqual(validations, 3, "the fixture must reach the post-repair validation")
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.obstacles[selected], .changedSinceScan)
        var otherInfo = stat()
        XCTAssertEqual(lstat(otherLocked.path, &otherInfo), 0)
        XCTAssertEqual(otherInfo.st_mode & 0o777, 0o755, "rollback must not chmod through the new link")
        var selectedInfo = stat()
        XCTAssertEqual(lstat(held.appendingPathComponent("locked").path, &selectedInfo), 0)
        XCTAssertEqual(selectedInfo.st_mode & 0o777, 0o555, "the originally repaired directory regains its permissions")
        XCTAssertEqual(try String(contentsOf: otherFile), "unrelated")
    }

    func testReadOnlyTreeRepairStillDeletesWithoutFollowingChildLinks() throws {
        guard geteuid() != 0 else { throw XCTSkip("root bypasses scratch POSIX permissions") }
        let selectedFile = try file("selected/locked/file")
        let locked = selectedFile.deletingLastPathComponent()
        let selected = locked.deletingLastPathComponent()
        let externalFile = try file("external/.git/locked/file", text: "outside")
        let externalLocked = externalFile.deletingLastPathComponent()
        try fm.createSymbolicLink(at: selected.appendingPathComponent("external-link"),
                                  withDestinationURL: externalLocked.deletingLastPathComponent())
        XCTAssertEqual(chmod(locked.path, 0o555), 0)
        XCTAssertEqual(chmod(externalLocked.path, 0o555), 0)
        defer {
            _ = chmod(locked.path, 0o755)
            _ = chmod(externalLocked.path, 0o755)
        }

        let result = DeletionService.delete([selected])

        XCTAssertEqual(result.deleted, [selected])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(RemovalCheck.isMissing(selected))
        XCTAssertEqual(try String(contentsOf: externalFile), "outside")
        var info = stat()
        XCTAssertEqual(lstat(externalLocked.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o555)
    }
}
