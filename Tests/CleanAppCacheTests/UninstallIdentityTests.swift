import XCTest
@testable import CleanAppCacheLib

final class UninstallIdentityTests: XCTestCase {
    private let fm = FileManager.default

    private func scratch() throws -> URL {
        let buildDirectory = ProcessInfo.processInfo.environment["BUILD_TMP_DIR"].map { URL(fileURLWithPath: $0) }
        let root = (buildDirectory ?? fm.temporaryDirectory).appendingPathComponent("uninstall_identity_\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func writeBundle(_ url: URL, id: String = "com.cacfixture.editor") throws {
        try writeTestApplication(url, id: id)
    }

    private func fixture(_ root: URL, bundleName: String = "Editor.app") throws -> InstalledApp {
        let bundle = root.appendingPathComponent("Applications").appendingPathComponent(bundleName)
        try writeBundle(bundle)
        let data = root.appendingPathComponent("Library/Application Support/com.cacfixture.editor")
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("original data".utf8).write(to: data.appendingPathComponent("document"))
        return InstalledApp(url: bundle, name: "Editor", bundleIdentifier: "com.cacfixture.editor",
                            version: nil, size: 0,
                            associatedFiles: [AssociatedFile(url: data, type: .support, size: 0)], installDate: nil)
    }

    private func replace(_ url: URL, bundle: Bool = false) throws {
        try fm.moveItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent("held-\(UUID().uuidString)"))
        if bundle {
            try writeBundle(url, id: "com.cacfixture.replacement")
        } else {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("replacement data".utf8).write(to: url.appendingPathComponent("document"))
        }
    }

    private func identities(_ app: InstalledApp) throws -> [URL: RemovalIdentity] {
        var result = [app.url: try XCTUnwrap(app.removalIdentity)]
        for file in app.associatedFiles { result[file.url] = try XCTUnwrap(file.removalIdentity) }
        return result
    }

    /// Executes only the production command's scratch targets, as the test user, without AppleScript.
    private func admin(_ app: InstalledApp, root: URL, beforeRun: () throws -> Void = {},
                       cancel: Bool = false, missingIdentities: Bool = false, followedBy late: URL? = nil,
                       checkRunning: Bool = false) throws -> DeletionService.AdministratorResult {
        var expected = missingIdentities ? [:] : try identities(app)
        if let late { expected[late] = RemovalIdentity(at: late) }
        let groups = [[app.url] + app.associatedFiles.map(\.url)] + (late.map { [[$0]] } ?? [])
        return DeletionService.deleteAsAdministrator(
            groups, prompt: "unused", identities: expected, appBundles: checkRunning ? [app.url] : [],
            targetResolver: { url in
                url.path.hasPrefix(root.path + "/") ? url : nil
            }, runner: { command, _ in
                do {
                    try beforeRun()
                    if cancel {
                        return AppleScriptRunner.Output(status: 1, stdout: "", stderr: "cancelled (-128)", timedOut: false)
                    }
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/bin/sh")
                    task.arguments = ["-c", command]
                    let output = Pipe()
                    task.standardOutput = output
                    task.standardError = FileHandle.nullDevice
                    try task.run()
                    let bytes = output.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    return AppleScriptRunner.Output(status: task.terminationStatus,
                                                    stdout: task.terminationStatus == 0 ? String(decoding: bytes, as: UTF8.self) : "",
                                                    stderr: "", timedOut: false)
                } catch {
                    XCTFail("scratch command failed: \(error)")
                    return AppleScriptRunner.Output(status: 1, stdout: "", stderr: "fixture failed", timedOut: false)
                }
            })
    }

