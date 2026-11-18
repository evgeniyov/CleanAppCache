import XCTest
import SQLite3
@testable import CleanAppCacheLib

final class AuditRegressionTests: XCTestCase {
    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("audit-regression-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ name: String, _ text: String = "synthetic") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testVMNamesWithDotsAreProtectedEverywhereOutsideKnownCacheEntries() throws {
        for name in ["Ubuntu.24.utm", "Windows.11.pvm", "Ubuntu.test.vmwarevm", "com.utmapp.utm"] {
            let disk = try write("\(name)/disk.img")
            XCTAssertEqual(PathGuard.reject(disk), .virtualMachine)
            let deleted = DeletionService.delete([disk])
            XCTAssertEqual(deleted.blocked, [disk])
            XCTAssertTrue(FileManager.default.fileExists(atPath: disk.path))
        }
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.utmapp.utm")
        XCTAssertNil(PathGuard.reject(cache))
    }

    func testProtectedDescendantBlocksRecursiveDeletionAndTrash() throws {
        let file = try write("cache/.git/objects/sentinel")
        let folder = root.appendingPathComponent("cache")
        XCTAssertNil(PathGuard.reject(folder))
        XCTAssertEqual(PathGuard.rejectTree(folder), .versionControl)
        XCTAssertEqual(DeletionService.delete([folder]).blocked, [folder])
        let result = TrashService.trash([folder], mover: { _ in
            XCTFail("a protected descendant must prevent the move")
            return folder
        })
        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testTreeVerificationFailsClosedWhenBudgetIsExceeded() throws {
        _ = try write("cache/a")
        _ = try write("cache/b")
        XCTAssertEqual(PathGuard.rejectTree(root.appendingPathComponent("cache"), limit: 1), .unverifiedContents)
    }

    func testOldRegularTempFileIsNotInUseButFreshOneIs() throws {
        let file = try write("old.part")
        let old = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        XCTAssertFalse(Scanner.touchedRecently(file, within: 3600))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        XCTAssertTrue(Scanner.touchedRecently(file, within: 3600))
    }

    func testMultilineFilenameCannotForgeAnotherDUSizingRecord() throws {
        let name = "unusual\n999999\t\(root.path)/victim"
        let file = try write(name, String(repeating: "X", count: 8192))
        let ordinary = try write("ordinary", String(repeating: "Y", count: 4096))
        let sizes = Scanner.shared.calculateSizes(at: [file, ordinary])
        XCTAssertEqual(Set(sizes.keys), [file.path, ordinary.path])
        XCTAssertEqual(sizes[file.path], Scanner.shared.calculateSize(at: file))
        XCTAssertEqual(sizes[ordinary.path], Scanner.shared.calculateSize(at: ordinary))
    }

    func testStaleKnownSizeDoesNotInventSpaceForSymlinkOrHardlink() throws {
        let target = try write("target", String(repeating: "X", count: 8192))
        let link = root.appendingPathComponent("cache-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let result = DeletionService.delete([link], knownSizes: [link: 1_000_000])
        XCTAssertEqual(result.deleted, [link])
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        let hardlink = root.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: target, to: hardlink)
        let unlinked = DeletionService.delete([hardlink], knownSizes: [hardlink: 1_000_000])
        XCTAssertEqual(unlinked.deleted, [hardlink])
        XCTAssertEqual(unlinked.freedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testCurrentSizeReplacesStaleHintForRegularFile() throws {
        let file = try write("cache", String(repeating: "X", count: 8192))
        let measured = try FileManager.default.allocatedSize(of: file, reclaiming: true)
        XCTAssertGreaterThan(measured, 0)
        let result = DeletionService.delete([file], knownSizes: [file: 999_999_999])
        XCTAssertEqual(result.freedBytes, measured)
    }

    func testPinnedRootCommandRefusesAnEntryReplacedAfterValidation() throws {
        let target = try write("candidate")
        let command = DeletionService.pinnedRemoval(target)
        let original = root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: target, to: original)
        _ = try write("candidate", "replacement")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "replacement")
    }

    func testFirefoxHistoryRefusesProtectedSymlinkTargetBeforeOpeningIt() throws {
        let target = try write("protected/.git/places.sqlite", "must remain byte-identical")
        let link = root.appendingPathComponent("places.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        guard case .failed(let reason) = FirefoxHistory.clear(database: link) else {
            return XCTFail("protected history target was modified")
        }
        XCTAssertTrue(reason.contains("protected"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "must remain byte-identical")
    }

    func testDuplicateRevalidationRejectsSameSizeSubsecondEditAndReplacement() async throws {
        _ = try write("a", "AAAA")
        _ = try write("b", "AAAA")
        let scan = await DuplicateFinder.shared.findDuplicates(in: root, minSize: 1) { _, _ in }
        let files = try XCTUnwrap(scan.groups.first).files.sorted { $0.name < $1.name }
        let file = try XCTUnwrap(files.first)
        XCTAssertTrue(DuplicateFinder.isUnchanged(file))
        let date = try XCTUnwrap(file.modified)
        _ = try write(file.name, "BBBB")
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(0.5)], ofItemAtPath: file.url.path)
        XCTAssertFalse(DuplicateFinder.isUnchanged(file))
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.url.path)
        XCTAssertFalse(DuplicateFinder.isUnchanged(file), "preserving mtime cannot make different bytes a duplicate")
    }

    func testTrashValidationRunsImmediatelyBeforeEveryMove() throws {
        let a = try write("a")
        let b = try write("b")
        var mayMove = true
        let result = TrashService.trash([a, b], validation: { _ in mayMove }, mover: { original in
            let destination = root.appendingPathComponent("moved-" + original.lastPathComponent)
            try FileManager.default.moveItem(at: original, to: destination)
            mayMove = false
            return destination
        })
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.failed, [b])
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testDefaultTrashBackendIsUnavailableToTests() throws {
        let file = try write("stay")
        let result = TrashService.trash([file])
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.failed, [file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(AppPaths.support.path.hasPrefix(AppPaths.testRoot.path + "/"))
        XCTAssertTrue(AppPaths.logs?.path.hasPrefix(AppPaths.testRoot.path + "/") == true)
    }

    func testBusyDeveloperItemIsPreserved() async throws {
        let file = try write("build-cache/blob")
        let folder = file.deletingLastPathComponent()
        let manager = DevCleanManager(isInUse: { _ in true })
        let item = DevJunkItem(definitionID: "derivedData", url: folder, size: 999, safe: true)
        let result = await manager.clean(items: [item])
        XCTAssertTrue(result.cleaned.isEmpty)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testUndoRefusesAParentRedirectedIntoProtectedData() throws {
        let file = try write("original/note")
        let originalParent = file.deletingLastPathComponent()
        let moved = root.appendingPathComponent("trashed-note")
        let result = TrashService.trash([file], mover: { source in
            try FileManager.default.moveItem(at: source, to: moved)
            return moved
        })
        XCTAssertEqual(result.count, 1)
        try FileManager.default.moveItem(at: originalParent, to: root.appendingPathComponent("old-parent"))
        _ = try write("protected/.git/sentinel")
        let protected = root.appendingPathComponent("protected/.git")
        try FileManager.default.createSymbolicLink(at: originalParent, withDestinationURL: protected)
        XCTAssertEqual(TrashService.restore(result.trashed), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: protected.appendingPathComponent("note").path))
    }

    func testPermanentBatchRechecksActivityBeforeEachRemoval() throws {
        let a = try write("a")
        let b = try write("b")
        var calls = 0
        let result = DeletionService.delete([a, b], validation: { _ in
            calls += 1
            return calls == 1
        })
        XCTAssertEqual(result.deleted, [a])
        XCTAssertEqual(result.failed, [b])
        XCTAssertEqual(result.obstacles[b], .inUse)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    func testRunningNestedHelperKeepsItsParentAppProtected() {
        let bundle = URL(fileURLWithPath: "/Applications/Example.app")
        XCTAssertTrue(AppManager.hasRunningComponent(in: bundle,
            paths: ["/Applications/Example.app/Contents/Helpers/Worker.app"]))
        XCTAssertFalse(AppManager.hasRunningComponent(in: bundle,
            paths: ["/Applications/Example.app.other/Contents/Helpers/Worker.app"]))
    }

    func testSizeCachePersistenceUsesOnlyTheInjectedDirectory() async throws {
        let directory = root.appendingPathComponent("cache-state")
        let cache = DiskCacheManager(directory: directory)
        await cache.setSize(12, for: "synthetic-path", isDirectory: false)
        await cache.saveToDisk()
        let restored = DiskCacheManager(directory: directory)
        let size = await restored.getSize(for: "synthetic-path")
        XCTAssertEqual(size, 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("sizeCache.json").path))
    }

    func testActivityPatternRecognisesLongHelpersWithoutNameSubstrings() throws {
        let pattern = try NSRegularExpression(pattern: AppActivityGuard.processPattern(["com.docker.backend", "node"]))
        func matches(_ command: String) -> Bool {
            pattern.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
        }
        XCTAssertTrue(matches("/Applications/Docker.app/Contents/MacOS/com.docker.backend --watch"))
        XCTAssertTrue(matches("/opt/homebrew/bin/node server.js"))
        XCTAssertFalse(matches("/usr/bin/node-exporter --watch"))
        XCTAssertFalse(matches("/Applications/comXdockerXbackend"))
    }
}
