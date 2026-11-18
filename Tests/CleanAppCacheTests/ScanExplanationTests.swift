import XCTest
@testable import CleanAppCacheLib

private struct EmptyExplanationScanner: ScannerProtocol {
    func performFullScan(progressHandler: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        ScanResult(items: [], totalSize: 0, duration: 0, categorySizes: [:])
    }
    func cancel() async {}
}

final class ScanExplanationTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("scan-explanations-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: root)
    }

    private func file(_ path: String, old: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: 4096).write(to: url)
        if old { try age(url) }
        return url
    }

    private func age(_ url: URL) throws {
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: url.path)
    }

    private func scan(_ source: CleanAppCacheLib.Scanner.CategorySource, category: ScanCategory = .userCache,
                      inUse: @Sendable (URL) -> Bool = { _ in false }) async -> CleanAppCacheLib.Scanner.CategoryResult {
        await Scanner.shared.scanCategory(category: category, source: source, inUse: inUse)
    }

    func testGoogleChildrenAreClassifiedWithoutWholeVendorFolder() async throws {
        let chrome = try file("Google/Chrome/cache").deletingLastPathComponent()
        let studio = try file("Google/AndroidStudio2026.1/cache").deletingLastPathComponent()
        let other = try file("Google/Firefox/cache").deletingLastPathComponent()
        for url in [chrome, studio, other] { try age(url) }
        let user = await scan(Scanner.userCacheSource(root.path))
        let browser = await scan(Scanner.browserCacheSource(root.path), category: .browserJunk)
        XCTAssertEqual(Set(user.items.map(\.url)), Set([studio, other]))
        XCTAssertEqual(browser.items.map(\.url), [chrome])
        XCTAssertTrue(user.items.allSatisfy { $0.category == .userCache })
        XCTAssertFalse((user.items + browser.items).contains { $0.url.lastPathComponent == "Google" })
    }

    func testChromeAndAndroidStudioHaveDifferentOwners() {
        let home = URL(fileURLWithPath: "/Users/synthetic")
        func owners(_ path: String) -> Set<String> {
            AppActivityGuard.cacheOwners(for: home.appendingPathComponent(path), home: home)
        }
        XCTAssertEqual(owners("Library/Caches/Google/Chrome/Profile 1"), ["com.google.chrome"])
        XCTAssertEqual(owners("Library/Caches/Google/AndroidStudio2026.1"), ["com.google.android.studio"])
        XCTAssertEqual(owners("Library/Logs/Google/AndroidStudioPreview2026.2"), ["com.google.android.studio"])
        XCTAssertEqual(owners("Library/Caches/Google/Chrome Canary"), ["com.google.chrome.canary"])
        XCTAssertEqual(owners("Library/Caches/Google"), ["com.google"])
        XCTAssertTrue(owners("Library/CachesExtra/Google/Chrome").isEmpty)
    }

    func testActiveIDEIsSkippedIndependentlyFromClosedChrome() async throws {
        let chrome = try file("Google/Chrome/cache").deletingLastPathComponent()
        let studio = try file("Google/AndroidStudio2026.1/cache").deletingLastPathComponent()
        try age(chrome); try age(studio)
        let user = await scan(Scanner.userCacheSource(root.path), inUse: { $0 == studio })
        let browser = await scan(Scanner.browserCacheSource(root.path), category: .browserJunk, inUse: { $0 == studio })
        XCTAssertTrue(user.items.isEmpty)
        XCTAssertEqual(user.skipped.paths.first?.path, studio.path)
        XCTAssertEqual(user.skipped.counts[.inUse], 1)
        XCTAssertEqual(browser.items.map(\.url), [chrome])
    }

    func testRecentAndInUseReasonsDoNotBecomeCleanable() async throws {
        let old = try file("old")
        let live = try file("live")
        let recent = try file("recent", old: false)
        let result = await scan(.children(roots: [.init(root.path)], excluding: []), inUse: { $0 == live })
        XCTAssertEqual(result.items.map(\.url), [old])
        XCTAssertEqual(result.skipped.counts[.inUse], 1)
        XCTAssertEqual(result.skipped.counts[.recent], 1)
        XCTAssertEqual(Set(result.skipped.paths.map(\.path)), Set([live.path, recent.path]))
    }

    func testEnumerationFailureIsNotAnEmptySuccessfulScan() async throws {
        let notDirectory = try file("not-a-directory")
        let result = await scan(.children(roots: [.init(notDirectory.path)], excluding: []))
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.counts[.unreadable], 1)
        XCTAssertEqual(result.skipped.paths.first?.path, notDirectory.path)
        XCTAssertTrue(result.skipped.needsNotice)
        let installers = await scan(.filesMatching(directory: notDirectory.path, extensions: ["dmg"]), category: .installers)
        XCTAssertEqual(installers.skipped.counts[.unreadable], 1)
    }

    func testMissingOptionalRootIsNotAnAccessFailure() async {
        let result = await scan(.children(roots: [.init(root.appendingPathComponent("missing").path)], excluding: []))
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.totalCount, 0)
    }

    func testFailedMeasurementDoesNotCountAsZeroOrCleanable() async throws {
        let url = try file("unmeasured")
        let result = await Scanner.shared.scanCategory(category: .userCache,
            source: .directories([url.path]), inUse: { _ in false }, sizeProvider: { _ in [:] })
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.counts[.unreadable], 1)
        XCTAssertEqual(result.skipped.paths.first?.path, url.path)
    }

    func testSafetyAndLinksAreExplainedForInstallersToo() async throws {
        let protected = try file("backup.pvm/private").deletingLastPathComponent()
        let link = root.appendingPathComponent("linked.dmg")
        try fm.createSymbolicLink(at: link, withDestinationURL: protected)
        XCTAssertEqual(Scanner.skipReason(protected, minAge: 0, inUse: { _ in false }), .safetyProtected)
        let result = await scan(.filesMatching(directory: root.path, extensions: ["dmg"]), category: .installers)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.counts[.symbolicLink], 1)
    }

    func testUnverifiableRecencyHasItsOwnReason() throws {
        let dir = try file("tree/a").deletingLastPathComponent()
        _ = try file("tree/b")
        try age(dir)
        XCTAssertEqual(Scanner.recentSkipReason(dir, within: 3600, limit: 1), .verificationLimit)
        XCTAssertEqual(Scanner.recentSkipReason(root.appendingPathComponent("missing"), within: 3600), .unreadable)
        XCTAssertTrue(Scanner.touchedRecently(dir, within: 3600, limit: 1))
    }

    func testUnreadableRootAndDescendantAreReported() async throws {
        let dir = try file("restricted/a").deletingLastPathComponent()
        try age(dir)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        let result = await scan(.children(roots: [.init(dir.path)], excluding: []))
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.counts[.unreadable], 1)
        XCTAssertEqual(Scanner.recentSkipReason(dir, within: 3600), .unreadable)
    }

    func testReportingIsBoundedButCountsRemainComplete() {
        var a = ScanSkipSummary()
        var b = ScanSkipSummary()
        for i in 0..<500 {
            a.record(root.appendingPathComponent("a\(i)"), category: .userCache, reason: .inUse)
            b.record(root.appendingPathComponent("b\(i)"), reason: .unreadable)
        }
        a.merge(b)
        XCTAssertEqual(a.paths.count, ScanSkipSummary.detailLimit)
        XCTAssertEqual(a.totalCount, 1000)
        XCTAssertEqual(a.omittedCount, 800)
        XCTAssertEqual(a.counts[.unreadable], 500)
    }

    func testCacheRoundTripPreservesCountsWithoutPrivatePaths() throws {
        var summary = ScanSkipSummary()
        summary.record(root.appendingPathComponent("cache"), category: .userCache, reason: .inUse)
        summary.record(root.appendingPathComponent("private-trash-name"), category: .trash, reason: .recent)
        summary.record(root.appendingPathComponent("private-download-name"), category: .installers, reason: .unreadable)
        let result = ScanResult(items: [], totalSize: 0, duration: 1, categorySizes: [:], skipped: summary)
        let data = try JSONEncoder().encode(ScanResult.Cached(from: result))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("private-trash-name"))
        XCTAssertFalse(text.contains("private-download-name"))
        let restored = try JSONDecoder().decode(ScanResult.Cached.self, from: data).toScanResult()
        XCTAssertEqual(restored.skipped.totalCount, 3)
        XCTAssertEqual(restored.skipped.paths.count, 1)
        XCTAssertEqual(restored.totalSize, 0)
        XCTAssertTrue(restored.skipped.explanationsAvailable)
    }

    func testLegacyCacheDecodesAndDropsUnsafeGoogleAggregate() throws {
        let google = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Google")
        let result = ScanResult(items: [CleanableItem(url: google, category: .browserJunk, size: 1024, itemCount: 0)],
                                totalSize: 1024, duration: 1, categorySizes: [.browserJunk: 1024])
        let encoded = try JSONEncoder().encode(ScanResult.Cached(from: result))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "skipped")
        let data = try JSONSerialization.data(withJSONObject: object)
        let restored = try JSONDecoder().decode(ScanResult.Cached.self, from: data).toScanResult()
        XCTAssertTrue(restored.items.isEmpty)
        XCTAssertEqual(restored.totalSize, 0)
        XCTAssertEqual(restored.size(for: .browserJunk), 0)
        XCTAssertFalse(restored.skipped.explanationsAvailable)
        XCTAssertTrue(restored.skipped.needsNotice)
    }

    func testCancellationDiscardsPartialItemsAndExplanations() async throws {
        let url = try file("old")
        let result = await Task {
            await Scanner.shared.scanCategory(category: .userCache,
                source: .directories([url.path]), inUse: { _ in false }, sizeProvider: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return [url.path: 4096]
                })
        }.value
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.totalCount, 0)
        let next = await scan(.directories([url.path]))
        XCTAssertEqual(next.items.map(\.url), [url])
    }

    func testCancellingCategoryStopsItsRunningSizeProbe() async throws {
        let url = try file("old-cache")
        let marker = root.appendingPathComponent("du-started")
        let command = root.appendingPathComponent("fake-du")
        try """
        #!/bin/sh
        : > "\(marker.path)"
        exec /bin/sleep 5
        """.write(to: command, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)

        let scanner = CleanAppCacheLib.Scanner(duExecutable: command)
        let work = Task {
            await scanner.scanCategory(category: .userCache, source: .directories([url.path]), inUse: { _ in false })
        }
        for _ in 0..<400 {
            if fm.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let started = fm.fileExists(atPath: marker.path)
        let now = DispatchTime.now().uptimeNanoseconds
        work.cancel()
        let result = await work.value
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - now) / 1_000_000_000
        XCTAssertTrue(started, "the test must cancel after the subprocess launches")
        XCTAssertLessThan(elapsed, 2, "cancellation must return before the subprocess's natural exit")
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.totalCount, 0)
    }

    func testTrashCandidateReplacedDuringSizingIsSkipped() async throws {
        let url = try file("trash/trashed-cache")
        let replacement = try file("replacement")
        let result = await Scanner.shared.scanCategory(category: .trash,
            source: .children(roots: [.init(url.deletingLastPathComponent().path)], excluding: []),
            inUse: { _ in false }, sizeProvider: { _ in
                XCTAssertEqual(rename(replacement.path, url.path), 0)
                return [url.path: 4096]
            })
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.skipped.counts[.unreadable], 1)
    }

    @MainActor
    func testSelectionNeverIncludesSkippedPaths() {
        var summary = ScanSkipSummary()
        summary.record(root.appendingPathComponent("busy"), category: .userCache, reason: .inUse)
        let item = CleanableItem(url: root.appendingPathComponent("available"), category: .userCache, size: 4096, itemCount: 1)
        let vm = DashboardViewModel(loadCache: false)
        vm.scanResult = ScanResult(items: [item], totalSize: 4096, duration: 0, categorySizes: [.userCache: 4096], skipped: summary)
        vm.selectAll()
        XCTAssertEqual(vm.selectedItems, [item.id])
        XCTAssertEqual(vm.selectedSize, 4096)
    }
    @MainActor
    func testCleanupRefusalRemainsVisibleAfterAutomaticRescan() async throws {
        let url = try file("active-cache", old: false)
        let item = CleanableItem(url: url, category: .userCache, size: 4096, itemCount: 1)
        let vm = DashboardViewModel(scanner: EmptyExplanationScanner(), loadCache: false,
                                    cacheDirectory: root.appendingPathComponent("state"))
        vm.scanResult = ScanResult(items: [item], totalSize: 4096, duration: 0,
                                   categorySizes: [.userCache: 4096])
        vm.selectAll()
        let ran = await vm.cleanSelectedItems()
        XCTAssertTrue(ran)
        for _ in 0..<100 where vm.isScanning { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(vm.isScanning)
        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertEqual(vm.cleanupSkipped.counts[.recent], 1)
        XCTAssertEqual(vm.cleanupSkipped.paths.first?.path, url.path)
        XCTAssertTrue(vm.cleanupSkipped.needsNotice)
        XCTAssertEqual(vm.selectedSize, 0)
        XCTAssertNil(vm.cleanupOutcome)
    }

    @MainActor
    func testCleanupDoesNotCountAnItemRemovedAfterScanning() async throws {
        let url = try file("removed-after-scan")
        let item = CleanableItem(url: url, category: .userCache, size: 4096, itemCount: 1)
        let vm = DashboardViewModel(scanner: EmptyExplanationScanner(), loadCache: false,
                                    cacheDirectory: root.appendingPathComponent("state"))
        vm.scanResult = ScanResult(items: [item], totalSize: 4096, duration: 0,
                                   categorySizes: [.userCache: 4096])
        vm.selectAll()
        try fm.removeItem(at: url)

        let ran = await vm.cleanSelectedItems()
        XCTAssertTrue(ran)
        let report = try XCTUnwrap(vm.lastCleanReport)
        XCTAssertEqual(report.cleanedCount, 0)
        XCTAssertEqual(report.alreadyGoneCount, 1)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertNil(report.historyRecord)
        XCTAssertFalse(vm.cleanupSkipped.needsNotice)
        for _ in 0..<100 where vm.isScanning { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(vm.isScanning)
    }

    @MainActor
    func testCleanupReportsBlockedAndMissingItemsFromFinderRetry() async throws {
        let blocked = try file("blocked-during-retry")
        let gone = try file("removed-during-retry")
        let urls = [blocked, gone]
        let items = urls.map { CleanableItem(url: $0, category: .userCache, size: 4096, itemCount: 1) }
        let vm = DashboardViewModel(scanner: EmptyExplanationScanner(), loadCache: false,
                                    cacheDirectory: root.appendingPathComponent("state"))
        vm.scanResult = ScanResult(items: items, totalSize: 8192, duration: 0,
                                   categorySizes: [.userCache: 8192])
        vm.selectAll()

        let ran = await vm.cleanSelectedItems(trash: { url in
            .init(trashed: [], failed: [url], obstacles: [url: .needsAdmin], freedBytes: 0)
        }, retryTrash: { candidates in
            XCTAssertEqual(candidates, urls)
            return .init(trashed: [], failed: [], blocked: [blocked], alreadyGone: [gone], freedBytes: 0)
        })

        XCTAssertTrue(ran)
        let report = try XCTUnwrap(vm.lastCleanReport)
        XCTAssertEqual(report.cleanedCount, 0)
        XCTAssertEqual(report.alreadyGoneCount, 1)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertNil(report.historyRecord)
        XCTAssertEqual(vm.cleanupSkipped.counts[.safetyProtected], 1)
        XCTAssertEqual(vm.cleanupSkipped.paths.first?.path, blocked.path)
        XCTAssertEqual(vm.cleanupSkipped.paths.first?.category, .userCache)
        XCTAssertTrue(fm.fileExists(atPath: blocked.path))
        for _ in 0..<100 where vm.isScanning { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(vm.isScanning)
    }

    func testAlreadyCancelledFullScanThrowsInsteadOfReturningEmptySuccess() async {
        let work = Task { try await Scanner.shared.performFullScan(progressHandler: { _ in }) }
        work.cancel()
        do {
            _ = try await work.value
            XCTFail("Cancellation must not publish a partial or empty completed scan")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

}
