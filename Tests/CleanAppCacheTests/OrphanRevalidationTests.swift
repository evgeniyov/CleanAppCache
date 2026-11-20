import XCTest
@testable import CleanAppCacheLib

final class OrphanRevalidationTests: XCTestCase {
    private var root: URL!
    private let empty = AppManager.InstalledInventory(bundleIDs: [], names: [], vendors: [])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OrphanRevalidation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func job(program: String? = nil, owner: String? = nil) throws -> OrphanItem {
        let url = root.appendingPathComponent("com.acmetest.removed.plist")
        var plist: [String: Any] = ["Label": "com.acmetest.removed", "Program": program ?? root.appendingPathComponent("missing").path]
        if let owner { plist["AssociatedBundleIdentifiers"] = owner }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url)
        return try XCTUnwrap(OrphanScanner.classifyPlist(url: url, scope: .userAgent))
    }

    private func valid(_ item: OrphanItem, inventory: AppManager.InstalledInventory? = nil,
                       installed: Set<String> = []) -> Bool {
        OrphanScanner.isStillOrphan(item, inventory: inventory ?? empty,
                                   applicationExists: { installed.contains($0) }, jobDirectories: [root])
    }

    func testUnchangedMissingProgramRemainsEligible() throws {
        XCTAssertTrue(valid(try job()))
    }

    func testRestoredProgramIsExcluded() throws {
        let item = try job()
        try Data("restored".utf8).write(to: URL(fileURLWithPath: item.programPath))
        XCTAssertFalse(valid(item))
    }

    func testRestoredAppIsExcludedEvenWithoutProgram() throws {
        let app = root.appendingPathComponent("Restored.app")
        let item = try job(program: app.appendingPathComponent("Contents/MacOS/tool").path)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertFalse(valid(item))
    }

    func testReplacedPlistWithIdenticalBytesIsExcluded() throws {
        let item = try job()
        let data = try Data(contentsOf: item.url)
        try FileManager.default.moveItem(at: item.url, to: root.appendingPathComponent("original"))
        try data.write(to: item.url)
        XCTAssertFalse(valid(item))
    }

    func testModifiedPlistIsExcluded() throws {
        let item = try job()
        try Data("changed".utf8).write(to: item.url)
        XCTAssertFalse(valid(item))
    }

    func testSymlinkSubstitutionIsExcluded() throws {
        let item = try job()
        let original = root.appendingPathComponent("original")
        try FileManager.default.moveItem(at: item.url, to: original)
        try FileManager.default.createSymbolicLink(at: item.url, withDestinationURL: original)
        XCTAssertFalse(valid(item))
    }

    func testNewInventoryOwnerAndVendorAreExcluded() throws {
        let item = try job()
        XCTAssertFalse(valid(item, inventory: .init(bundleIDs: ["com.acmetest.removed"], names: [], vendors: [])))
        XCTAssertFalse(valid(item, inventory: .init(bundleIDs: [], names: [], vendors: ["acmetest"])))
    }

    func testLaunchServicesOwnerAndAssociatedOwnerAreExcluded() throws {
        let item = try job(owner: "org.owner.product")
        XCTAssertFalse(valid(item, installed: ["com.acmetest.removed"]))
        XCTAssertFalse(valid(item, installed: ["org.owner.product"]))
    }

    func testHelperGainsOwnerThroughNewJob() throws {
        let helper = root.appendingPathComponent("com.acmetest.helper")
        try Data("helper".utf8).write(to: helper)
        let item = try XCTUnwrap(OrphanScanner.classifyHelper(url: helper, inventory: empty,
            applicationExists: { _ in false }, jobDirectories: [root]))
        XCTAssertTrue(valid(item))
        let alias = root.appendingPathComponent("helper-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: helper)
        let plist: [String: Any] = ["Label": "org.owner.product", "ProgramArguments": [alias.path]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("new.plist"))
        XCTAssertFalse(valid(item))
        XCTAssertNil(OrphanScanner.classifyHelper(url: helper, inventory: empty,
            applicationExists: { _ in false }, jobDirectories: [root]))
    }

    func testNoSnapshotFailsClosed() throws {
        var item = try job()
        item.scanIdentity = nil
        XCTAssertFalse(valid(item))
    }

    func testTrashValidationReportsChangedItemWithoutCallingMover() throws {
        let item = try job()
        try Data("restored".utf8).write(to: URL(fileURLWithPath: item.programPath))
        var called = false
        let result = TrashService.trash([item.url], validationObstacle: .changedSinceScan, validation: { _ in self.valid(item) }, mover: { url in
            called = true
            return url
        })
        XCTAssertFalse(called)
        XCTAssertEqual(result.failed, [item.url])
        XCTAssertEqual(result.obstacles[item.url], .changedSinceScan)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
    }
    func testValidationRunsForEachMoveAfterEarlierMove() throws {
        let item = try job()
        let earlier = root.appendingPathComponent("earlier")
        try Data("scratch".utf8).write(to: earlier)
        var moved: [URL] = []
        let result = TrashService.trash([earlier, item.url], validationObstacle: .changedSinceScan, validation: { url in
            url == earlier || self.valid(item)
        }, mover: { url in
            moved.append(url)
            try Data("restored".utf8).write(to: URL(fileURLWithPath: item.programPath))
            let destination = self.root.appendingPathComponent("scratch-trash")
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
        XCTAssertEqual(moved, [earlier])
        XCTAssertEqual(result.validationRejected, [item.url])
        XCTAssertEqual(result.obstacles[item.url], .changedSinceScan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
    }

    func testFinderDispatchRevalidatesRestoredItem() throws {
        let item = try job()
        XCTAssertTrue(valid(item))
        try Data("restored".utf8).write(to: URL(fileURLWithPath: item.programPath))
        var dispatched = false
        let result = TrashService.trashWithFinder([item.url], knownSizes: [:], allowing: [],
            validationObstacle: .changedSinceScan, validation: { _ in self.valid(item) }, dispatch: { _ in
                dispatched = true
                return .init(status: 0, stdout: "", stderr: "", timedOut: false)
            })
        XCTAssertFalse(dispatched)
        XCTAssertEqual(result.validationRejected, [item.url])
        XCTAssertEqual(result.obstacles[item.url], .changedSinceScan)
        XCTAssertEqual(result.freedBytes, 0)
    }

    func testEscalatingEntryPointPropagatesValidation() async throws {
        let item = try job()
        let result = await TrashService.trashEscalating([item.url], validationObstacle: .changedSinceScan, validation: { _ in false })
        XCTAssertEqual(result.validationRejected, [item.url])
        XCTAssertEqual(result.obstacles[item.url], .changedSinceScan)
        XCTAssertEqual(result.failed, [item.url])
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertNil(result.escalation)
    }

    func testDefaultValidationObstacleRemainsInUse() throws {
        let item = try job()
        let ordinary = TrashService.trash([item.url], validation: { _ in false }, mover: { url in
            XCTFail("Rejected item must not reach the mover")
            return url
        })
        XCTAssertEqual(ordinary.obstacles[item.url], .inUse)
        let finder = TrashService.trashWithFinder([item.url], knownSizes: [:], allowing: [],
            validation: { _ in false }, dispatch: { _ in
                XCTFail("Rejected item must not reach Finder")
                return .init(status: 0, stdout: "", stderr: "", timedOut: false)
            })
        XCTAssertEqual(finder.obstacles[item.url], .inUse)
    }

    func testInstallationChangeAfterValidatorCreationSkipsLaterHelper() throws {
        let apps = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
        let helper = root.appendingPathComponent("com.acmetest.oldhelper")
        try Data("helper".utf8).write(to: helper)
        let item = try XCTUnwrap(OrphanScanner.classifyHelper(url: helper, inventory: empty,
            applicationExists: { _ in false }, jobDirectories: [root]))
        let baseline = try XCTUnwrap(OrphanScanner.installationState(roots: [apps], runningBundleIDs: []))
        let generation = try XCTUnwrap(OrphanScanner.InstallationGeneration(state: baseline))
        let validator = OrphanScanner.removalValidator(for: [item], inventory: empty,
            installationIsCurrent: { generation.isCurrent() },
            applicationExists: { _ in false }, jobDirectories: [root])
        XCTAssertTrue(validator(helper))
        let earlier = root.appendingPathComponent("earlier")
        try Data("earlier".utf8).write(to: earlier)
        var moved: [URL] = []
        let result = TrashService.trash([earlier, helper], validationObstacle: .changedSinceScan,
            validation: { $0 == earlier || validator($0) }, mover: { url in
                moved.append(url)
                // Another product of the same vendor has no dotted prefix in common with the helper.
                let contents = apps.appendingPathComponent("NewProduct.app/Contents")
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.acmetest.newproduct"],
                                                              format: .xml, options: 0)
                try data.write(to: contents.appendingPathComponent("Info.plist"))
                let destination = self.root.appendingPathComponent("scratch-trash")
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            })
        XCTAssertEqual(moved, [earlier])
        XCTAssertEqual(result.failed, [helper])
        XCTAssertEqual(result.obstacles[helper], .changedSinceScan)
        XCTAssertFalse(validator(helper))
        XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path))
    }

    func testUnreadableInstallationStateFailsClosed() throws {
        let item = try job()
        let validator = OrphanScanner.removalValidator(for: [item], inventory: empty,
            installationIsCurrent: { false }, applicationExists: { _ in false }, jobDirectories: [root])
        XCTAssertFalse(validator(item.url))
    }

    func testInstallationGenerationInvalidatesOnAnInPlaceInfoPlistChange() throws {
        let apps = root.appendingPathComponent("Applications")
        let bundle = apps.appendingPathComponent("Editor.app")
        try writeTestApplication(bundle)
        let baseline = try XCTUnwrap(OrphanScanner.installationState(roots: [apps], runningBundleIDs: []))
        let generation = try XCTUnwrap(OrphanScanner.InstallationGeneration(state: baseline))
        XCTAssertTrue(generation.isCurrent())
        try writeTestApplication(bundle, id: "com.example.changed")
        XCTAssertFalse(generation.isCurrent())
        XCTAssertFalse(generation.isCurrent())
    }

    private func permissionFailure(_ url: URL) -> TrashService.Result {
        .init(trashed: [], failed: [url], obstacles: [url: .needsAdmin], freedBytes: 0)
    }

    func testFinderReplacesPermissionFailureWithChangedSymlink() throws {
        let item = try job()
        let first = permissionFailure(item.url)
        let saved = root.appendingPathComponent("saved")
        try FileManager.default.moveItem(at: item.url, to: saved)
        try FileManager.default.createSymbolicLink(at: item.url, withDestinationURL: saved)
        let result = TrashService.escalate(first, knownSizes: [:], allowing: [],
            validationObstacle: .changedSinceScan, validation: { _ in self.valid(item) }, dispatch: { _ in
                XCTFail("Changed symlink must not reach Finder")
                return .init(status: 0, stdout: "", stderr: "", timedOut: false)
            })
        XCTAssertEqual(result.failed, [item.url])
        XCTAssertEqual(result.validationRejected, [item.url])
        XCTAssertEqual(result.obstacles[item.url], .changedSinceScan)
        XCTAssertNil(result.escalation)
    }

    func testFinderReplacesPermissionFailureWithBlockedTarget() throws {
        let item = try job()
        let first = permissionFailure(item.url)
        try FileManager.default.moveItem(at: item.url, to: root.appendingPathComponent("saved"))
        try FileManager.default.createSymbolicLink(at: item.url, withDestinationURL: URL(fileURLWithPath: "/System"))
        let result = TrashService.escalate(first, knownSizes: [:], allowing: [],
            validation: { _ in true }, dispatch: { _ in
                XCTFail("Forbidden target must not reach Finder")
                return .init(status: 0, stdout: "", stderr: "", timedOut: false)
            })
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.blocked, [item.url])
        XCTAssertNil(result.obstacles[item.url])
        XCTAssertNil(result.escalation)
    }

    func testFinderReplacesPermissionFailureWithAlreadyGone() throws {
        let item = try job()
        let first = permissionFailure(item.url)
        try FileManager.default.moveItem(at: item.url, to: root.appendingPathComponent("saved"))
        let result = TrashService.escalate(first, knownSizes: [:], allowing: [],
            validation: { _ in false }, dispatch: { _ in
                XCTFail("Missing item must not reach Finder")
                return .init(status: 0, stdout: "", stderr: "", timedOut: false)
            })
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.alreadyGone, [item.url])
        XCTAssertNil(result.obstacles[item.url])
        XCTAssertNil(result.escalation)
    }

}
