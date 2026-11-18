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
        let home = fm.homeDirectoryForCurrentUser
        let target = entry(history: [history], siteData: [home])

        let result = await PrivacyManager.shared.clearHistory(for: target)

        XCTAssertTrue(fm.fileExists(atPath: home.path))
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

    func testClearRemovesFilesAndShowsASuccessToast() async throws {
        let (target, url) = try entry(id: "com.cacfixture.browser")
        let before = ToastCenter.shared.toasts.count
        let vm = PrivacyViewModel()

        await vm.clearHistory(for: target)

        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertNil(vm.clearingID)
        XCTAssertEqual(ToastCenter.shared.toasts.count, before + 1)
        XCTAssertEqual(ToastCenter.shared.toasts.last?.style, .success)
    }

    func testRunningBrowserFlagStartsNothing() async throws {
        let (target, url) = try entry(id: "com.cacfixture.browser", isRunning: true)
        let before = ToastCenter.shared.toasts.count
        let vm = PrivacyViewModel()

        await vm.clearHistory(for: target)

        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertEqual(ToastCenter.shared.toasts.count, before)
    }

    func testBusyViewModelStartsNothing() async throws {
        let (target, url) = try entry(id: "com.cacfixture.browser")
        let vm = PrivacyViewModel()

        vm.isScanning = true
        await vm.clearHistory(for: target)
        vm.isScanning = false
        vm.clearingID = "another"
        await vm.clearHistory(for: target)

        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertEqual(vm.clearingID, "another")
    }

    func testBrowserThatStartedDuringTheDialogGetsAnErrorToastAndKeepsItsFiles() async throws {
        let (target, url) = try entry(id: "com.apple.finder", isRunning: false)
        let before = ToastCenter.shared.toasts.count
        let vm = PrivacyViewModel()

        await vm.clearHistory(for: target)

        XCTAssertTrue(fm.fileExists(atPath: url.path))
        XCTAssertEqual(ToastCenter.shared.toasts.count, before + 1)
        XCTAssertEqual(ToastCenter.shared.toasts.last?.style, .error)
    }
}
