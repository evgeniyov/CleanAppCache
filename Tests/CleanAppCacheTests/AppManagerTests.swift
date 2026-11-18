import XCTest
@testable import CleanAppCacheLib

final class AppManagerTests: XCTestCase {

    func testInstalledAppTotalSize() {
        let associated = [
            AssociatedFile(url: URL(fileURLWithPath: "/tmp/cache"), type: .cache, size: 500),
            AssociatedFile(url: URL(fileURLWithPath: "/tmp/prefs"), type: .preference, size: 300)
        ]

        let app = InstalledApp(
            url: URL(fileURLWithPath: "/Applications/Test.app"),
            name: "TestApp",
            bundleIdentifier: "com.test.app",
            version: "1.0",
            size: 1000,
            associatedFiles: associated,
            installDate: nil
        )

        XCTAssertEqual(app.totalSize, 1800)
        XCTAssertEqual(app.associatedFiles.count, 2)

        // The formatted string belongs to `Fmt` and follows the app's own
        // language, so asserting a literal here would test the localization
        // rather than this type. What belongs to this type is *which number*
        // gets formatted.
        XCTAssertEqual(app.formattedSize, Fmt.bytes(UInt64(1800)))
        // …and that it is a measurement, not a bare figure. `Fmt` reads its unit
        // table from a context that `Localizer` publishes; a process that never
        // touches `Localizer` must still print a unit.
        XCTAssertTrue(app.formattedSize.contains(where: { $0.isLetter }),
                      "formatted size lost its unit: \(app.formattedSize)")
    }

    // MARK: - Admin deletion target

    /// A scratch tree under the per-user temp directory, whose children
    /// `PathGuard` allows. `allowed` stands in for /Applications; `outside` is
    /// a sibling that is not an allowed root. Only the validator runs against
    /// it — nothing here escalates or deletes outside the scratch directory.
    private struct Scratch {
        let base: URL
        let allowed: URL
        let outside: URL
        /// `allowed`, standardized and symlink-resolved like the real roots.
        var allowedRoot: String { allowed.standardizedFileURL.resolvingSymlinksInPath().path }
    }

