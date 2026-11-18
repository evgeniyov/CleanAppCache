import XCTest
import Darwin
@testable import CleanAppCacheLib

final class PathGuardTreeTests: XCTestCase {
    private var scratch: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        scratch = fm.temporaryDirectory.appendingPathComponent("pathguard-tree-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let physical = try XCTUnwrap(realpath(scratch.path, nil))
        defer { free(physical) }
        scratch = URL(fileURLWithPath: String(cString: physical))
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: scratch)
    }

    @discardableResult
    private func directory(_ path: String) throws -> URL {
        let url = scratch.appendingPathComponent(path)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func file(_ path: String) throws -> URL {
        let url = scratch.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("scratch sentinel".utf8).write(to: url)
        return url
    }

    private func link(_ path: String, to target: URL) throws -> URL {
        let url = scratch.appendingPathComponent(path)
        try fm.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    func testContainerDocumentsLinkIsALeafButExplicitLinkRemainsProtected() throws {
        // Both the protected destination and the container are disposable fixtures.
        let destination = try directory("destination/.git/Documents")
        let sentinel = try file("destination/.git/Documents/sentinel")
        let data = try directory("Library/Containers/com.example.fixture/Data")
        let documents = try link("Library/Containers/com.example.fixture/Data/Documents", to: destination)
        let container = data.deletingLastPathComponent()
        XCTAssertEqual(PathGuard.reject(documents), .versionControl)
        XCTAssertEqual(PathGuard.rejectTree(documents), .versionControl)
        XCTAssertNil(PathGuard.rejectTree(container))

        // Exercise the actual recursive remover only against this scratch container.
        let result = DeletionService.delete([container])
        XCTAssertEqual(result.deleted, [container])
        XCTAssertTrue(result.blocked.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: container.path))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "scratch sentinel")
    }

    func testRelativeLinkToProtectedDestinationIsALeaf() throws {
        _ = try directory("destination/.git")
        let container = try directory("container")
        let link = container.appendingPathComponent("relative")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../destination/.git")
        XCTAssertEqual(PathGuard.rejectTree(link), .versionControl)
        XCTAssertNil(PathGuard.rejectTree(container))
    }

    func testScratchTrashMovesContainerAndPreservesLinkedDestination() throws {
        let destination = try directory("destination/Photos.photoslibrary")
        let sentinel = try file("destination/Photos.photoslibrary/sentinel")
        let container = try directory("container")
        _ = try link("container/Pictures", to: destination)
        let moved = scratch.appendingPathComponent("scratch-trash")
        let result = TrashService.trash([container], mover: { url in
            try fm.moveItem(at: url, to: moved)
            return moved
        })
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.blocked.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: container.path))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: moved.appendingPathComponent("Pictures").path),
                       destination.path)
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "scratch sentinel")
    }

    func testDanglingAndCyclicDescendantLinksAreLeaves() throws {
        let container = try directory("container")
        _ = try link("container/dangling", to: scratch.appendingPathComponent("absent"))
        _ = try link("container/self", to: container.appendingPathComponent("self"))
        _ = try link("container/parent", to: container)
        XCTAssertNil(PathGuard.rejectTree(container, limit: 3))
        XCTAssertEqual(PathGuard.rejectTree(container, limit: 2), .unverifiedContents)
    }

    func testLinkDestinationIsNotEnumeratedOrChargedToBudget() throws {
        let destination = try directory("destination")
        _ = try file("destination/a")
        _ = try file("destination/b")
        _ = try directory("destination/nested/.git")
        let container = try directory("container")
        _ = try link("container/link", to: destination)
        XCTAssertNil(PathGuard.rejectTree(container, limit: 1))
        XCTAssertEqual(PathGuard.rejectTree(container, limit: 0), .unverifiedContents)
    }

    func testRealProtectedDescendantsStillBlockWholeTree() throws {
        let cases: [(String, PathGuard.Rejection)] = [
            (".git/objects", .versionControl),
            ("Photos.photoslibrary/originals", .mediaLibrary),
            ("guest.utm/Data", .virtualMachine),
            ("Windows.pvm/Data", .virtualMachine),
            ("guest.vmwarevm/Data", .virtualMachine),
            ("backup.sparsebundle/bands", .backupData),
            (".Spotlight-V100/data", .volumeMetadata)
        ]
        for (index, entry) in cases.enumerated() {
            let tree = try directory("tree-\(index)")
            _ = try directory("tree-\(index)/nested/\(entry.0)")
            XCTAssertEqual(PathGuard.rejectTree(tree), entry.1, entry.0)
        }
    }

    func testGitWorktreePointerFileIsStillProtected() throws {
        let tree = try directory("tree")
        _ = try file("tree/.git")
        XCTAssertEqual(PathGuard.rejectTree(tree), .versionControl)
    }

    func testEmptyDirectoryMissingRootAndRegularFile() throws {
        XCTAssertNil(PathGuard.rejectTree(try directory("empty"), limit: 0))
        XCTAssertNil(PathGuard.rejectTree(scratch.appendingPathComponent("missing")))
        XCTAssertNil(PathGuard.rejectTree(try file("file"), limit: 0))
    }

    func testEveryRealEntryCountsTowardLimit() throws {
        let tree = try directory("tree")
        _ = try file("tree/nested/file")
        XCTAssertNil(PathGuard.rejectTree(tree, limit: 2))
        XCTAssertEqual(PathGuard.rejectTree(tree, limit: 1), .unverifiedContents)
    }

    func testCancellationStopsTraversalAndFailsClosed() throws {
        let tree = try directory("tree")
        try file("tree/a")
        try file("tree/b")
        var visited = 0
        let result = PathGuard.rejectTree(tree, beforeInspect: { url in
            if url.path != tree.path { visited += 1 }
        }, isCancelled: { visited > 0 })

        XCTAssertEqual(result, .unverifiedContents)
        XCTAssertEqual(visited, 1)
        XCTAssertNil(PathGuard.rejectTree(tree))
    }

    func testExplicitAllowedLinkIsNotWalked() throws {
        let destination = try directory("destination")
        _ = try file("destination/.git")
        let alias = try link("alias", to: destination)
        XCTAssertNil(PathGuard.rejectTree(alias, limit: 0))
        XCTAssertEqual(PathGuard.rejectTree(destination), .versionControl)
    }

    func testSymlinkInRootParentIsResolvedAndTreeStillChecked() throws {
        _ = try directory("physical/tree")
        _ = try file("physical/tree/file")
        let alias = try link("alias", to: scratch.appendingPathComponent("physical"))
        XCTAssertNil(PathGuard.rejectTree(alias.appendingPathComponent("tree")))
        _ = try file("physical/tree/.git")
        XCTAssertEqual(PathGuard.rejectTree(alias.appendingPathComponent("tree")), .versionControl)
    }

    func testUnreadableDirectoryFailsClosed() throws {
        guard geteuid() != 0 else { throw XCTSkip("root bypasses scratch POSIX permissions") }
        let tree = try directory("tree")
        let locked = try directory("tree/locked")
        _ = try file("tree/locked/sentinel")
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, 0o700) }
        XCTAssertEqual(PathGuard.rejectTree(tree), .unverifiedContents)
        XCTAssertEqual(PathGuard.rejectTree(locked), .unverifiedContents)
    }

    func testUnreadableLinkDestinationDoesNotMakeContainerUnreadable() throws {
        guard geteuid() != 0 else { throw XCTSkip("root bypasses scratch POSIX permissions") }
        let destination = try directory("destination")
        _ = try file("destination/sentinel")
        let tree = try directory("tree")
        _ = try link("tree/link", to: destination)
        XCTAssertEqual(chmod(destination.path, 0), 0)
        defer { _ = chmod(destination.path, 0o700) }
        XCTAssertNil(PathGuard.rejectTree(tree, limit: 1))
    }

    func testDirectoryReplacedWithLinkBetweenStatAndOpenFailsClosed() throws {
        let tree = try directory("tree")
        let child = try directory("tree/child")
        let destination = try directory("destination")
        _ = try file("destination/.git")
        var visited = false
        let result = PathGuard.rejectTree(tree, beforeInspect: { url in
            guard url.path == child.path else { return }
            visited = true
            do {
                try fm.moveItem(at: child, to: tree.appendingPathComponent("moved"))
                try fm.createSymbolicLink(at: child, withDestinationURL: destination)
            } catch { XCTFail("scratch replacement failed: \(error)") }
        })
        XCTAssertTrue(visited)
        XCTAssertEqual(result, .unverifiedContents)
        XCTAssertTrue(fm.fileExists(atPath: destination.appendingPathComponent(".git").path))
    }

    func testLinkReplacedWithRealProtectedSubtreeFailsClosed() throws {
        let tree = try directory("tree")
        let child = try link("tree/child", to: scratch.appendingPathComponent("absent"))
        var visited = false
        let result = PathGuard.rejectTree(tree, beforeInspect: { url in
            guard url.path == child.path else { return }
            visited = true
            do {
                try fm.removeItem(at: child)
                _ = try file("tree/child/.git")
            } catch { XCTFail("scratch replacement failed: \(error)") }
        })
        XCTAssertTrue(visited)
        XCTAssertEqual(result, .unverifiedContents)
    }

    func testRootReplacedWithLinkFailsClosed() throws {
        let tree = try directory("tree")
        let destination = try directory("destination")
        let result = PathGuard.rejectTree(tree, beforeInspect: { url in
            guard url.path == tree.path else { return }
            do {
                try fm.moveItem(at: tree, to: scratch.appendingPathComponent("moved"))
                try fm.createSymbolicLink(at: tree, withDestinationURL: destination)
            } catch { XCTFail("scratch replacement failed: \(error)") }
        })
        XCTAssertEqual(result, .unverifiedContents)
    }

    func testAncestorLinkRetargetedDuringRootInspectionFailsClosed() throws {
        _ = try directory("first/tree")
        _ = try directory("second/tree")
        let alias = try link("alias", to: scratch.appendingPathComponent("first"))
        let tree = alias.appendingPathComponent("tree")
        let result = PathGuard.rejectTree(tree, beforeInspect: { url in
            guard url.path == tree.path else { return }
            do {
                try fm.removeItem(at: alias)
                try fm.createSymbolicLink(at: alias, withDestinationURL: scratch.appendingPathComponent("second"))
            } catch { XCTFail("scratch replacement failed: \(error)") }
        })
        XCTAssertEqual(result, .unverifiedContents)
    }

    func testDisappearingDescendantFailsClosed() throws {
        let tree = try directory("tree")
        let child = try file("tree/child")
        var visited = false
        let result = PathGuard.rejectTree(tree, beforeInspect: { url in
            guard url.path == child.path else { return }
            visited = true
            do { try fm.removeItem(at: child) }
            catch { XCTFail("scratch removal failed: \(error)") }
        })
        XCTAssertTrue(visited)
        XCTAssertEqual(result, .unverifiedContents)
    }

    func testAlreadyVisitedLinkReplacementIsCaughtByParentMetadata() throws {
        let tree = try directory("tree")
        _ = try link("tree/first", to: scratch.appendingPathComponent("absent"))
        _ = try link("tree/second", to: scratch.appendingPathComponent("absent"))
        var previous: URL?
        var replaced = false
        let result = PathGuard.rejectTree(tree, beforeInspect: { url in
            guard url.path != tree.path else { return }
            guard let first = previous else { previous = url; return }
            guard !replaced else { return }
            replaced = true
            do {
                try fm.removeItem(at: first)
                try fm.createDirectory(at: first.appendingPathComponent(".git"), withIntermediateDirectories: true)
            } catch { XCTFail("scratch replacement failed: \(error)") }
        })
        XCTAssertTrue(replaced)
        XCTAssertEqual(result, .unverifiedContents)
    }

    func testRootLinkReplacementIsNotAcceptedAsAnUnchangedLeaf() throws {
        let original = try file("original")
        let replacement = try file("replacement")
        let alias = try link("alias", to: original)
        let result = PathGuard.rejectTree(alias, beforeInspect: { _ in
            do {
                try fm.removeItem(at: alias)
                try fm.createSymbolicLink(at: alias, withDestinationURL: replacement)
            } catch { XCTFail("scratch replacement failed: \(error)") }
        })
        XCTAssertEqual(result, .unverifiedContents)
    }

    func testProtectedLinkNameStillUsesLexicalDenyPolicy() throws {
        let tree = try directory("tree")
        let destination = try file("destination")
        _ = try link("tree/.git", to: destination)
        XCTAssertEqual(PathGuard.rejectTree(tree), .versionControl)
    }

    func testExcessiveDepthFailsClosed() throws {
        let tree = try directory("tree")
        let deep = (0..<260).map { _ in "d" }.joined(separator: "/")
        _ = try directory("tree/\(deep)")
        XCTAssertEqual(PathGuard.rejectTree(tree), .unverifiedContents)
    }
}
