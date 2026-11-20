import XCTest
@testable import CleanAppCacheLib

/// The Privacy clear deletes history and site data for good, so what it
/// removes, what it keeps and when it refuses are checked on a fake browser
/// profile. `com.apple.finder` stands in for a browser that is running: it is
/// always live, and every file involved is in a scratch directory.
final class PrivacyClearTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private let fakeBrowser = "com.cacfixture.browser"
    private let runningBrowser = "com.apple.finder"

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("privacy-clear-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func file(_ name: String, bytes: Int = 4096) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        return url
    }

    private func entry(id: String? = nil, isRunning: Bool = false, history: [URL] = [],
                       databases: [URL] = [], siteData: [URL] = []) -> BrowserEntry {
        BrowserEntry(id: id ?? fakeBrowser, name: "Fixture", icon: "globe",
                     historyFiles: history, historyDatabases: databases, siteDataFiles: siteData,
                     totalSize: 4096 * UInt64(history.count + siteData.count),
                     isRunning: isRunning, isInstalled: true)
    }

    func testClearDeletesHistoryAndSiteDataButNotTheFilesNoListNames() async throws {
        let history = try file("Default/History")
        let cookies = try file("Default/Cookies")
        let passwords = try file("Default/Login Data")
        let bookmarks = try file("Default/Bookmarks")
        let target = entry(history: [history], siteData: [cookies])

        let result = await PrivacyManager.shared.clearHistory(for: target)

        XCTAssertFalse(fm.fileExists(atPath: history.path))
        XCTAssertFalse(fm.fileExists(atPath: cookies.path))
        XCTAssertTrue(fm.fileExists(atPath: passwords.path), "passwords are never on a list")
        XCTAssertTrue(fm.fileExists(atPath: bookmarks.path), "bookmarks are never on a list")
        XCTAssertEqual(result.cleared, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertGreaterThan(result.freed, 0)
    }

    func testRunningFlagRefusesTheWholeClearAndDeletesNothing() async throws {
        let history = try file("Default/History")
        let cookies = try file("Default/Cookies")
        let target = entry(isRunning: true, history: [history], siteData: [cookies])

        let result = await PrivacyManager.shared.clearHistory(for: target)

        XCTAssertEqual(result.cleared, 0)
        XCTAssertEqual(result.failed, 2)
        XCTAssertEqual(result.freed, 0)
        XCTAssertTrue(fm.fileExists(atPath: history.path))
        XCTAssertTrue(fm.fileExists(atPath: cookies.path))
    }

    func testLiveProcessCheckBeatsAStaleNotRunningFlag() async throws {
        let history = try file("Default/History")
        let cookies = try file("Default/Cookies")
        XCTAssertNotNil(PrivacyManager.blockingProcess(for: runningBrowser), "Finder must be running")
        let target = entry(id: runningBrowser, isRunning: false, history: [history], siteData: [cookies])

        let result = await PrivacyManager.shared.clearHistory(for: target)

        XCTAssertEqual(result.cleared, 0)
        XCTAssertEqual(result.failed, 2)
        XCTAssertTrue(fm.fileExists(atPath: history.path), "the browser may have started while the dialog was up")
        XCTAssertTrue(fm.fileExists(atPath: cookies.path))
    }

    func testProtectedLocationIsBlockedAndCountsAsFailed() async throws {
        let history = try file("Default/History")
        let protected = try file("Profile/.git/config")
        let target = entry(history: [history], siteData: [protected])

        let result = await PrivacyManager.shared.clearHistory(for: target)

        XCTAssertTrue(fm.fileExists(atPath: protected.path))
        XCTAssertEqual(result.failed, 1)
        XCTAssertFalse(fm.fileExists(atPath: history.path), "the unprotected path is still cleared")
        XCTAssertEqual(result.cleared, 1)
    }

    func testUnreadableHistoryDatabaseStaysAndIsReportedFailed() async throws {
        let database = try file("Profiles/abc/places.sqlite", bytes: 512)
        let cookies = try file("Profiles/abc/cookies.sqlite")
        let target = entry(databases: [database], siteData: [cookies])

        let result = await PrivacyManager.shared.clearHistory(for: target)

        XCTAssertFalse(fm.fileExists(atPath: cookies.path))
        XCTAssertTrue(fm.fileExists(atPath: database.path), "the bookmarks' database is never deleted")
        XCTAssertEqual(try Data(contentsOf: database), Data(repeating: 7, count: 512))
        XCTAssertEqual(result.cleared, 1)
        XCTAssertEqual(result.failed, 1)
    }

    func testMissingFilesAreNeitherClearedNorFailed() async throws {
        let present = try file("Default/History")
        let gone = root.appendingPathComponent("Default/Cookies")
        let target = entry(history: [present], siteData: [gone])

        let result = await PrivacyManager.shared.clearHistory(for: target)

        XCTAssertEqual(result.cleared, 1)
        XCTAssertEqual(result.failed, 0)
    }
}

