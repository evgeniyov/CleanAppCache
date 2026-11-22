import XCTest
@testable import CleanAppCacheLib

@MainActor
final class StorageClassificationTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("classification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = try XCTUnwrap(realpath(directory.path, nil))
        defer { free(path) }
        scratch = URL(fileURLWithPath: String(cString: path))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: scratch) }
    private func target(_ name: String) throws -> StorageClassification.Target {
        let url = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return .init(name: name, icon: "folder", url: url)
    }

    func testFoldersAreDisjointAndResidualHasNoRoot() throws {
        let apps = try target("Applications"), docs = try target("Documents")
        let nested = StorageClassification.Target(name: "Nested apps", icon: "folder", url: docs.url.appendingPathComponent("Example.app"))
        let roots = StorageClassification.disjoint([apps, docs, nested, docs])
        XCTAssertEqual(roots.count, 2)
        let measured = StorageClassification.Measurement(bytes: [apps.url.path: 200, docs.url.path: 300])
        let rows = StorageClassification.breakdown(targets: [apps, docs, nested], measurement: measured, total: 1000, used: 800)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.bytes }, 800)
        XCTAssertEqual(rows.first { $0.remainderReason == .unmeasured }?.bytes, 300)
        XCTAssertEqual(rows.first { $0.isResidual }?.path, "")
        XCTAssertFalse(rows.contains { $0.name == "Nested apps" })
    }

    func testUnknownAndPartialNeverBecomeMeasuredZero() throws {
        let docs = try target("Documents")
        let rows = StorageClassification.breakdown(targets: [docs], measurement: .init(), total: 1000, used: 800)
        let row = try XCTUnwrap(rows.first { !$0.isResidual })
        XCTAssertFalse(row.sizeKnown)
        XCTAssertTrue(row.isPartial)
        XCTAssertEqual(row.formattedSize, Fmt.none)
        XCTAssertEqual(rows.first { $0.isResidual }?.bytes, 800)
    }

    func testOverallocatedFoldersDoNotInventAZeroResidualMeasurement() throws {
        let docs = try target("Documents")
        let rows = StorageClassification.breakdown(targets: [docs], measurement: .init(bytes: [docs.url.path: 900]), total: 1000, used: 800)
        XCTAssertTrue(rows.allSatisfy { !$0.reconciled })
        XCTAssertFalse(rows.contains { $0.isResidual })
        XCTAssertEqual(rows.first { !$0.isResidual }?.bytes, 900, "do not silently scale folder sizes")
    }

    func testOneTraversalCountsCrossCategoryHardLinksOnceAndDoesNotFollowSymlinks() async throws {
        let apps = try target("Applications"), docs = try target("Documents"), outside = try target("outside")
        let file = apps.url.appendingPathComponent("shared")
        try Data(repeating: 65, count: 65536).write(to: file)
        try FileManager.default.linkItem(at: file, to: docs.url.appendingPathComponent("hard-link"))
        try Data(repeating: 66, count: 131072).write(to: outside.url.appendingPathComponent("outside-file"))
        try FileManager.default.createSymbolicLink(at: docs.url.appendingPathComponent("external-link"), withDestinationURL: outside.url)
        let sizes = await StorageClassification.measure([apps, docs], volume: scratch)
        XCTAssertFalse(sizes.partial)
        let total = sizes.bytes.values.reduce(0, +)
        let data = await DirectorySizeProbe.capture(executable: URL(fileURLWithPath: "/usr/bin/du"), arguments: ["-skx", apps.url.path, docs.url.path], timeout: 5)
        let expected = StorageClassification.parse(try XCTUnwrap(data), roots: [apps.url, docs.url]).values.reduce(0, +)
        XCTAssertEqual(total, expected)
        XCTAssertGreaterThanOrEqual(total, 65536)
        XCTAssertLessThan(total, 131072, "hard link and external symlink must not add file allocation twice")
        let linkedRoot = scratch.appendingPathComponent("symlink-category")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside.url)
        let link = await StorageClassification.measure([.init(name: "linked", icon: "folder", url: linkedRoot)], volume: scratch)
        XCTAssertFalse(link.partial)
        XCTAssertLessThan(try XCTUnwrap(link.bytes[linkedRoot.path]), 131072)
    }

    func testHardLinkedTopLevelItemCountsOnceWithoutBecomingUnmeasured() async throws {
        let first = scratch.appendingPathComponent("first-link")
        let second = scratch.appendingPathComponent("second-link")
        try Data(repeating: 67, count: 65536).write(to: first)
        try FileManager.default.linkItem(at: first, to: second)
        let result = await StorageClassification.measure([.init(name: "first", icon: "doc", url: first),
                                                          .init(name: "second", icon: "doc", url: second)],
                                                         volume: scratch)
        XCTAssertFalse(result.partial)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.bytes[first.path]), 65536)
        XCTAssertEqual(result.bytes[second.path], 0)
    }

    func testAbsentFolderIsKnownEmptyAndMalformedOutputCannotForgeTargets() async throws {
        let missing = scratch.appendingPathComponent("missing")
        let result = await StorageClassification.measure([.init(name: "missing", icon: "folder", url: missing)], volume: scratch)
        XCTAssertEqual(result.bytes[missing.path], 0)
        let text = "bad\t\(missing.path)\n18446744073709551615\t\(missing.path)\n99\t/forged\n0\t\(missing.path)\n"
        XCTAssertEqual(StorageClassification.parse(Data(text.utf8), roots: [missing]), [missing.path: 0])
    }

    func testFailedProbeKeepsPartialOutputWithoutPretendingSuccess() async throws {
        let response = await DirectorySizeProbe.captureResponse(executable: URL(fileURLWithPath: "/bin/sh"),
                                                                arguments: ["-c", "printf '12\\t/synthetic\\n'; exit 1"], timeout: 3)
        let captured = try XCTUnwrap(response)
        XCTAssertFalse(captured.succeeded)
        XCTAssertEqual(StorageClassification.parse(captured.data, roots: [URL(fileURLWithPath: "/synthetic")]), ["/synthetic": 12288])
    }

    func testStartupPartitionFindsEveryGroupAndDataBranch() throws {
        let directories = [
            "Applications", "Users/me/Applications", "Users/me/Documents", "Users/me/Downloads",
            "Users/me/Desktop", "Users/me/Movies", "Users/me/Music", "Users/me/Pictures",
            "Users/me/Library/Application Support", "Users/me/Library/Caches", "Users/me/Library/Logs",
            "Users/me/Library/Containers", "Users/me/Library/Group Containers", "Users/me/Library/Developer",
            "Users/me/Library/Mail", "Users/me/Library/Messages", "Users/me/Library/Mobile Documents",
            "Users/me/Library/Other", "Users/me/Projects", "Users/me/.cache", "Users/Shared", "Users/another",
            "Library", "private/var", "private/etc", "usr/local", "usr/share", "opt", ".Spotlight-V100"
        ]
        for entry in directories { _ = try target(entry) }
        for entry in ["Users/me/.localfile", "Users/me/notes.txt"] {
            XCTAssertTrue(FileManager.default.createFile(atPath: scratch.appendingPathComponent(entry).path, contents: Data()))
        }
        let targets = StorageClassification.targets(volume: scratch, home: scratch.appendingPathComponent("Users/me"))
        let all = Set(targets.map { String($0.url.path.dropFirst(scratch.path.count + 1)) })
        XCTAssertEqual(all, Set(directories + ["Users/me/.localfile", "Users/me/notes.txt"]))
        XCTAssertEqual(StorageClassification.disjoint(targets).count, all.count)
        let logical = StorageClassification.targets(volume: scratch, home: URL(fileURLWithPath: "/Users/me"))
        XCTAssertEqual(logical.map(\.url.path), targets.map(\.url.path))
        XCTAssertEqual(logical.map(\.name), targets.map(\.name))
        let aliased = StorageClassification.targets(volume: scratch, home: scratch.appendingPathComponent("Users/me")) { parent in
            try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).map {
                URL(fileURLWithPath: "/different/parent/" + $0.lastPathComponent)
            }
        }
        XCTAssertEqual(aliased.map(\.url.path), targets.map(\.url.path))
        XCTAssertEqual(aliased.map(\.name), targets.map(\.name))
        let measurement = StorageClassification.Measurement(bytes: Dictionary(uniqueKeysWithValues: targets.map {
            ($0.url.path, UInt64(100))
        }))
        let used = UInt64(targets.count) * 100
        let rows = StorageClassification.breakdown(targets: targets, measurement: measurement, total: 10_000, used: used)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.bytes }, used)
        XCTAssertFalse(rows.contains { $0.isResidual })
        func names(_ category: String) -> Set<String> {
            Set(rows.first { $0.name == category }?.members?.map(\.name) ?? [])
        }
        XCTAssertEqual(rows.count, 18)
        XCTAssertEqual(names("Applications"), ["Applications"])
        XCTAssertEqual(rows.first { $0.name == "Applications" }?.members?.count, 2)
        XCTAssertEqual(names("Your folders"), ["Projects", "notes.txt"])
        XCTAssertEqual(names("Hidden folders"), [".cache", ".localfile"])
        XCTAssertEqual(names("Containers"), ["Containers", "Group Containers"])
        XCTAssertEqual(names("Mail and Messages"), ["Mail", "Messages"])
        XCTAssertEqual(names("Other Library"), ["Other"])
        XCTAssertEqual(names("System Data"), ["Library", "var", "etc", "local", "share", "opt", "Shared", "another", ".Spotlight-V100"])
        XCTAssertEqual(rows.first { $0.name == "Developer" }?.path, scratch.appendingPathComponent("Users/me/Library/Developer").path)
    }

    func testOnlyAffectedRowsArePartialAndRemainderExplainsDenial() throws {
        let docs = try target("Documents"), apps = try target("Applications")
        let measurement = StorageClassification.Measurement(
            bytes: [docs.url.path: 200, apps.url.path: 300],
            issues: [.init(path: docs.url.appendingPathComponent("Denied").path, reasonKey: "detail.accessDenied")])
        let rows = StorageClassification.breakdown(targets: [docs, apps], measurement: measurement, total: 1_000, used: 800)
        XCTAssertEqual(rows.first { $0.remainderReason == .protected }?.bytes, 300)
        XCTAssertEqual(rows.first { $0.name == docs.name }?.isPartial, true)
        XCTAssertEqual(rows.first { $0.name == apps.name }?.isPartial, false)
        let granted = StorageClassification.breakdown(targets: [docs, apps], measurement: measurement,
                                                      total: 1_000, used: 800, hasFullDiskAccess: true)
        XCTAssertEqual(granted.first { $0.remainderReason == .unmeasured }?.bytes, 300)
    }

    func testUnreadableLibraryDoesNotLookLikeRemovedCategories() async throws {
        let home = scratch.appendingPathComponent("Users/me")
        let library = home.appendingPathComponent("Library")
        let caches = try target("Users/me/Library/Caches")
        let containers = try target("Users/me/Library/Containers")
        let documents = try target("Users/me/Documents")
        for directory in [caches, containers, documents] {
            try Data(repeating: 1, count: 65_536).write(to: directory.url.appendingPathComponent("fixture"))
        }

        let complete = StorageClassification.targets(volume: scratch, home: home)
        let incomplete = StorageClassification.targets(volume: scratch, home: home) { url in
            if url.path == library.path { throw CocoaError(.fileReadNoPermission) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
        let before = await StorageClassification.measure(complete, volume: scratch)
        let after = await StorageClassification.measure(incomplete, volume: scratch)
        XCTAssertEqual(after.probeFailed, false)
        XCTAssertGreaterThan(try XCTUnwrap(after.bytes[library.path]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: caches.url.path))

        let used: UInt64 = 1_000_000_000
        let beforeRows = StorageClassification.breakdown(targets: complete, measurement: before, total: used, used: used)
        let afterRows = StorageClassification.breakdown(targets: incomplete, measurement: after, total: used, used: used)
        let date = Date()
        let original = StorageSnapshot(date: date, usedBytes: used, breakdown: beforeRows)
        let snapshot = StorageSnapshot(date: date.addingTimeInterval(86_400), usedBytes: used, breakdown: afterRows)
        let restored = try JSONDecoder().decode(StorageSnapshot.self, from: JSONEncoder().encode(snapshot))
        // Losing and regaining access changes which rows exist, not what is on
        // disk: neither direction may report an existing folder as removed.
        for comparison in [StorageSnapshotComparison(from: original, to: restored),
                           StorageSnapshotComparison(from: restored, to: original)] {
            XCTAssertFalse(comparison.changes.contains { $0.presence == .removed })
            XCTAssertFalse(comparison.changes.contains { $0.category == StorageCategory.userCaches.rawValue })
        }
        let homeDenied = StorageClassification.targets(volume: scratch, home: home) { url in
            if url.path == home.path { throw CocoaError(.fileReadNoPermission) }
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
        let homeMeasured = await StorageClassification.measure(homeDenied, volume: scratch)
        let homeRows = StorageClassification.breakdown(targets: homeDenied, measurement: homeMeasured, total: used, used: used)
        let homeSnapshot = StorageSnapshot(date: date.addingTimeInterval(172_800), usedBytes: used, breakdown: homeRows)
        let homeComparison = StorageSnapshotComparison(from: original, to: homeSnapshot)
        XCTAssertFalse(homeComparison.changes.contains { $0.presence == .removed })
        XCTAssertTrue(homeComparison.changes.allSatisfy(\.uncertain),
                      "a fallback layout cannot be compared exactly in either direction")
        XCTAssertTrue(StorageSnapshotComparison(from: homeSnapshot, to: original).changes.allSatisfy(\.uncertain))

        // A complete member row cannot outweigh a snapshot whose layout fell back.
        let flagged = StorageSnapshot(date: date, usedBytes: used, categories: [
            .init(key: StorageCategory.yourFolders.rawValue, bytes: 400_000_000, partial: false, members: [
                .init(id: "/zone", name: "Zone", bytes: 400_000_000, partial: false)])], enumerationFailed: true)
        let clean = StorageSnapshot(date: date.addingTimeInterval(-60), usedBytes: used, categories: [
            .init(key: StorageCategory.yourFolders.rawValue, bytes: 100_000_000, partial: false, members: [
                .init(id: "/zone", name: "Zone", bytes: 100_000_000, partial: false)])])
        XCTAssertTrue(StorageSnapshotComparison(from: clean, to: flagged).changes.allSatisfy(\.uncertain))
        // The same unreadable folders on both days keep exact figures; a
        // change in them can move hard-linked allocation between folders.
        let deniedBefore = StorageSnapshot(date: date, usedBytes: used, categories: clean.categories,
                                           unreadablePaths: ["/home/Library/Containers"])
        let deniedSame = StorageSnapshot(date: date.addingTimeInterval(60), usedBytes: used,
                                         categories: flagged.categories, unreadablePaths: ["/home/Library/Containers"])
        let deniedMore = StorageSnapshot(date: date.addingTimeInterval(60), usedBytes: used,
                                         categories: flagged.categories,
                                         unreadablePaths: ["/home/Archive/Private", "/home/Library/Containers"])
        XCTAssertTrue(StorageSnapshotComparison(from: deniedBefore, to: deniedSame).changes.contains { !$0.uncertain })
        XCTAssertTrue(StorageSnapshotComparison(from: deniedBefore, to: deniedMore).changes.allSatisfy(\.uncertain))
        let partialLegacy = StorageSnapshot(date: date, usedBytes: used, categories: [
            .init(key: StorageCategory.yourFolders.rawValue, bytes: 100_000_000, partial: true, members: [
                .init(id: "/zone", name: "Zone", bytes: 100_000_000, partial: false)])])
        let readable = StorageSnapshot(date: date.addingTimeInterval(60), usedBytes: used,
                                       categories: flagged.categories)
        XCTAssertNil(partialLegacy.knownUnreadable)
        XCTAssertTrue(StorageSnapshotComparison(from: partialLegacy, to: readable).changes.allSatisfy(\.uncertain))
        let legacy = Data(#"{"date":0,"usedBytes":1,"categories":[],"libraryEnumerationFailed":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(StorageSnapshot.self, from: legacy).enumerationFailed, true)

        // A folder that cannot be checked is not a folder that is gone.
        let locked = scratch.appendingPathComponent("locked")
        let hidden = locked.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let listed = StorageSnapshot(date: date, usedBytes: used, categories: [
            .init(key: StorageCategory.yourFolders.rawValue, bytes: 300_000_000, partial: false, members: [
                .init(id: hidden.path, name: "project", bytes: 300_000_000, partial: false, folderPath: hidden.path)])])
        let unlisted = StorageSnapshot(date: date.addingTimeInterval(60), usedBytes: used, categories: [
            .init(key: StorageCategory.yourFolders.rawValue, bytes: 0, partial: false, members: [])])
        XCTAssertNil(StorageSnapshotComparison(from: listed, to: unlisted).changes.first { $0.member != nil })

        let gone = StorageSnapshot(date: date, usedBytes: used, categories: [
            .init(key: StorageCategory.yourFolders.rawValue, bytes: 300_000_000, partial: false, members: [
                .init(id: "/missing/project", name: "project", bytes: 300_000_000, partial: false,
                      folderPath: "/missing/project")])])
        let empty = StorageSnapshot(date: date.addingTimeInterval(60), usedBytes: used, categories: [
            .init(key: StorageCategory.yourFolders.rawValue, bytes: 0, partial: false, members: [])])
        let removal = StorageSnapshotComparison(from: gone, to: empty, pathExists: { _ in false })
        XCTAssertEqual(removal.changes.first { $0.member != nil }?.presence, .removed)
        let stillThere = StorageSnapshotComparison(from: gone, to: empty, pathExists: { _ in true })
        XCTAssertNil(stillThere.changes.first { $0.member != nil })

        let libraryRow = try XCTUnwrap(afterRows.first { $0.name == StorageCategory.otherLibrary.rawValue })
        XCTAssertTrue(libraryRow.isPartial)
        XCTAssertEqual(libraryRow.accessIssues.first?.path, library.path)
        XCTAssertEqual(libraryRow.accessIssues.first?.reasonKey, "detail.accessDenied")
        XCTAssertEqual(afterRows.first { $0.name == StorageCategory.documents.rawValue }?.isPartial, false)
        XCTAssertEqual(restored.categories.first { $0.key == libraryRow.name }?.partial, true)
    }

    func testAPFSPlistKeepsOnlyOtherVolumesOfStartupContainer() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Containers</key><array>
        <dict><key>Volumes</key><array>
        <dict><key>DeviceIdentifier</key><string>disk1s1</string><key>CapacityInUse</key><integer>900</integer></dict>
        </array></dict>
        <dict><key>Volumes</key><array>
        <dict><key>DeviceIdentifier</key><string>disk3s5</string><key>Roles</key><array><string>Data</string></array>
        <key>CapacityInUse</key><integer>500</integer></dict>
        <dict><key>DeviceIdentifier</key><string>disk3s1</string><key>Name</key><string>macOS</string>
        <key>Roles</key><array><string>System</string></array><key>CapacityInUse</key><integer>140</integer></dict>
        <dict><key>DeviceIdentifier</key><string>disk3s3</string><key>Name</key><string>Recovery</string>
        <key>Roles</key><array><string>Recovery</string></array><key>CapacityInUse</key><integer>20</integer></dict>
        <dict><key>DeviceIdentifier</key><string>disk3s7</string><key>Name</key><string>Locked</string></dict>
        </array></dict>
        </array></dict></plist>
        """
        let data = Data(plist.utf8)
        let volumes = try XCTUnwrap(StorageAPFSVolumes.parse(data, dataDevice: "disk3s5"))
        XCTAssertTrue(volumes.isPartial)
        XCTAssertEqual(volumes.members.map(\.device), ["disk3s1", "disk3s3", "disk3s7"])
        XCTAssertEqual(volumes.members.map(\.roles), [["System"], ["Recovery"], []])
        XCTAssertNil(StorageAPFSVolumes.parse(data, dataDevice: "disk7s5"))
        let rows = StorageClassification.breakdown(targets: [], measurement: .init(), volumes: volumes, total: 1_000, used: 500)
        XCTAssertEqual(rows.first { $0.isResidual }?.bytes, 340)
        let row = try XCTUnwrap(rows.first { !$0.isResidual })
        XCTAssertEqual(row.bytes, 160)
        XCTAssertTrue(row.isPartial)
        XCTAssertEqual(row.members?.first?.size, 140)
        XCTAssertEqual(row.members?.last?.sizeKnown, false)
    }

    func testOverviewCacheKeepsBatchTogetherAndRejectsOldGeneration() async throws {
        let cache = DiskCacheManager(directory: scratch)
        let paths = ["/Volumes/fixture/first", "/Volumes/fixture/second"]
        let generation = await cache.generation
        let measurement = StorageClassification.Measurement(bytes: [paths[0]: 80, paths[1]: 20])
        await cache.saveStorageMeasurement(measurement, device: "disk9s1", paths: paths,
                                           hasFullDiskAccess: false, ifGeneration: generation)
        let restored = DiskCacheManager(directory: scratch)
        let saved = await restored.storageMeasurement(device: "disk9s1", paths: paths, hasFullDiskAccess: false)
        XCTAssertEqual(saved?.bytes, measurement.bytes)
        let changedAccess = await restored.storageMeasurement(device: "disk9s1", paths: paths, hasFullDiskAccess: true)
        XCTAssertNil(changedAccess)
        await cache.invalidate(under: paths[0])
        await cache.saveStorageMeasurement(measurement, device: "disk9s1", paths: paths,
                                           hasFullDiskAccess: false, ifGeneration: generation)
        let invalidated = await cache.storageMeasurement(device: "disk9s1", paths: paths, hasFullDiskAccess: false)
        let afterRestart = await DiskCacheManager(directory: scratch).storageMeasurement(
            device: "disk9s1", paths: paths, hasFullDiskAccess: false)
        XCTAssertNil(invalidated)
        XCTAssertNil(afterRestart)
    }

    func testSelectingResidualCancelsPriorDetailsWithoutScanningRoot() async throws {
        let docs = try target("Documents")
        let manager = StorageManager(diskCache: DiskCacheManager(directory: scratch.appendingPathComponent("cache")),
                                     measure: { _, _ in try? await Task.sleep(nanoseconds: 200_000_000); return [:] })
        let model = StorageViewModel(manager: manager)
        model.loadDetail(for: .init(name: "Documents", icon: "folder", bytes: 0, path: docs.url.path, percentOfTotal: 0))
        model.loadDetail(for: .init(name: "Other", icon: "folder", bytes: 800, path: "", percentOfTotal: 0.8, isResidual: true))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(model.detailItems.isEmpty)
        XCTAssertFalse(model.isLoadingDetail)
        XCTAssertFalse(model.isSizingDetail)
        XCTAssertEqual(model.currentDetailPath, "")
    }
}
