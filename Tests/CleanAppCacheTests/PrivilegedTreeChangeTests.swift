import XCTest
@testable import CleanAppCacheLib

final class PrivilegedTreeChangeTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("admin-tree-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func write(_ relative: String, _ contents: String = "selected data") throws -> URL {
        let file = root.appendingPathComponent(relative)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        return file
    }

    /// The production command only receives scratch targets and runs without
    /// AppleScript or elevation. Mutation happens after preflight completes.
    private func remove(_ groups: [[URL]], beforeRun: () throws -> Void = {},
                        transformCommand: (String) -> String = { $0 },
                        appBundles: Set<URL> = [], activityCheck: (URL) -> String = { _ in "/usr/bin/true" }) throws
        -> DeletionService.AdministratorResult {
        var identities: [URL: RemovalIdentity] = [:]
        for url in groups.flatMap({ $0 }) {
            identities[url] = try XCTUnwrap(RemovalIdentity(at: url, bundle: url.pathExtension == "app"))
        }
        return DeletionService.deleteAsAdministrator(groups, prompt: "unused", identities: identities, appBundles: appBundles,
            targetResolver: { $0.path.hasPrefix(self.root.path + "/") ? $0 : nil },
            activityCheck: activityCheck,
            runner: { command, _ in
                do {
                    try beforeRun()
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/bin/sh")
                    task.arguments = ["-c", transformCommand(command)]
                    let output = Pipe()
                    task.standardOutput = output
                    task.standardError = FileHandle.nullDevice
                    try task.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    task.waitUntilExit()
                    return AppleScriptRunner.Output(status: task.terminationStatus,
                        stdout: String(decoding: data, as: UTF8.self), stderr: "", timedOut: false)
                } catch {
                    XCTFail("scratch command failed: \(error)")
                    return AppleScriptRunner.Output(status: 1, stdout: "", stderr: "fixture failed", timedOut: false)
                }
            })
    }

    func testGitAddedInsideExistingNestedDirectoryDuringAuthenticationIsPreserved() throws {
        let sentinel = try write("selected/nested/original")
        let target = root.appendingPathComponent("selected")
        let identity = try XCTUnwrap(FileSnapshot(at: target))

        let result = try remove([[target]], beforeRun: { _ = try self.write("selected/nested/.git/objects/keep") })

        XCTAssertTrue(identity.isSameObject(at: target))
        XCTAssertEqual(result.changed, [target])
        XCTAssertEqual(result.obstacles[target], .changedSinceScan)
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: sentinel.path))
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("nested/.git/objects/keep").path))
    }

    func testVirtualMachineAddedDuringAuthenticationIsPreserved() throws {
        _ = try write("selected/nested/original")
        let target = root.appendingPathComponent("selected")

        let result = try remove([[target]], beforeRun: { _ = try self.write("selected/nested/Machine.utm/disk.img") })

        XCTAssertEqual(result.changed, [target])
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("nested/Machine.utm/disk.img").path))
    }

    func testExistingManagedCacheTagMutationIsDetectedEvenWithRestoredMtime() throws {
        _ = try write("selected/nested/original")
        _ = try write("selected/nested/.lock", "")
        let signature = "Signature: 8a477f597d28d172789f06886806bc55"
        let tag = try write("selected/nested/CACHEDIR.TAG", String(repeating: "x", count: signature.utf8.count))
        let modified = try XCTUnwrap(tag.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let target = root.appendingPathComponent("selected")

        let result = try remove([[target]], beforeRun: {
            try Data(signature.utf8).write(to: tag)
            try self.fm.setAttributes([.modificationDate: modified], ofItemAtPath: tag.path)
        })

        XCTAssertEqual(result.changed, [target])
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(try String(contentsOf: tag, encoding: .utf8), signature)
    }

    func testNewManagedCacheMarkersInAnAncestorPreventDeletingItsBucket() throws {
        _ = try write("cache/selected/nested/original")
        let target = root.appendingPathComponent("cache/selected")

        let result = try remove([[target]], beforeRun: {
            _ = try self.write("cache/.lock", "")
            _ = try self.write("cache/CACHEDIR.TAG", "Signature: 8a477f597d28d172789f06886806bc55")
        })

        XCTAssertEqual(result.changed, [target])
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("nested/original").path))
    }

    func testCaseVariantMarkerMutationsInvalidateTheFingerprint() throws {
        _ = try write("selected/nested/original")
        _ = try write("selected/nested/.LOCK", "")
        let tag = try write("selected/nested/cachedir.tag", "old marker")
        let target = root.appendingPathComponent("selected")
        let before = try XCTUnwrap(DeletionService.treeFingerprint(target, parent: root))

        try Data("new marker".utf8).write(to: tag)

        let after = try XCTUnwrap(DeletionService.treeFingerprint(target, parent: root))
        XCTAssertNotEqual(after, before)
    }

    func testUnchangedBundleAndDataStillDeleteInOrderWithMultilineNames() throws {
        let bundle = root.appendingPathComponent("Applications/it's here\nEditor.app")
        _ = try write("Applications/it's here\nEditor.app/Contents/Info.plist", "bundle identity")
        _ = try write("Applications/it's here\nEditor.app/Contents/Resources/file\nwith a tab\t")
        let data = root.appendingPathComponent("Library/Application Support/editor")
        _ = try write("Library/Application Support/editor/document")

        let result = try remove([[bundle, data]])

        XCTAssertEqual(result.removed, [bundle, data])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: bundle.path))
        XCTAssertFalse(fm.fileExists(atPath: data.path))
    }

    func testAppleScriptCarriageReturnReceiptsAccountForEveryRemovedTarget() throws {
        let bundle = root.appendingPathComponent("Applications/Editor.app")
        _ = try write("Applications/Editor.app/Contents/Info.plist", "bundle identity")
        let data = root.appendingPathComponent("Library/Application Support/editor")
        _ = try write("Library/Application Support/editor/document")

        let result = try remove([[bundle, data]], transformCommand: { command in
            // `do shell script` returns carriage returns between output lines.
            "set -o pipefail; { " + command + "; } | /usr/bin/tr '\\n' '\\r'"
        })

        XCTAssertEqual(result.removed, [bundle, data])
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: bundle.path))
        XCTAssertFalse(fm.fileExists(atPath: data.path))
    }

    func testChangedBundleKeepsItsDataWhileIndependentGroupStillRuns() throws {
        let bundle = root.appendingPathComponent("Applications/Editor.app")
        _ = try write("Applications/Editor.app/Contents/Info.plist", "bundle identity")
        _ = try write("Applications/Editor.app/Contents/Resources/original")
        let data = root.appendingPathComponent("Library/Application Support/editor")
        _ = try write("Library/Application Support/editor/document")
        let independent = try write("independent")

        let result = try remove([[bundle, data], [independent]], beforeRun: {
            _ = try self.write("Applications/Editor.app/Contents/Resources/.git/keep")
        })

        XCTAssertEqual(result.removed, [independent])
        XCTAssertEqual(result.changed, [bundle])
        XCTAssertTrue(fm.fileExists(atPath: bundle.path))
        XCTAssertTrue(fm.fileExists(atPath: data.path))
    }

    func testAdministratorKeepsProtectedDescendantAddedDuringActivityCheck() throws {
        let bundle = root.appendingPathComponent("Applications/Editor.app")
        _ = try write("Applications/Editor.app/Contents/Info.plist", "bundle identity")
        _ = try write("Applications/Editor.app/Contents/Resources/original")
        let protected = bundle.appendingPathComponent("Contents/Resources/.git")
        let data = try write("Library/editor/document")

        let result = try remove([[bundle, data]], appBundles: [bundle], activityCheck: { _ in
            "/bin/mkdir -- " + AppleScriptRunner.shellQuoted(protected.path)
        })

        XCTAssertEqual(result.changed, [bundle])
        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: protected.path))
        XCTAssertTrue(fm.fileExists(atPath: data.path))
    }

    func testSymlinkTargetsAndUnrelatedAncestorChangesDoNotInvalidateSelectedTree() throws {
        _ = try write("selected/nested/original")
        let target = root.appendingPathComponent("selected")
        let external = try write("external/.git/keep", "outside")
        try fm.createSymbolicLink(at: target.appendingPathComponent("external-link"),
                                 withDestinationURL: external.deletingLastPathComponent())

        let result = try remove([[target]], beforeRun: {
            try Data("updated outside".utf8).write(to: external)
            _ = try self.write("unrelated-sibling")
        })

        XCTAssertEqual(result.removed, [target])
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "updated outside")
    }

    func testObjectIdentityIsRecheckedAfterTheFingerprintTraversal() throws {
        let selected = try write("selected-file", "original")
        let replacement = try write("replacement-file", "replacement")
        let result = try remove([[selected]], transformCommand: { command in
            // Insert the replacement after the initial identity guard. Plain
            // file metadata is not part of the directory/marker fingerprint.
            let anchor = "if cac_tree_fingerprint=$("
            XCTAssertTrue(command.contains(anchor))
            let swap = "/bin/mv -f -- " + AppleScriptRunner.shellQuoted(replacement.path)
                + " " + AppleScriptRunner.shellQuoted("./" + selected.lastPathComponent) + "; "
            return command.replacingOccurrences(of: anchor, with: swap + anchor)
        })

        XCTAssertTrue(result.removed.isEmpty)
        XCTAssertEqual(result.changed, [selected])
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "replacement")
    }

    func testMissingTreeFailsFingerprintInsteadOfHashingPartialOutput() {
        XCTAssertNil(DeletionService.treeFingerprint(root.appendingPathComponent("missing"), parent: root))
    }

    func testFingerprintTimeoutFailsClosedWithoutTouchingTheSelection() throws {
        let file = try write("selected/nested/original")
        let target = root.appendingPathComponent("selected")
        XCTAssertNil(DeletionService.treeFingerprint(target, parent: root, timeout: 0))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "selected data")
    }
}
