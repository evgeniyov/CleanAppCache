import XCTest
import Darwin
@testable import CleanAppCacheLib

final class ScannerAuditRegressionTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("scanner-audit-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: root)
    }

    private func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 8192).write(to: url.appendingPathComponent("payload"))
        return url
    }

    private func manager() -> DevCleanManager {
        DevCleanManager(isInUse: { _ in false }, uvIsInUse: { false },
                        uvCleaner: UvCacheCleaner(home: root, environment: [:], discoverExecutable: false))
    }

    func testDeveloperCleanupKeepsReplacedCache() async throws {
        let url = try directory("cache")
        let item = DevJunkItem(definitionID: "npm", url: url, size: 8192, safe: true)
        try fm.moveItem(at: url, to: root.appendingPathComponent("original-cache"))
        _ = try directory("cache")
        let candidate = manager()

        let result = await candidate.clean(items: [item])

        XCTAssertTrue(result.cleaned.isEmpty)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("payload").path))
        let report = await candidate.lastRemovalResult
        XCTAssertEqual(report?.obstacles[url], .changedSinceScan)
    }

    func testProjectCleanupKeepsReplacedArtifact() async throws {
        let url = try directory("project/node_modules")
        let parent = url.deletingLastPathComponent()
        try Data("{}".utf8).write(to: parent.appendingPathComponent("package.json"))
        let item = ProjectArtifact(url: url, projectName: "project", projectPath: parent.path,
                                   kind: .node, size: 8192, projectModified: .distantPast)
        try fm.moveItem(at: url, to: root.appendingPathComponent("original-modules"))
        _ = try directory("project/node_modules")

        let result = await manager().cleanProjects([item])

        XCTAssertTrue(result.cleaned.isEmpty)
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("payload").path))
    }

    func testInstallerScanMeasuresPackageDirectories() async throws {
        let mpkg = try directory("legacy.mpkg")
        let pkg = try directory("legacy.pkg")
        let result = await Scanner.shared.scanCategory(category: .installers,
            source: .filesMatching(directory: root.path, extensions: ["mpkg", "pkg"]),
            inUse: { _ in false })

        XCTAssertEqual(Set(result.items.map { $0.url.resolvingSymlinksInPath().path }),
                       Set([mpkg, pkg].map { $0.resolvingSymlinksInPath().path }))
        XCTAssertTrue(result.items.allSatisfy { $0.size >= 8192 && !$0.autoSelect })
        XCTAssertEqual(result.skipped.totalCount, 0)
    }

    func testInstallerScanKeepsProtectedPackageContentsExcluded() async throws {
        let package = try directory("protected.mpkg")
        try fm.createDirectory(at: package.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let result = await Scanner.shared.scanCategory(category: .installers,
            source: .filesMatching(directory: root.path, extensions: ["mpkg"]), inUse: { _ in false })
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.counts[.safetyProtected], 1)
    }
    func testSystemJunkCleanupKeepsReplacedTarget() async throws {
        let url = try directory("derived-data")
        let entry = SystemJunkEntry(category: .xcodeDerivedData, urls: [url], totalSize: 8192)
        try fm.moveItem(at: url, to: root.appendingPathComponent("original-derived-data"))
        _ = try directory("derived-data")

        let result = await SystemJunkManager.shared.clean(entry)

        XCTAssertEqual(result.validationRejected, [url])
        XCTAssertEqual(result.obstacles[url], .changedSinceScan)
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("payload").path))
    }

    func testSystemJunkPartialResultKeepsOriginalIdentity() throws {
        let survivor = try directory("survivor")
        let gone = try directory("gone")
        let entry = SystemJunkEntry(category: .quickLookCache, urls: [survivor, gone], totalSize: 16384)
        try fm.moveItem(at: survivor, to: root.appendingPathComponent("original-survivor"))
        _ = try directory("survivor")

        let partial = entry.keeping(urls: [survivor], totalSize: 8192)

        XCTAssertEqual(partial.id, entry.id)
        XCTAssertFalse(partial.matches(survivor))
        XCTAssertNil(partial.removalIdentities[gone])
    }

    func testSystemJunkFinderRetryKeepsReplacedTarget() throws {
        let url = try directory("protected-cache")
        let entry = SystemJunkEntry(category: .quickLookCache, urls: [url], totalSize: 8192)
        let initial = TrashService.Result(trashed: [], failed: [url], obstacles: [url: .needsAdmin], freedBytes: 0)
        try fm.moveItem(at: url, to: root.appendingPathComponent("original-protected-cache"))
        _ = try directory("protected-cache")

        let retry = TrashService.escalate(initial, knownSizes: [:], allowing: [], validation: { candidate in
            entry.matches(candidate) && SystemJunkManager.canMoveToTrash(candidate, category: entry.category)
        }, dispatch: { _ in
            XCTFail("Finder must not receive a replaced target")
            return .init(status: 1, stdout: "", stderr: "", timedOut: false)
        })
        let result = SystemJunkManager.classifyChanges(retry, entries: [entry])

        XCTAssertEqual(result.obstacles[url], .changedSinceScan)
        XCTAssertEqual(result.validationRejected, [url])
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("payload").path))
    }

    func testDeveloperCleanupKeepsRedirectedParent() async throws {
        let url = try directory("project/cache")
        let parent = url.deletingLastPathComponent()
        let item = DevJunkItem(definitionID: "npm", url: url, size: 8192, safe: true)
        let moved = root.appendingPathComponent("original-project")
        try fm.moveItem(at: parent, to: moved)
        try fm.createSymbolicLink(at: parent, withDestinationURL: moved)

        let result = await manager().clean(items: [item])

        XCTAssertTrue(result.cleaned.isEmpty)
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(fm.fileExists(atPath: moved.appendingPathComponent("cache/payload").path))
    }

    func testMissingDeveloperSelectionNeverBindsToNewObject() async throws {
        let url = root.appendingPathComponent("later-cache")
        let item = DevJunkItem(definitionID: "npm", url: url, size: 8192, safe: true)
        _ = try directory("later-cache")

        let result = await manager().clean(items: [item])

        XCTAssertTrue(result.cleaned.isEmpty)
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("payload").path))
    }

    func testEverySmartCleanupCategoryRejectsReplacementDuringSizing() async throws {
        for category in ScanCategory.allCases {
            let url = root.appendingPathComponent("selected-" + category.rawValue)
            let replacement = root.appendingPathComponent("replacement-" + category.rawValue)
            try Data(repeating: 42, count: 8192).write(to: url)
            try Data(repeating: 43, count: 8192).write(to: replacement)
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: url.path)

            let result = await Scanner.shared.scanCategory(category: category,
                source: .directories([url.path]), inUse: { _ in false }, sizeProvider: { _ in
                    XCTAssertEqual(rename(replacement.path, url.path), 0)
                    return [url.path: 8192]
                })

            XCTAssertTrue(result.items.isEmpty, category.rawValue)
            XCTAssertEqual(result.skipped.counts[.unreadable], 1, category.rawValue)
            XCTAssertTrue(fm.fileExists(atPath: url.path))
        }
    }

    func testInstallerIdentitySurvivesScanAndRejectsReplacement() async throws {
        let url = root.appendingPathComponent("setup.dmg")
        let replacement = root.appendingPathComponent("replacement")
        try Data(repeating: 42, count: 8192).write(to: url)
        try Data(repeating: 43, count: 8192).write(to: replacement)
        let result = await Scanner.shared.scanCategory(category: .installers,
            source: .filesMatching(directory: root.path, extensions: ["dmg"]), inUse: { _ in false })
        let item = try XCTUnwrap(result.items.first)
        XCTAssertTrue(item.removalIdentity?.matches(item.url) == true)

        XCTAssertEqual(rename(replacement.path, url.path), 0)

        XCTAssertFalse(item.removalIdentity?.matches(item.url) == true)
    }

    func testInstallerReplacedDuringEligibilityIsNotOffered() async throws {
        let url = root.appendingPathComponent("setup.dmg")
        let replacement = root.appendingPathComponent("replacement")
        try Data(repeating: 42, count: 8192).write(to: url)
        try Data(repeating: 43, count: 8192).write(to: replacement)
        let result = await Scanner.shared.scanCategory(category: .installers,
            source: .filesMatching(directory: root.path, extensions: ["dmg"]), inUse: { candidate in
                XCTAssertEqual(rename(replacement.path, candidate.path), 0)
                return false
            })
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.counts[.unreadable], 1)
    }

    func testCachedCleanupRowNeverAcquiresCurrentObjectIdentity() throws {
        let url = try directory("cached")
        let scanned = CleanableItem(url: url, category: .userCache, size: 8192, itemCount: 1)
        XCTAssertNotNil(scanned.removalIdentity)
        let encoded = try JSONEncoder().encode(CleanableItem.Cached(from: scanned))
        let restored = try JSONDecoder().decode(CleanableItem.Cached.self, from: encoded).toCleanableItem()
        XCTAssertNil(restored.removalIdentity)
        XCTAssertEqual(restored.url.path, url.path)
    }

    func testDeveloperCleanupDoesNotMistakeDeniedParentForMissingTarget() async throws {
        let url = try directory("restricted/cache")
        let parent = url.deletingLastPathComponent()
        let item = DevJunkItem(definitionID: "npm", url: url, size: 8192, safe: true)
        let candidate = manager()
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: parent.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }

        let result = await candidate.clean(items: [item])

        XCTAssertTrue(result.cleaned.isEmpty)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.freedBytes, 0)
        let report = await candidate.lastRemovalResult
        XCTAssertEqual(report?.failed, [url])
        XCTAssertTrue(report?.alreadyGone.isEmpty == true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        XCTAssertTrue(fm.fileExists(atPath: url.appendingPathComponent("payload").path))
    }

    func testDeveloperMissingSelectionRemainsInRemovalReport() async throws {
        let url = try directory("removed-cache")
        let item = DevJunkItem(definitionID: "npm", url: url, size: 8192, safe: true)
        let candidate = manager()
        try fm.removeItem(at: url)

        let result = await candidate.clean(items: [item])

        XCTAssertEqual(result.cleaned, [item.id])
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.freedBytes, 0)
        let report = await candidate.lastRemovalResult
        XCTAssertEqual(report?.alreadyGone, [url])
    }

}