    private func makeScratch() throws -> Scratch {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("admin_target_\(UUID().uuidString)")
        let allowed = base.appendingPathComponent("allowed")
        let outside = base.appendingPathComponent("outside")
        try fm.createDirectory(at: allowed, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return Scratch(base: base, allowed: allowed, outside: outside)
    }

    private func makeBundle(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    }

    func testAdminDeletionTargetAcceptsRealBundleInsideAllowedRoot() throws {
        let s = try makeScratch()
        let app = s.allowed.appendingPathComponent("Foo.app")
        try makeBundle(app)

        let target = DeletionService.administratorBundleTarget(for: app, allowedRoots: [s.allowedRoot])
        XCTAssertEqual(target?.path, app.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    func testAdminDeletionTargetRefusesParentTraversal() throws {
        let s = try makeScratch()
        // A real bundle exists at the normalised destination, so only the `..`
        // check can refuse it.
        try makeBundle(s.allowed.appendingPathComponent("Foo.app"))
        let sneaky = URL(fileURLWithPath: s.allowed.path + "/../allowed/Foo.app")
        XCTAssertTrue(sneaky.pathComponents.contains(".."))

        XCTAssertNil(DeletionService.administratorBundleTarget(for: sneaky, allowedRoots: [s.allowedRoot]))
    }

    func testAdminDeletionTargetRefusesNonAppDirectory() throws {
        let s = try makeScratch()
        let folder = s.allowed.appendingPathComponent("Foo")
        try makeBundle(folder)

        XCTAssertNil(DeletionService.administratorBundleTarget(for: folder, allowedRoots: [s.allowedRoot]))
    }

    func testAdminDeletionTargetRefusesBundleOutsideAllowedRoots() throws {
        let s = try makeScratch()
        let app = s.outside.appendingPathComponent("Foo.app")
        try makeBundle(app)

        XCTAssertNil(DeletionService.administratorBundleTarget(for: app, allowedRoots: [s.allowedRoot]))
    }

    func testAdminDeletionTargetRespectsComponentBoundary() throws {
        let s = try makeScratch()
        // `allowedX` shares a string prefix with `allowed` but is not inside it.
        let lookalike = s.base.appendingPathComponent("allowedX/Foo.app")
        try makeBundle(lookalike)

        XCTAssertNil(DeletionService.administratorBundleTarget(for: lookalike, allowedRoots: [s.allowedRoot]))
    }

    func testAdminDeletionTargetRefusesSymlinkLeavingAllowedRoot() throws {
        let s = try makeScratch()
        let real = s.outside.appendingPathComponent("X.app")
        try makeBundle(real)
        let link = s.allowed.appendingPathComponent("X.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        XCTAssertNil(DeletionService.administratorBundleTarget(for: link, allowedRoots: [s.allowedRoot]))
    }

    func testAdminDeletionTargetRefusesBundleWithoutContents() throws {
        let s = try makeScratch()
        let app = s.allowed.appendingPathComponent("Foo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        XCTAssertNil(DeletionService.administratorBundleTarget(for: app, allowedRoots: [s.allowedRoot]))
    }

    func testAdminDeletionTargetRefusesPlainFileNamedApp() throws {
        let s = try makeScratch()
        let file = s.allowed.appendingPathComponent("Foo.app")
        try Data("x".utf8).write(to: file)

        XCTAssertNil(DeletionService.administratorBundleTarget(for: file, allowedRoots: [s.allowedRoot]))
    }

    func testAdminDeletionTargetRefusesRootAndNonFileURLs() {
        XCTAssertNil(DeletionService.administratorBundleTarget(
            for: URL(fileURLWithPath: "/"), allowedRoots: ["/"]))
        XCTAssertNil(DeletionService.administratorBundleTarget(
            for: URL(string: "https://example.com/Foo.app")!, allowedRoots: ["/"]))
    }

    // MARK: - Uninstall ordering

    /// A scratch "app" with one associated folder, both under the per-user
    /// temp directory. `bundlePath` is relative to the scratch root.
    private func makeUninstallFixture(bundlePath: String) throws -> (app: InstalledApp, leftover: URL) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("uninstall_order_\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let bundle = base.appendingPathComponent(bundlePath)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let leftover = base.appendingPathComponent("support/com.example.fixture")
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: leftover.appendingPathComponent("state.bin"))
        let app = InstalledApp(
            url: bundle,
            name: "Fixture",
            bundleIdentifier: "com.example.fixture",
            version: nil,
            size: 0,
            associatedFiles: [AssociatedFile(url: leftover, type: .support, size: 4096)],
            installDate: nil
        )
        return (app, leftover)
    }

    func testUninstallKeepsLeftoversWhenTheBundleStays() async throws {
        // PathGuard refuses anything inside a .git directory, so this bundle
        // cannot be removed — it stands in for one that stays installed.
        let (app, leftover) = try makeUninstallFixture(bundlePath: "repo/.git/Stuck.app")

        let results = await AppManager.shared.uninstall([app], adminPrompt: "test")

        XCTAssertEqual(results.count, 1)
        XCTAssertFalse(results[0].bundleRemoved)
        XCTAssertTrue(results[0].bundleBlocked)
        XCTAssertEqual(results[0].associatedRemoved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path),
                      "an app that stays installed must keep its files")
    }

    func testUninstallRemovesLeftoversAfterTheBundle() async throws {
        let (app, leftover) = try makeUninstallFixture(bundlePath: "apps/Gone.app")

        let results = await AppManager.shared.uninstall([app], adminPrompt: "test")

        XCTAssertTrue(results[0].bundleRemoved)
        XCTAssertEqual(results[0].associatedRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    func testUninstallKeepsDataOfAnAppMovedAfterTheScan() async throws {
        let (app, leftover) = try makeUninstallFixture(bundlePath: "apps/Moved.app")
        let moved = app.url.deletingLastPathComponent().appendingPathComponent("Elsewhere.app")
        try FileManager.default.moveItem(at: app.url, to: moved)
        let results = await AppManager.shared.uninstall([app], adminPrompt: "test")
        XCTAssertFalse(results[0].bundleRemoved)
        XCTAssertEqual(results[0].associatedRemoved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path))
    }

    // MARK: - Associated-file matching

    func testGroupContainerNamesMatchTheirBundleID() {
        XCTAssertEqual(AppManager.groupMatchName("5HD2ARTBFS.com.canva.affinity"), "com.canva.affinity")
        XCTAssertEqual(AppManager.groupMatchName("4FG648TM2A.group.com.aone.keka"), "com.aone.keka")
        XCTAssertEqual(AppManager.groupMatchName("group.su.ffg.happ.ruplus"), "su.ffg.happ.ruplus")
        XCTAssertEqual(AppManager.groupMatchName("com.acme.app.widget"), "com.acme.app.widget")
        // A suite-wide group names no single app and keeps a name no bundle id has.
        XCTAssertEqual(AppManager.groupMatchName("UBF8T346G9.Office"), "office")
        // Ten characters that are not a Team ID stay part of the name.
        XCTAssertEqual(AppManager.groupMatchName("abcdefghij.com.x.y"), "abcdefghij.com.x.y")
    }

    func testCopiesSharingABundleIDKeepTheirData() {
        let prefs = AssociatedFile(url: URL(fileURLWithPath: "/tmp/com.apple.dt.Xcode.plist"),
                                   type: .preference, size: 10)
        func app(_ path: String, _ id: String, _ files: [AssociatedFile]) -> InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: path), name: path, bundleIdentifier: id,
                         version: nil, size: 1, associatedFiles: files, installDate: nil)
        }
        let apps = AppManager.separateSharedData([
            app("/Applications/Xcode.app", "com.apple.dt.Xcode", [prefs]),
            app("/Applications/Xcode-beta.app", "com.apple.dt.xcode", [prefs]),
            app("/Applications/Other.app", "com.example.other", [prefs])
        ])
        XCTAssertTrue(apps[0].associatedFiles.isEmpty)
        XCTAssertTrue(apps[1].associatedFiles.isEmpty)
        XCTAssertEqual(apps[0].sharedDataWith?.lastPathComponent, "Xcode-beta.app")
        XCTAssertEqual(apps[2].associatedFiles.count, 1)
        XCTAssertNil(apps[2].sharedDataWith)
    }
}
