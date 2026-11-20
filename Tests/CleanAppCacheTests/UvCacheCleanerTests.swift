import XCTest
import Darwin
@testable import CleanAppCacheLib

final class UvCacheCleanerTests: XCTestCase {
    private var temp: URL!
    private var home: URL!
    private var environment: [String: String]!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uv-test-\(UUID().uuidString)")
        home = temp.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        environment = ["HOME": home.path, "PATH": "/usr/bin:/bin",
                       "XDG_CONFIG_HOME": temp.appendingPathComponent("config").path,
                       "XDG_CONFIG_DIRS": temp.appendingPathComponent("system-config").path]
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func executable() throws -> URL {
        let testEnvironment = ProcessInfo.processInfo.environment
        if let path = testEnvironment["CAC_TEST_UV"], !path.isEmpty {
            let installed = FileManager.default.isExecutableFile(atPath: path)
            return try XCTUnwrap(installed ? URL(fileURLWithPath: path) : nil,
                                 "CAC_TEST_UV must point to an executable uv")
        }
        if testEnvironment["GITHUB_ACTIONS"] == "true" {
            return try XCTUnwrap(nil, "CI must set CAC_TEST_UV to the pinned uv executable")
        }
        if testEnvironment["CAC_TEST_NO_UV"] == "1" {
            throw XCTSkip("uv discovery is disabled by CAC_TEST_NO_UV")
        }
        guard let result = UvCacheCleaner.findExecutable(home: FileManager.default.homeDirectoryForCurrentUser,
                                                        environment: testEnvironment) else {
            throw XCTSkip("uv is required for the scratch-cache CLI integration tests")
        }
        return result
    }

    private func cleaner(timeout: TimeInterval = 30) throws -> UvCacheCleaner {
        UvCacheCleaner(home: home, environment: environment, executable: try executable(), timeout: timeout)
    }

    @discardableResult
    private func cache(at url: URL? = nil) throws -> URL {
        let root = url ?? home.appendingPathComponent(".cache/uv")
        let bucket = root.appendingPathComponent("sdists-v9")
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        try Data("Signature: 8a477f597d28d172789f06886806bc55\n".utf8).write(to: root.appendingPathComponent("CACHEDIR.TAG"))
        try Data().write(to: root.appendingPathComponent(".lock"))
        // uv's own cache scaffold has this marker; a generic tree guard rejects it.
        try Data().write(to: bucket.appendingPathComponent(".git"))
        try Data(repeating: 42, count: 131_072).write(to: bucket.appendingPathComponent("payload"))
        return root
    }

    private func item(_ root: URL) -> DevJunkItem {
        var result = DevJunkItem(definitionID: "uv-cache", url: root,
                                 size: Scanner.shared.calculateSize(at: root), safe: false)
        result.uvIdentity = RemovalIdentity(at: root)
        return result
    }

    func testDefaultDiscoveryAndAllocatedSizeIncludeHiddenCache() async throws {
        let root = try cache()
        // A hard link must not inflate the estimate.
        try FileManager.default.linkItem(at: root.appendingPathComponent("sdists-v9/payload"),
                                         to: root.appendingPathComponent("sdists-v9/second-link"))
        let service = try cleaner()
        XCTAssertEqual(service.location().url.path, root.path)
        let manager = DevCleanManager(isInUse: { _ in false }, uvIsInUse: { false }, uvCleaner: service)
        let found = await manager.scanUvCache()
        XCTAssertEqual(found?.url.path, root.path)
        XCTAssertEqual(found?.size, Scanner.shared.calculateSizes(at: [root])[root.path])
        XCTAssertLessThan(try XCTUnwrap(found?.size), 262_144)
        XCTAssertNil(found?.cleanupUnavailableReasonKey)
        XCTAssertEqual(found?.safe, false)
    }

    func testEnvironmentAndXDGPrecedence() throws {
        environment["XDG_CACHE_HOME"] = temp.appendingPathComponent("xdg").path
        let xdgService = try cleaner()
        XCTAssertEqual(xdgService.location().url.path, environment["XDG_CACHE_HOME"]! + "/uv")
        environment["UV_CACHE_DIR"] = temp.appendingPathComponent("chosen with spaces").path
        let configuredService = try cleaner()
        XCTAssertEqual(configuredService.location().url.path, environment["UV_CACHE_DIR"])
    }