@MainActor
final class PrivacyViewModelClearTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("privacy-vm-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func entry(id: String, isRunning: Bool = false) throws -> (BrowserEntry, URL) {
        let url = root.appendingPathComponent("History-\(UUID().uuidString)")
        try Data(repeating: 7, count: 4096).write(to: url)
        return (BrowserEntry(id: id, name: "Fixture", icon: "globe", historyFiles: [url],
                             historyDatabases: [], siteDataFiles: [], totalSize: 4096,
                             isRunning: isRunning, isInstalled: true), url)
    }

    func testBatchClearsBothBrowsersBeforeOneRescan() async throws {
        let (first, firstURL) = try entry(id: "com.cacfixture.first")
        let (second, secondURL) = try entry(id: "com.cacfixture.second")
        let before = Set(ToastCenter.shared.toasts.map(\.id))
        let probe = ScanProbe()
        let vm = PrivacyViewModel(scan: {
            XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
            await probe.recordScan()
            return []
        }, invalidateStorage: { urls in
            XCTAssertEqual(Set(urls), Set([firstURL, secondURL]))
        }, isRunning: { _ in false }, requestQuit: { _ in XCTFail("No browser should be asked to quit") })

        let accepted = await vm.clearHistory(for: [first, second], authorizedToQuit: [])

        XCTAssertTrue(accepted)
        let scans = await probe.scans
        XCTAssertEqual(scans, 1)
        XCTAssertFalse(vm.isClearing)
        XCTAssertFalse(vm.isScanning)
        XCTAssertEqual(ToastCenter.shared.toasts.filter { !before.contains($0.id) }.map(\.style),
                       [.success, .success])
    }

    func testRunningBrowserNeedsItsOwnQuitAuthorization() async throws {
        let (newlyRunning, runningURL) = try entry(id: "com.cacfixture.started")
        let (authorized, authorizedURL) = try entry(id: "com.cacfixture.authorized", isRunning: true)
        let before = Set(ToastCenter.shared.toasts.map(\.id))
        var running = Set([newlyRunning.id, authorized.id])
        var quitRequests: [String] = []
        let vm = PrivacyViewModel(scan: { [] }, invalidateStorage: { _ in },
                                  isRunning: { running.contains($0) }, requestQuit: {
            quitRequests.append($0)
            running.remove($0)
        })

        await vm.clearHistory(for: [newlyRunning, authorized], authorizedToQuit: [authorized.id])

        XCTAssertEqual(quitRequests, [authorized.id])
        XCTAssertTrue(fm.fileExists(atPath: runningURL.path))
        XCTAssertFalse(fm.fileExists(atPath: authorizedURL.path))
        let feedback = ToastCenter.shared.toasts.filter { !before.contains($0.id) }
        XCTAssertEqual(feedback.map(\.style), [.error, .success])
        XCTAssertEqual(feedback.first?.title, Localizer.shared.f("privacy.startedFmt", newlyRunning.name))
    }

    func testScanningViewModelRejectsClear() async throws {
        let (target, url) = try entry(id: "com.cacfixture.browser")
        let vm = PrivacyViewModel(scan: { [] }, invalidateStorage: { _ in },
                                  isRunning: { _ in false }, requestQuit: { _ in XCTFail() })
        vm.isScanning = true

        let accepted = await vm.clearHistory(for: [target], authorizedToQuit: [])

        XCTAssertFalse(accepted)
        XCTAssertTrue(fm.fileExists(atPath: url.path))
    }

    private actor ScanProbe {
        private(set) var scans = 0
        func recordScan() { scans += 1 }
    }
}
