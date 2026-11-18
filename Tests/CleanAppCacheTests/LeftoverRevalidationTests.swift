import XCTest
@testable import CleanAppCacheLib

final class LeftoverRevalidationTests: XCTestCase {
    private var root: URL!
    private let empty = AppManager.InstalledInventory(bundleIDs: [], names: [], vendors: [])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LeftoverRevalidation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func group(_ key: String = "com.cacfixture.removed", uncertain: Bool = false) throws -> LeftoverGroup {
        let url = root.appendingPathComponent(key + ".plist")
        try Data("old preferences".utf8).write(to: url)
        let file = LeftoverFile(url: url, locationKey: "leftovers.loc.prefs", size: 15)
        return LeftoverGroup(id: key, displayName: "Fixture", files: [file], totalBytes: 15, uncertain: uncertain)
    }

    private func validator(
        _ group: LeftoverGroup, inventory: AppManager.InstalledInventory? = nil,
        installed: Set<String> = []
    ) -> @Sendable (URL) -> Bool {
        LeftoversManager.removalValidator(for: [group], inventory: inventory ?? empty, baseline: .init(),
            readInstallationState: { .init() }, applicationExists: { installed.contains($0) })
    }

    func testUnchangedLeftoverMovesThroughValidatedTrashBoundary() throws {
        let chosen = try group()
        let file = try XCTUnwrap(chosen.files.first)
        let destination = root.appendingPathComponent("scratch-trash")
        let result = TrashService.trash([file.url], validationObstacle: .changedSinceScan,
            validation: validator(chosen), mover: { url in
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
        XCTAssertEqual(result.trashed.map(\.original), [file.url])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("old preferences".utf8))
    }

    func testReplacedFileWithIdenticalBytesIsKept() throws {
        let chosen = try group()
        let url = chosen.files[0].url
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("held-original"))
        try Data("old preferences".utf8).write(to: url)
        let result = TrashService.trash([url], validationObstacle: .changedSinceScan,
            validation: validator(chosen), mover: { _ in
                XCTFail("A replacement is not the scanned leftover")
                return url
            })
        XCTAssertEqual(result.failed, [url])
        XCTAssertEqual(result.obstacles[url], .changedSinceScan)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), Data("old preferences".utf8))
    }

    func testModifiedFileAndMissingIdentityAreKept() throws {
        let chosen = try group()
        let url = chosen.files[0].url
        try Data("new preferences from an updater".utf8).write(to: url)
        XCTAssertFalse(validator(chosen)(url))

        var file = LeftoverFile(url: url, locationKey: "leftovers.loc.prefs", size: 31)
        file.removalIdentity = nil
        let noIdentity = LeftoverGroup(id: chosen.id, displayName: "Fixture", files: [file], totalBytes: 31)
        XCTAssertFalse(validator(noIdentity)(url))
        XCTAssertFalse(validator(chosen)(root.appendingPathComponent("unselected")))
    }

    func testRedirectedParentIsKeptEvenWhenItReachesTheSameObject() throws {
        let library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let url = library.appendingPathComponent("com.cacfixture.removed")
        try Data("data".utf8).write(to: url)
        let file = LeftoverFile(url: url, locationKey: "leftovers.loc.caches", size: 4)
        let chosen = LeftoverGroup(id: "com.cacfixture.removed", displayName: "Fixture", files: [file], totalBytes: 4)
        let held = root.appendingPathComponent("HeldLibrary")
        try FileManager.default.moveItem(at: library, to: held)
        try FileManager.default.createSymbolicLink(at: library, withDestinationURL: held)
        XCTAssertFalse(validator(chosen)(url))
    }

    func testReinstalledExactPrefixAndNameOwnersAreKept() throws {
        let chosen = try group("com.cacfixture.removed.helper")
        let url = chosen.files[0].url
        for id in [chosen.id, "com.cacfixture.removed"] {
            let inventory = AppManager.InstalledInventory(bundleIDs: [id], names: [], vendors: [])
            XCTAssertFalse(validator(chosen, inventory: inventory)(url))
            XCTAssertFalse(validator(chosen, installed: [id])(url), "LaunchServices also sees external apps")
        }
        XCTAssertFalse(validator(chosen, inventory: .init(bundleIDs: [], names: [chosen.id], vendors: []))(url))
        XCTAssertTrue(validator(chosen, inventory: .init(bundleIDs: ["com.cacfixture.removedx"], names: [], vendors: []))(url))
    }

    func testNewVendorRequiresReviewButAlreadyUncertainSelectionStillWorks() throws {
        let chosen = try group()
        let inventory = AppManager.InstalledInventory(bundleIDs: ["com.cacfixture.other"], names: [], vendors: ["cacfixture"])
        XCTAssertFalse(validator(chosen, inventory: inventory)(chosen.files[0].url))
        let reviewed = LeftoverGroup(id: chosen.id, displayName: chosen.displayName, files: chosen.files,
                                     totalBytes: chosen.totalBytes, uncertain: true)
        XCTAssertTrue(validator(reviewed, inventory: inventory)(chosen.files[0].url))
        XCTAssertFalse(validator(reviewed, inventory: .init(bundleIDs: [chosen.id], names: [], vendors: []))(chosen.files[0].url))
    }

    func testInstallationDuringBatchKeepsLaterLeftover() throws {
        let first = try group("com.cacfixture.first")
        let later = try group("com.cacfixture.later")
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let baseline = try XCTUnwrap(OrphanScanner.installationState(roots: [applications], runningBundleIDs: []))
        let validation = LeftoversManager.removalValidator(for: [first, later], inventory: empty, baseline: baseline,
            readInstallationState: { OrphanScanner.installationState(roots: [applications], runningBundleIDs: []) },
            applicationExists: { _ in false })
        let result = TrashService.trash([first.files[0].url, later.files[0].url],
            validationObstacle: .changedSinceScan, validation: validation, mover: { url in
                XCTAssertEqual(url, first.files[0].url)
                let contents = applications.appendingPathComponent("Restored.app/Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": later.id], format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                let destination = self.root.appendingPathComponent("scratch-trash")
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
        XCTAssertEqual(result.trashed.map(\.original), [first.files[0].url])
        XCTAssertEqual(result.failed, [later.files[0].url])
        XCTAssertEqual(result.obstacles[later.files[0].url], .changedSinceScan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: later.files[0].url.path))
    }

    func testUnreadableOrMissingInstallationBaselineFailsClosed() throws {
        let chosen = try group()
        let missing = LeftoversManager.removalValidator(for: [chosen], inventory: empty, baseline: nil,
            readInstallationState: { .init() }, applicationExists: { _ in false })
        XCTAssertFalse(missing(chosen.files[0].url))
        let unreadable = LeftoversManager.removalValidator(for: [chosen], inventory: empty, baseline: .init(),
            readInstallationState: { nil }, applicationExists: { _ in false })
        XCTAssertFalse(unreadable(chosen.files[0].url))
    }
}