    func testCachePathParserPreservesFilenameWhitespaceAndRejectsMultipleRecords() {
        XCTAssertEqual(UvCacheCleaner.cachePath(from: "/cache \t\n"), "/cache \t")
        XCTAssertEqual(UvCacheCleaner.cachePath(from: "/cache \r\n"), "/cache ")
        XCTAssertEqual(UvCacheCleaner.cachePath(from: "/cache "), "/cache ")
        XCTAssertNil(UvCacheCleaner.cachePath(from: "/cache\n/neighbor\n"))
        XCTAssertNil(UvCacheCleaner.cachePath(from: "/cache\n\n"))
    }

    func testNativeDiscoveryAndCleanPreserveTrailingSpaceWithoutTouchingNeighbor() throws {
        let neighbor = try cache(at: temp.appendingPathComponent("cache"))
        let configured = try cache(at: temp.appendingPathComponent("cache "))
        environment["UV_CACHE_DIR"] = configured.path
        let service = try cleaner()
        XCTAssertEqual(service.location().url.path, configured.path)
        let result = service.clean(item(configured), isInUse: { _ in false })
        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.appendingPathComponent("sdists-v9/payload").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configured.appendingPathComponent("sdists-v9/payload").path))
    }

    func testNativePythonAndBinariesBucketsAreAcceptedAndCleaned() throws {
        let service = try cleaner()
        let root = try cache()
        for name in ["python-v0", "binaries-v0"] {
            let bucket = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
            try Data("cached".utf8).write(to: bucket.appendingPathComponent("payload"))
        }
        XCTAssertTrue(UvCacheCleaner.validCache(root, identity: RemovalIdentity(at: root)))
        XCTAssertTrue(service.clean(item(root), isInUse: { _ in false }).succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("python-v0/payload").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("binaries-v0/payload").path))
    }

    func testNativeCacheRejectsProtectedDescendantsIncludingInsideGit() throws {
        for (index, path) in ["sdists-v9/Photos.photoslibrary", "archive-v0/guest.utm",
                              "git-v0/repo/.git/backup.sparsebundle", "git-v0/repo/.git/.Spotlight-V100",
                              "git-v0/repo/.git/Photos.photoslibrary", "git-v0/repo/.git/guest.utm"].enumerated() {
            let root = try cache(at: temp.appendingPathComponent("protected-cache-\(index)"))
            let protected = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
            let sentinel = protected.appendingPathComponent("keep")
            try Data("retained".utf8).write(to: sentinel)
            XCTAssertFalse(UvCacheCleaner.validCache(root, identity: RemovalIdentity(at: root)), path)
            XCTAssertEqual(try String(contentsOf: sentinel), "retained")
        }
    }

    func testNativeCleanPreservesProtectedCacheContents() throws {
        let root = try cache()
        let protected = root.appendingPathComponent("sdists-v9/Photos.photoslibrary")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        let sentinel = protected.appendingPathComponent("keep")
        try Data("retained".utf8).write(to: sentinel)
        let result = try cleaner().clean(item(root), isInUse: { _ in false })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.reasonKey, "dev.uv.changed")
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertEqual(try String(contentsOf: sentinel), "retained")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sdists-v9/payload").path))
    }

    func testNativeCacheRejectsNestedManagedCachesAndManagedAncestors() throws {
        let root = try cache()
        let nested = try cache(at: root.appendingPathComponent("sdists-v9/inner-cache"))
        XCTAssertFalse(UvCacheCleaner.validCache(root, identity: RemovalIdentity(at: root)))
        XCTAssertFalse(UvCacheCleaner.validCache(nested, identity: RemovalIdentity(at: nested)))
    }

    func testAncestorWalkTerminatesForDirectoryDerivedFromFileURL() throws {
        let file = temp.appendingPathComponent("ordinary/build-cache/blob")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("build".utf8).write(to: file)
        // Reinitializing this URL from its path can hide Foundation's / -> /.. behavior.
        XCTAssertFalse(UvCacheCleaner.containsCacheOrUnverified(file.deletingLastPathComponent()))
    }

    func testNativeCacheRejectsUnreadableDescendants() throws {
        guard geteuid() != 0 else { throw XCTSkip("root bypasses scratch POSIX permissions") }
        let root = try cache()
        let locked = root.appendingPathComponent("sdists-v9/locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("retained".utf8).write(to: locked.appendingPathComponent("keep"))
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { _ = chmod(locked.path, 0o700) }
        XCTAssertFalse(UvCacheCleaner.validCache(root, identity: RemovalIdentity(at: root)))
    }

    func testNativeCacheGuardBoundsTraversalAndRetainsGenericProtection() throws {
        let root = try cache()
        XCTAssertEqual(PathGuard.rejectTree(root), .managedCache)
        XCTAssertNil(PathGuard.rejectUvCacheTree(root))
        XCTAssertEqual(PathGuard.rejectUvCacheTree(root, limit: 1), .unverifiedContents)
        let ordinary = temp.appendingPathComponent("ordinary")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        XCTAssertNotNil(PathGuard.rejectUvCacheTree(ordinary))
    }

    func testNativeCacheGuardRejectsDirectoryReplacedByLink() throws {
        let root = try cache()
        let child = root.appendingPathComponent("sdists-v9/mutable")
        let outside = temp.appendingPathComponent("outside/Photos.photoslibrary")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep")
        try Data("retained".utf8).write(to: sentinel)
        var replaced = false
        let rejection = PathGuard.rejectUvCacheTree(root, beforeInspect: { url in
            guard url.lastPathComponent == "mutable", !replaced else { return }
            replaced = true
            do {
                try FileManager.default.moveItem(at: child, to: temp.appendingPathComponent("moved"))
                try FileManager.default.createSymbolicLink(at: child, withDestinationURL: outside)
            } catch { XCTFail("Cannot replace scratch child: \(error)") }
        })
        XCTAssertTrue(replaced)
        XCTAssertEqual(rejection, .unverifiedContents)
        XCTAssertEqual(try String(contentsOf: sentinel), "retained")
    }

    private final class ActivitySwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        func isBusy() -> Bool {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return calls > 1
        }
    }

    func testActivityStartingAfterSizingReportsBusyRatherThanChanged() throws {
        let root = try cache()
        let activity = ActivitySwitch()
        let result = try cleaner().clean(item(root), isInUse: { _ in activity.isBusy() })
        XCTAssertEqual(result.reasonKey, "dev.uv.busy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sdists-v9/payload").path))
    }

    private func project(_ build: URL) -> ProjectArtifact {
        ProjectArtifact(url: build, projectName: "fixture", projectPath: build.deletingLastPathComponent().path,
                        kind: .swiftpm, size: 1, projectModified: nil)
    }

    func testMalformedConfigCannotBypassLockedCacheInsideProjectBuild() async throws {
        let build = home.appendingPathComponent("project/.build")
        let root = try cache(at: build.appendingPathComponent("custom-uv"))
        // No .git sentinel may mask the uv protection under test.
        try FileManager.default.removeItem(at: root.appendingPathComponent("sdists-v9/.git"))
        let config = temp.appendingPathComponent("uv.toml")
        environment["UV_CONFIG_FILE"] = config.path
        try "cache-dir = '\(root.path)'\n".write(to: config, atomically: true, encoding: .utf8)
        let service = try cleaner()
        let manager = DevCleanManager(isInUse: { _ in false }, uvIsInUse: { false }, uvCleaner: service)
        _ = await manager.scanUvCache()
        let descriptor = open(root.appendingPathComponent(".lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_SH | LOCK_NB), 0)
        try "invalid toml = [".write(to: config, atomically: true, encoding: .utf8)
        for candidate in [manager, DevCleanManager(isInUse: { _ in false }, uvIsInUse: { false }, uvCleaner: service)] {
            let result = await candidate.cleanProjects([project(build)])
            XCTAssertEqual(result.failed, 1)
            XCTAssertTrue(result.cleaned.isEmpty)
            let report = await candidate.lastRemovalResult
            XCTAssertEqual(report?.obstacles[build], .changedSinceScan)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sdists-v9/payload").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".lock").path))
    }

    func testMovedConfigurationRetainsPreviouslyDiscoveredRootWithDamagedMarkers() async throws {
        let build = home.appendingPathComponent("project/.build")
        let old = try cache(at: build.appendingPathComponent("old-cache"))
        let config = temp.appendingPathComponent("uv.toml")
        environment["UV_CONFIG_FILE"] = config.path
        try "cache-dir = '\(old.path)'\n".write(to: config, atomically: true, encoding: .utf8)
        let manager = DevCleanManager(isInUse: { _ in false }, uvIsInUse: { false }, uvCleaner: try cleaner())
        _ = await manager.scanUvCache()
        let new = try cache(at: temp.appendingPathComponent("new-cache"))
        try "cache-dir = '\(new.path)'\n".write(to: config, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: old.appendingPathComponent("CACHEDIR.TAG"))
        try FileManager.default.removeItem(at: old.appendingPathComponent("sdists-v9/.git"))
        let result = await manager.cleanProjects([project(build)])
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("sdists-v9/payload").path))
    }

    func testMissingUvAllowsOrdinaryBuildButProtectsUnconfiguredNestedCache() async throws {
        let ordinary = home.appendingPathComponent("plain-project/.build")
        try FileManager.default.createDirectory(at: ordinary, withIntermediateDirectories: true)
        try Data("build".utf8).write(to: ordinary.appendingPathComponent("output"))
        let nestedBuild = home.appendingPathComponent("other-project/.build")
        let nested = try cache(at: nestedBuild.appendingPathComponent("uv-custom"))
        try FileManager.default.removeItem(at: nested.appendingPathComponent("sdists-v9/.git"))
        let service = UvCacheCleaner(home: home, environment: environment, discoverExecutable: false)
        let manager = DevCleanManager(isInUse: { _ in false }, uvIsInUse: { false }, uvCleaner: service)
        let result = await manager.cleanProjects([project(ordinary), project(nestedBuild)])
        XCTAssertEqual(result.cleaned.count, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ordinary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.appendingPathComponent("sdists-v9/payload").path))
        XCTAssertTrue(UvCacheCleaner.containsCacheOrUnverified(nested.appendingPathComponent("sdists-v9")))
    }

    func testUserTOMLAndExplicitConfigAreResolvedByUv() throws {
        let config = URL(fileURLWithPath: environment["XDG_CONFIG_HOME"]!).appendingPathComponent("uv/uv.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        let root = temp.appendingPathComponent("configured cache")
        try "cache-dir = '\(root.path)'\n".write(to: config, atomically: true, encoding: .utf8)
        let userConfigService = try cleaner()
        XCTAssertEqual(userConfigService.location().url.path, root.path)
        let explicit = temp.appendingPathComponent("explicit.toml")
        let other = temp.appendingPathComponent("other cache")
        try "cache-dir = '\(other.path)'\n".write(to: explicit, atomically: true, encoding: .utf8)
        environment["UV_CONFIG_FILE"] = explicit.path
        let explicitConfigService = try cleaner()
        XCTAssertEqual(explicitConfigService.location().url.path, other.path)
    }

    func testUnavailableExecutableStillShowsDefaultCacheWithReason() async throws {
        let root = try cache()
        let service = UvCacheCleaner(home: home, environment: environment, discoverExecutable: false)
        let manager = DevCleanManager(isInUse: { _ in false }, uvIsInUse: { false }, uvCleaner: service)
        let found = await manager.scanUvCache()
        XCTAssertEqual(found?.url.path, root.path)
        XCTAssertEqual(found?.cleanupUnavailableReasonKey, "dev.uv.unavailable")
        let result = service.clean(item(root), isInUse: { _ in false })
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sdists-v9/payload").path))
    }

    func testInvalidConfigFailsClosedRatherThanCleaningDefault() throws {
        let root = try cache()
        environment["UV_CONFIG_FILE"] = temp.appendingPathComponent("missing.toml").path
        let result = try cleaner().clean(item(root), isInUse: { _ in false })
        XCTAssertEqual(result.reasonKey, "dev.uv.configuration")
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testRealUvCleanIsPinnedAndAccountsForActualRemainder() async throws {
        let root = try cache(at: temp.appendingPathComponent("cache with spaces ' ; $()"))
        environment["UV_CACHE_DIR"] = root.path
        let untouched = try cache(at: home.appendingPathComponent(".cache/uv"))
        let service = try cleaner()
        let original = item(root)
        let reclaimable = try FileManager.default.allocatedSize(of: root, reclaiming: true)
        let manager = DevCleanManager(isInUse: { _ in false }, uvIsInUse: { false }, uvCleaner: service)
        let result = await manager.clean(items: [original])
        XCTAssertEqual(result.cleaned, [original.id])
        XCTAssertEqual(result.failed, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sdists-v9/payload").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouched.appendingPathComponent("sdists-v9/payload").path))
        let remainder = Scanner.shared.calculateSizes(at: [root])[root.path] ?? 0
        XCTAssertEqual(result.freedBytes, min(original.size - remainder, reclaimable))
        let refreshed = await manager.scanUvCache()
        XCTAssertEqual(refreshed?.size ?? 0, remainder)
    }

    func testHeldSharedLockRefusesCleanupAndReportsNoFreedBytes() throws {
        let root = try cache()
        let descriptor = open(root.appendingPathComponent(".lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_SH | LOCK_NB), 0)
        let start = Date()
        let result = try cleaner().clean(item(root), isInUse: { _ in false })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.reasonKey, "dev.uv.busy")
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sdists-v9/payload").path))
    }

    func testHardLinkedOutsideFileIsRetainedAndNotCreditedAsFreed() throws {
        let root = try cache()
        let payload = root.appendingPathComponent("sdists-v9/payload")
        let retained = temp.appendingPathComponent("installed-package")
        try FileManager.default.linkItem(at: payload, to: retained)
        let original = item(root)
        let estimate = try FileManager.default.allocatedSize(of: root, reclaiming: true)
        let result = try cleaner().clean(original, isInUse: { _ in false })
        XCTAssertTrue(result.succeeded)
        XCTAssertLessThanOrEqual(result.freedBytes, estimate)
        XCTAssertLessThan(result.freedBytes, 131_072)
        XCTAssertEqual(try Data(contentsOf: retained).count, 131_072)
    }

    func testUvUnlinksBucketSymlinkWithoutTouchingItsTarget() throws {
        let root = try cache()
        let outside = temp.appendingPathComponent("outside/Photos.photoslibrary")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = outside.appendingPathComponent("keep")
        try Data("retained".utf8).write(to: kept)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("archive-v0"),
                                                   withDestinationURL: outside)
        let result = try cleaner().clean(item(root), isInUse: { _ in false })
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(try String(contentsOf: kept), "retained")
    }

    func testWatchdogBoundsLockWait() throws {
        let root = try cache()
        let descriptor = open(root.appendingPathComponent(".lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_SH | LOCK_NB), 0)
        let start = Date()
        let result = try cleaner(timeout: 0.25).clean(item(root), isInUse: { _ in false })
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.reasonKey, "dev.uv.busy")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sdists-v9/payload").path))
    }

    func testActivityGuardRefusesBeforeInvokingClean() throws {
        let service = try cleaner()
        let root = try cache()
        XCTAssertEqual(service.clean(item(root), isInUse: { _ in true }).reasonKey, "dev.uv.busy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sdists-v9/payload").path))
    }

    func testReplacedDirectoryAndSymlinkAreRejected() throws {
        let service = try cleaner()
        let root = try cache()
        let original = item(root)
        try FileManager.default.moveItem(at: root, to: temp.appendingPathComponent("original"))
        try cache(at: root)
        XCTAssertEqual(service.clean(original, isInUse: { _ in false }).reasonKey, "dev.uv.changed")
        let link = temp.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertFalse(UvCacheCleaner.validCache(link, identity: RemovalIdentity(at: link)))
    }

    func testChangedConfigurationAndUnknownTopLevelDataAreRejected() throws {
        let root = try cache()
        let original = item(root)
        environment["UV_CACHE_DIR"] = try cache(at: temp.appendingPathComponent("different")).path
        let redirectedService = try cleaner()
        XCTAssertEqual(redirectedService.clean(original, isInUse: { _ in false }).reasonKey, "dev.uv.changed")
        environment.removeValue(forKey: "UV_CACHE_DIR")
        try Data("keep".utf8).write(to: root.appendingPathComponent("personal.txt"))
        let defaultService = try cleaner()
        XCTAssertEqual(defaultService.clean(original, isInUse: { _ in false }).reasonKey, "dev.uv.changed")
    }

    func testGenericDeleteCannotBypassUvThroughAnAncestorOrChild() async throws {
        let root = try cache()
        let manager = DevCleanManager(isInUse: { _ in false }, uvIsInUse: { false }, uvCleaner: try cleaner())
        for url in [root.deletingLastPathComponent(), root.appendingPathComponent("sdists-v9")] {
            let forged = DevJunkItem(definitionID: "npm", url: url, size: 100, safe: true)
            let result = await manager.clean(items: [forged])
            XCTAssertEqual(result.failed, 1)
            XCTAssertEqual(result.freedBytes, 0)
            let report = await manager.lastRemovalResult
            XCTAssertEqual(report?.failed, [url])
            XCTAssertEqual(report?.obstacles[url], .inUse)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sdists-v9/payload").path))
    }

    func testMixedUvAndOrdinaryActivityFailuresRetainIndependentReports() async throws {
        let root = try cache()
        let artifact = temp.appendingPathComponent("build-output")
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
        let manager = DevCleanManager(isInUse: { _ in true }, uvIsInUse: { true }, uvCleaner: try cleaner())
        let ordinary = DevJunkItem(definitionID: "npm", url: artifact, size: 1, safe: true)
        let result = await manager.clean(items: [ordinary, item(root)])
        XCTAssertEqual(result.failed, 2)
        let report = await manager.lastRemovalResult
        XCTAssertEqual(report?.failed, [artifact])
        XCTAssertEqual(report?.obstacles[artifact], .inUse)
        let uvReason = await manager.uvFailureKey
        XCTAssertEqual(uvReason, "dev.uv.busy")
        let project = ProjectArtifact(url: artifact, projectName: "fixture", projectPath: temp.path,
                                      kind: .swiftpm, size: 1, projectModified: nil)
        let projects = await manager.cleanProjects([project])
        XCTAssertEqual(projects.failed, 1)
        let projectReport = await manager.lastRemovalResult
        XCTAssertEqual(projectReport?.failed, [artifact])
        XCTAssertEqual(projectReport?.obstacles[artifact], .inUse)
    }

    func testCleanArgumentsHaveNoForceAndIgnoreInheritedRedirection() throws {
        let path = temp.appendingPathComponent("cache name; touch sentinel")
        let arguments = UvCacheCleaner.cleanArguments(for: path)
        XCTAssertEqual(arguments, ["cache", "clean", "--cache-dir", path.path, "--offline", "--no-config",
                                   "--no-progress", "--color", "never"])
        environment["UV_NO_CACHE"] = "1"
        environment["UV_CONFIG_FILE"] = "/not-used"
        environment["UV_WORKING_DIR"] = "/not-used"
        let env = UvCacheCleaner(home: home, environment: environment, discoverExecutable: false).cleanEnvironment
        XCTAssertEqual(env.filter { $0.key.hasPrefix("UV_") }, ["UV_LOCK_TIMEOUT": "2"])
    }

    func testRealCacheReadOnlyDiscoveryWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["CAC_UV_READONLY_REAL"] == "1" else {
            throw XCTSkip("Opt-in read-only probe; no real cache cleanup")
        }
        let found = await DevCleanManager.shared.scanUvCache()
        let row = try XCTUnwrap(found)
        XCTAssertEqual(row.definitionID, "uv-cache")
        XCTAssertGreaterThan(row.size, 0)
        XCTAssertNil(row.cleanupUnavailableReasonKey)
        print("Read-only uv discovery: \(row.url.path), \(row.size) allocated bytes")
    }
}