    func testLateAdministratorFailurePreservesEarlierReceipts() throws {
        let root = try scratch()
        let app = try fixture(root)
        let late = root.appendingPathComponent("Late")
        try Data("original".utf8).write(to: late)
        let result = try admin(app, root: root, beforeRun: {
            try self.fm.moveItem(at: late, to: root.appendingPathComponent("Held"))
            try Data("replacement".utf8).write(to: late)
        }, followedBy: late)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.removed, [app.url] + app.associatedFiles.map(\.url))
        XCTAssertEqual(result.failed, [late])
        XCTAssertEqual(result.obstacles[late], .changedSinceScan)
        XCTAssertEqual(try Data(contentsOf: late), Data("replacement".utf8))
    }

    func testAdministratorRechecksBundleActivityAfterAuthentication() throws {
        let root = try scratch()
        let physical = root.appendingPathComponent("Contents")
        try fm.createDirectory(at: physical, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: physical)
        let app = try fixture(alias, bundleName: "Фото с пробелом.app")
        let sleeper = Process()
        sleeper.executableURL = app.url.appendingPathComponent("Contents/MacOS/fixture")
        sleeper.arguments = ["30"]
        defer {
            if sleeper.isRunning { sleeper.terminate(); sleeper.waitUntilExit() }
        }
        let result = try admin(app, root: root, beforeRun: {
            try sleeper.run()
        }, checkRunning: true)
        XCTAssertEqual(result.running, [app.url])
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testDirectUninstallRechecksRunningStateAndLeavesAssociatedData() async throws {
        let root = try scratch()
        let app = try fixture(root)
        let results = await AppManager.shared.uninstall([app], adminPrompt: "unused", bundleIsRunning: { _ in true })
        XCTAssertTrue(results[0].stillRunning)
        XCTAssertFalse(results[0].bundleRemoved)
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testDirectUninstallRefusesReplacementBundleAndKeepsData() async throws {
        let root = try scratch()
        let app = try fixture(root)
        try replace(app.url, bundle: true)
        let results = await AppManager.shared.uninstall([app], adminPrompt: "unused")
        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.bundleChanged)
        XCTAssertEqual(result.bundleObstacle, .changedSinceScan)
        XCTAssertFalse(result.bundleRemoved)
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
        XCTAssertEqual(result.freedBytes, 0)
    }

    func testDirectUninstallRefusesChangedBundleMetadataOnSameDirectory() async throws {
        let root = try scratch()
        let app = try fixture(root)
        try writeBundle(app.url, id: "com.cacfixture.replacement")
        XCTAssertTrue(try XCTUnwrap(app.removalIdentity).object.isSameObject(at: app.url))
        let results = await AppManager.shared.uninstall([app], adminPrompt: "unused")
        XCTAssertTrue(try XCTUnwrap(results.first).bundleChanged)
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testDirectUninstallKeepsReplacementDataButRemovesSelectedBundle() async throws {
        let root = try scratch()
        let app = try fixture(root)
        let data = app.associatedFiles[0].url
        try replace(data)
        let results = await AppManager.shared.uninstall([app], adminPrompt: "unused")
        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.bundleRemoved)
        XCTAssertEqual(result.associatedChanged, [data])
        XCTAssertEqual(result.associatedFailed, [data])
        XCTAssertEqual(result.associatedObstacles[data], .changedSinceScan)
        XCTAssertEqual(result.associatedRemoved, 0)
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("document")), "replacement data")
    }

    func testMissingScanIdentityFailsClosed() async throws {
        let root = try scratch()
        var app = try fixture(root)
        app.removalIdentity = nil
        let results = await AppManager.shared.uninstall([app], adminPrompt: "unused")
        XCTAssertTrue(try XCTUnwrap(results.first).bundleChanged)
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
    }

    func testStaleGroupSelectionsArePreservedAndNonGroupScriptsAreRemoved() async throws {
        let root = try scratch()
        var app = try fixture(root)
        let paths = [
            "Group Containers/group.com.cacfixture.editor.shared",
            "Group Containers/ABCDE12345.com.cacfixture.editor",
            "Application Scripts/group.com.cacfixture.editor",
            "Application Scripts/ABCDE12345.com.cacfixture.editor",
            "Application Scripts/ABCDE12345.group.com.cacfixture.editor"
        ]
        var preserved: [URL] = []
        for path in paths {
            let url = root.appendingPathComponent("Library/" + path)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            // Even an incorrectly classified old entry must be retained by its location.
            app.associatedFiles.append(AssociatedFile(url: url, type: .container, size: 0))
            XCTAssertTrue(AppManager.preservesSharedData(at: url, type: .container))
            preserved.append(url)
        }
        let unproven = root.appendingPathComponent("Library/Application Scripts/com.cacfixture.editor.shared")
        try fm.createDirectory(at: unproven, withIntermediateDirectories: true)
        app.associatedFiles.append(AssociatedFile(url: unproven, type: .container, size: 0))
        preserved.append(unproven)
        let ordinary = root.appendingPathComponent("Library/Application Scripts/com.cacfixture.editor")
        try fm.createDirectory(at: ordinary, withIntermediateDirectories: true)
        app.associatedFiles.append(AssociatedFile(url: ordinary, type: .container, size: 0))
        XCTAssertFalse(AppManager.preservesSharedData(at: ordinary, type: .container))
        let results = await AppManager.shared.uninstall([app], adminPrompt: "unused")
        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.bundleRemoved)
        XCTAssertTrue(result.sharedDataKept)
        XCTAssertEqual(result.associatedRemoved, 2)
        for url in preserved { XCTAssertTrue(fm.fileExists(atPath: url.path), url.path) }
        XCTAssertFalse(fm.fileExists(atPath: ordinary.path))
    }

    func testAdminUsesOriginalIdentityWhenReplacementPrecedesCommand() throws {
        let root = try scratch()
        let app = try fixture(root)
        try replace(app.url, bundle: true)
        let result = try admin(app, root: root)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.changed, [app.url])
        XCTAssertEqual(result.obstacles[app.url], .changedSinceScan)
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testAdminRefusesBundleReplacedDuringPasswordWaitAndKeepsData() throws {
        let root = try scratch()
        let app = try fixture(root)
        let result = try admin(app, root: root, beforeRun: { try self.replace(app.url, bundle: true) })
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.changed, [app.url])
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testAdminRefusesMetadataChangedDuringPasswordWait() throws {
        let root = try scratch()
        let app = try fixture(root)
        let result = try admin(app, root: root, beforeRun: {
            try self.writeBundle(app.url, id: "com.cacfixture.changed")
        })
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.changed, [app.url])
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testAdminKeepsDataReplacedDuringPasswordWait() throws {
        let root = try scratch()
        let app = try fixture(root)
        let data = app.associatedFiles[0].url
        let result = try admin(app, root: root, beforeRun: { try self.replace(data) })
        XCTAssertEqual(result.removed, [app.url])
        XCTAssertEqual(result.changed, [data])
        XCTAssertEqual(result.failed, [data])
        XCTAssertEqual(result.obstacles[data], .changedSinceScan)
        XCTAssertEqual(try String(contentsOf: data.appendingPathComponent("document")), "replacement data")
    }

    func testAdminDoesNotCountAnExternallyMovedBundleAsRemoved() throws {
        let root = try scratch()
        let app = try fixture(root)
        let moved = root.appendingPathComponent("Moved.app")
        let result = try admin(app, root: root, beforeRun: {
            try self.fm.moveItem(at: app.url, to: moved)
        }, cancel: true)
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.changed, [app.url])
        XCTAssertTrue(fm.fileExists(atPath: moved.path))
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testAdminMissingIdentityNeverFallsBackToCurrentObject() throws {
        let root = try scratch()
        let app = try fixture(root)
        let result = try admin(app, root: root, missingIdentities: true)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(Set(result.changed), Set([app.url] + app.associatedFiles.map(\.url)))
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testAdminUnchangedSelectionDeletesBundleAndDataAndReportsReceipts() throws {
        let root = try scratch()
        let app = try fixture(root)
        let result = try admin(app, root: root)
        XCTAssertEqual(result.removed, [app.url] + app.associatedFiles.map(\.url))
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: app.url.path))
        XCTAssertFalse(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testDirectUninstallRejectsARecreatedParentEvenWithOriginalBundle() async throws {
        let root = try scratch()
        let app = try fixture(root)
        let parent = app.url.deletingLastPathComponent()
        let held = root.appendingPathComponent("HeldApplications")
        try fm.moveItem(at: parent, to: held)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.moveItem(at: held.appendingPathComponent(app.url.lastPathComponent), to: app.url)
        XCTAssertTrue(try XCTUnwrap(app.removalIdentity).object.isSameObject(at: app.url))
        let results = await AppManager.shared.uninstall([app], adminPrompt: "unused")
        XCTAssertTrue(try XCTUnwrap(results.first).bundleChanged)
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testAdminRejectsParentRecreatedDuringPasswordWait() throws {
        let root = try scratch()
        let app = try fixture(root)
        let parent = app.url.deletingLastPathComponent()
        let held = root.appendingPathComponent("HeldApplications")
        let result = try admin(app, root: root, beforeRun: {
            try self.fm.moveItem(at: parent, to: held)
            try self.fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try self.fm.moveItem(at: held.appendingPathComponent(app.url.lastPathComponent), to: app.url)
        })
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.changed, [app.url])
        XCTAssertTrue(fm.fileExists(atPath: app.url.path))
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }

    func testDirectUninstallKeepsDataWithoutScanIdentity() async throws {
        let root = try scratch()
        var app = try fixture(root)
        app.associatedFiles[0].removalIdentity = nil
        let data = app.associatedFiles[0].url
        let results = await AppManager.shared.uninstall([app], adminPrompt: "unused")
        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.bundleRemoved)
        XCTAssertEqual(result.associatedChanged, [data])
        XCTAssertEqual(result.associatedObstacles[data], .changedSinceScan)
        XCTAssertTrue(fm.fileExists(atPath: data.path))
    }

    func testAdminUnchangedGroupHasNoDataDeletionWhenBundleDisappearsDuringWait() throws {
        let root = try scratch()
        let app = try fixture(root)
        let result = try admin(app, root: root, beforeRun: {
            try self.fm.moveItem(at: app.url, to: root.appendingPathComponent("Moved.app"))
        })
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.changed, [app.url])
        XCTAssertTrue(fm.fileExists(atPath: app.associatedFiles[0].url.path))
    }
}
