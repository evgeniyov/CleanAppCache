import XCTest
@testable import CleanAppCacheLib

/// What the Privacy clear aims at, checked on a fake browser folder: every
/// profile counts, extension storage is spared, and Firefox's places.sqlite is
/// never on a delete list.
final class PrivacyPathsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("privacy_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ relative: String, directory: Bool = false) throws {
        let url = root.appendingPathComponent(relative)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        }
    }

    /// Paths below `root`. Cut at the unique folder name rather than by
    /// length: directory listings may spell the temporary folder /private/var.
    private func relative(_ urls: [URL]) -> Set<String> {
        let marker = "/" + root.lastPathComponent + "/"
        return Set(urls.compactMap { url in
            url.path.range(of: marker).map { String(url.path[$0.upperBound...]) }
        })
    }

    func testChromiumCoversEveryProfileAndSparesExtensionIndexedDB() throws {
        for profile in ["Default", "Profile 1", "Profile 3"] {
            try make("User Data/\(profile)/Preferences")
            try make("User Data/\(profile)/History")
        }
        try make("User Data/Profile 1/IndexedDB/https_example.com_0.indexeddb.leveldb", directory: true)
        try make("User Data/Profile 1/IndexedDB/chrome-extension_abcdef_0.indexeddb.leveldb", directory: true)
        // Not profiles: no Preferences file.
        try make("User Data/Crashpad/settings.dat")
        try make("User Data/Snapshots/History")
        try make("User Data/Local State")

        let paths = PrivacyManager.chromiumPaths(userData: root.appendingPathComponent("User Data"))

        let history = relative(paths.history)
        XCTAssertTrue(history.contains("User Data/Default/History"))
        XCTAssertTrue(history.contains("User Data/Profile 1/History"))
        XCTAssertTrue(history.contains("User Data/Profile 3/History"))
        XCTAssertFalse(history.contains { $0.hasPrefix("User Data/Snapshots") || $0.hasPrefix("User Data/Crashpad") })

        let siteData = relative(paths.siteData)
        XCTAssertTrue(siteData.contains("User Data/Profile 1/IndexedDB/https_example.com_0.indexeddb.leveldb"))
        XCTAssertFalse(siteData.contains { $0.contains("chrome-extension_") },
                       "extension IndexedDB must stay")
        XCTAssertFalse(siteData.contains("User Data/Profile 1/IndexedDB"),
                       "the per-origin folder is cleared origin by origin, not as a whole")
    }

    func testFirefoxClearsHistoryInPlaceAndSparesExtensionStorage() throws {
        try make("Profiles/abc.default-release/places.sqlite")
        try make("Profiles/abc.default-release/places.sqlite-wal")
        try make("Profiles/abc.default-release/cookies.sqlite")
        try make("Profiles/abc.default-release/storage/default/https+++example.com", directory: true)
        try make("Profiles/abc.default-release/storage/default/moz-extension+++1234^userContextId=4294967295",
                 directory: true)

        let paths = PrivacyManager.firefoxPaths(profiles: root.appendingPathComponent("Profiles"))

        XCTAssertEqual(relative(paths.historyDatabases), ["Profiles/abc.default-release/places.sqlite"])
        let deleted = relative(paths.history + paths.siteData)
        XCTAssertFalse(deleted.contains { $0.contains("places.sqlite") },
                       "places.sqlite and its sidecars hold the bookmarks and are never deleted")
        XCTAssertTrue(deleted.contains("Profiles/abc.default-release/cookies.sqlite"))
        XCTAssertTrue(deleted.contains("Profiles/abc.default-release/storage/default/https+++example.com"))
        XCTAssertFalse(deleted.contains { $0.contains("moz-extension+++") }, "extension storage must stay")
        XCTAssertFalse(deleted.contains("Profiles/abc.default-release/storage/default"))
    }
}
