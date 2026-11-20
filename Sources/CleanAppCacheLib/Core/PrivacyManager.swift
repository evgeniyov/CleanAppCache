import Foundation
import AppKit

// MARK: - Privacy Manager
//
// Privacy is the one destructive section of the eight, and its consequence line
// reads "Deleted permanently: you will be signed out of some sites". Both halves
// of that sentence are promises about behaviour, and this manager keeps both:
//
//   • Cookies and site storage are collected alongside the history files.
//     Nothing else ends a session: clearing History.db only forgets where the
//     user has been.
//   • Everything goes through `DeletionService`, not `TrashService`. "Deleted
//     permanently" has to be literally true, and a Trash holding History.db plus
//     Cookies.binarycookies is still readable browsing history plus a set of
//     live session tokens — an Undo would hand back precisely what the user
//     asked to destroy. History is therefore not recoverable either, so the
//     section has one story instead of two.
//
// Passwords, bookmarks, autofill and extension storage are kept, and the
// confirmation dialog says so; no Undo exists to correct a mistake:
//
//   • Passwords and autofill live in files no list below names.
//   • Firefox keeps bookmarks in places.sqlite, the same database as its
//     history. That file is never deleted; `FirefoxHistory` clears the history
//     inside it.
//   • Per-origin storage folders are deleted one origin at a time, and
//     extension origins are skipped: extensions — password managers among
//     them — keep their data there.
//   • Chromium's Local Storage and Session Storage are each a single database
//     shared by every origin, extensions included. They cannot be split, so
//     they go whole, and the dialog says that extension data kept there goes
//     with the sites'.

/// A live process belonging to a browser — its main app or one of its helpers.
/// Sendable so it can cross back out of the actor.
public struct BrowserProcess: Sendable {
    public let name: String
    public let pid: pid_t
}

public struct BrowserEntry: Identifiable, Sendable {
    public let id: String          // bundle ID
    public let name: String
    public let icon: String        // SF Symbol name
    /// Where the user has been: visited URLs, downloads, last session.
    public let historyFiles: [URL]
    /// Databases that hold history next to data that must stay — Firefox's
    /// places.sqlite, one per profile, which also holds the bookmarks. The
    /// history is cleared inside them and the files stay.
    public let historyDatabases: [URL]
    /// Cookies and per-site storage. Removing these is the half of the clear
    /// that actually signs the user out.
    public let siteDataFiles: [URL]
    /// What deleting `files` frees. The history databases are not counted:
    /// they stay, and clearing rows inside them frees next to nothing.
    public var totalSize: UInt64
    public var isRunning: Bool
    public var isInstalled: Bool
    var unreadableHistoryDatabases: [URL] = []

    /// Everything this row deletes.
    public var files: [URL] { historyFiles + siteDataFiles }

    /// Everything this row deletes or clears.
    public var allFiles: [URL] { files + historyDatabases }

    /// Whether a clear has anything to act on. A history database counts
    /// although its size does not, or a Firefox that has history but no site
    /// data would never get a row.
    public var hasData: Bool { totalSize > 0 || !historyDatabases.isEmpty }

    public var formattedSize: String {
        Fmt.bytes(totalSize)
    }
}

public actor PrivacyManager {
    public static let shared = PrivacyManager()
    private init() {}

    private struct BrowserDefinition {
        let id: String
        let name: String
        let icon: String
        let paths: BrowserPaths
    }

    /// Where one browser keeps what the clear acts on, as absolute URLs, so
    /// `PathGuard` sees absolute, standardised URLs by the time anything is
    /// deleted. The lists name more than any one install has; `scan()` drops
    /// what is not on disk.
    struct BrowserPaths: Equatable {
        var history: [URL] = []
        var historyDatabases: [URL] = []
        var siteData: [URL] = []
    }

    // MARK: - Scan

    /// Re-scan every known browser and return fresh entries.
    public func scan() -> [BrowserEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support")

        let definitions: [BrowserDefinition] = [
            BrowserDefinition(id: "com.apple.Safari",
                              name: "Safari",
                              icon: "safari",
                              paths: BrowserPaths(
                                history: Self.safariHistory.map { home.appendingPathComponent($0) },
                                siteData: Self.safariSiteData.map { home.appendingPathComponent($0) })),
            BrowserDefinition(id: "com.google.Chrome",
                              name: "Google Chrome",
                              icon: "globe",
                              paths: Self.chromiumPaths(
                                userData: support.appendingPathComponent("Google/Chrome"))),
            BrowserDefinition(id: "org.mozilla.firefox",
                              name: "Firefox",
                              icon: "flame",
                              paths: Self.firefoxPaths(
                                profiles: support.appendingPathComponent("Firefox/Profiles"))),
            BrowserDefinition(id: "com.brave.Browser",
                              name: "Brave Browser",
                              icon: "shield",
                              paths: Self.chromiumPaths(
                                userData: support.appendingPathComponent("BraveSoftware/Brave-Browser"))),
            BrowserDefinition(id: "company.thebrowser.Browser",
                              name: "Arc",
                              // "arc.circle" is not an SF Symbol in any
                              // release — the row drew an empty image.
                              icon: "circle.dashed",
                              paths: Self.chromiumPaths(
                                userData: support.appendingPathComponent("Arc/User Data")))
        ]

        return definitions.compactMap { def in
            let history = existing(def.paths.history)
            let databases = Self.probeHistoryDatabases(def.paths.historyDatabases)
            let siteData = existing(def.paths.siteData)
            let isInstalled = !history.isEmpty || !databases.available.isEmpty || !databases.unreadable.isEmpty || !siteData.isEmpty ||
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: def.id) != nil
            guard isInstalled else { return nil }
            return BrowserEntry(
                id: def.id,
                name: def.name,
                icon: def.icon,
                historyFiles: history,
                historyDatabases: databases.available,
                siteDataFiles: siteData,
                totalSize: measure(history) &+ measure(siteData),
                isRunning: Self.blockingProcess(for: def.id) != nil,
                isInstalled: isInstalled,
                unreadableHistoryDatabases: databases.unreadable
            )
        }
        .sorted { $0.name < $1.name }
    }

    static func probeHistoryDatabases(_ urls: [URL]) -> (available: [URL], unreadable: [URL]) {
        var available: [URL] = []
        var unreadable: [URL] = []
        for url in urls {
            switch FirefoxHistory.probe(database: url) {
            case .available: available.append(url)
            case .unknown: unreadable.append(url)
            case .empty: break
            }
        }
        return (available, unreadable)
    }

    /// Keeps only the paths that are actually on this machine. Every browser
    /// below lists more spellings than any one install has — cookie jars moved
    /// between releases — and a path that does not exist simply drops out
    /// instead of being guessed at.
    private func existing(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        return urls.filter { fm.fileExists(atPath: $0.path) }
    }

    /// Local Storage, Session Storage and IndexedDB are directories, so the
    /// `.fileSizeKey` reports 0 for exactly the data the section deletes.
    /// `allocatedSize(of:)` walks them.
    ///
    /// It is a per-scan cost and never a sampling one: this screen measures
    /// only when the user presses Scan.
    private func measure(_ urls: [URL]) -> UInt64 {
        let fm = FileManager.default
        return urls.reduce(UInt64(0)) { $0 &+ ((try? fm.allocatedSize(of: $1)) ?? 0) }
    }

    // MARK: - Clearing

    /// Permanently delete the browser's history **and** site data.
    ///
    /// `cleared` counts the files deleted plus the history databases
    /// cleared: an in-place clear frees next to nothing, so `freed` alone
    /// cannot tell whether anything happened.
    public func clearHistory(for entry: BrowserEntry) -> (freed: UInt64, failed: Int, cleared: Int) {
        // Refuse, never half-delete. A running browser holds these SQLite
        // files open and rewrites them from its own page cache on exit, so a
        // delete underneath it leaves a corrupt profile rather than a clean
        // one. The flag on `entry` is whatever the last scan saw; the live
        // check next to it is what actually matters, because the user may have
        // launched the browser while the dialog was up.
        guard !entry.isRunning, Self.blockingProcess(for: entry.id) == nil else {
            return (0, entry.allFiles.count, 0)
        }

        // Site data first: "signed out of some sites" is the headline of the
        // consequence line, so if anything fails half-way it should be the
        // history that survives, not the session tokens.
        //
        // `DeletionService` runs `PathGuard` over every URL before it touches
        // the filesystem — same gate as every other deletion site in the app.
        let result = DeletionService.delete(entry.siteDataFiles + entry.historyFiles,
                                           validation: { _ in Self.blockingProcess(for: entry.id) == nil })
        var freed = result.freedBytes
        var failed = result.failed.count + result.blocked.count
        var cleared = result.deleted.count

        for database in entry.historyDatabases {
            // Checked again for each database: the deletes above take time,
            // and a browser that is back holds the database and would write
            // its own copy of the history over the clear.
            guard Self.blockingProcess(for: entry.id) == nil else {
                failed += 1
                continue
            }
            switch FirefoxHistory.clear(database: database) {
            case .cleared(let reclaimed):
                freed &+= reclaimed
                cleared += 1
            case .nothingToClear: break
            case .failed(let reason):
                Log.error("History clear left \(database.path) unchanged: \(reason)")
                failed += 1
            }
        }
        return (freed, failed, cleared)
    }

    // MARK: - Running browsers

    /// Any live process belonging to `bundleID`'s application, or `nil` when
    /// the browser is really gone.
    ///
    /// The main bundle id alone is not enough. Chromium runs every tab in a
    /// helper app (`com.brave.Browser.helper.renderer` and friends) and those
    /// outlive the last window by a moment while still holding the profile's
    /// databases open — which is exactly the window in which a delete
    /// corrupts a profile. Helpers are caught two ways: by bundle-id prefix,
    /// and by living inside the browser's own app bundle, which is how
    /// Firefox's nested `plugin-container.app` is spotted.
    ///
    /// Static, therefore non-isolated: the view polls it on the main actor
    /// while waiting for a browser to quit, and the actor uses it as the gate
    /// on `clearHistory`.
    public static func blockingProcess(for bundleID: String) -> BrowserProcess? {
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }

        // Cheap pass first — the browser itself and the helpers Chromium names
        // after it.
        for app in running {
            guard let id = app.bundleIdentifier,
                  id == bundleID || id.hasPrefix(bundleID + ".") else { continue }
            return BrowserProcess(name: app.localizedName ?? bundleID,
                                  pid: app.processIdentifier)
        }

        // Only now ask LaunchServices where the app lives. The lookup is the
        // expensive half of this function and it only buys the second pass:
        // helpers nested inside the browser's own bundle under an unrelated id.
        guard let appPath = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)?
            .standardizedFileURL.path else { return nil }

        for app in running {
            guard let path = app.bundleURL?.standardizedFileURL.path,
                  path == appPath || path.hasPrefix(appPath + "/") else { continue }
            return BrowserProcess(name: app.localizedName ?? bundleID,
                                  pid: app.processIdentifier)
        }
        return nil
    }

    // MARK: - Path definitions

    /// Safari, which is sandboxed: its own data lives in its container, and the
    /// pre-sandbox locations are kept because they survive an in-place upgrade.
    /// Relative to the home folder.
    private static let safariHistory: [String] = [
        "Library/Safari/History.db",
        // The SQLite sidecars (`<db>-wal` / `<db>-shm`) hold writes that have
        // not landed in the main file yet; without them the browser can put
        // back what we just cleared.
        "Library/Safari/History.db-wal",
        "Library/Safari/History.db-shm",
        "Library/Safari/LastSession.plist",
        "Library/Safari/Downloads.plist"
    ]

    private static let safariSiteData: [String] = [
        // The shared `~/Library/Cookies/Cookies.binarycookies` is deliberately
        // NOT here. That jar belongs to every non-sandboxed app on the Mac, not
        // to Safari, and signing the user out of those is not what this row
        // promises.
        "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
        "Library/Containers/com.apple.Safari/Data/Library/HTTPStorages/com.apple.Safari.binarycookies",
        "Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/LocalStorage",
        "Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteData/IndexedDB",
        "Library/HTTPStorages/com.apple.Safari",
        "Library/HTTPStorages/com.apple.Safari.binarycookies",
        "Library/WebKit/com.apple.Safari/WebsiteData/LocalStorage",
        "Library/WebKit/com.apple.Safari/WebsiteData/IndexedDB",
        "Library/Safari/LocalStorage",
        "Library/Safari/Databases"
    ]

    /// Chrome, Brave and Arc are the same browser with different user-data
    /// folders, so they get the same list under each of their profiles.
    static func chromiumPaths(userData: URL) -> BrowserPaths {
        var paths = BrowserPaths()
        for profile in chromiumProfiles(in: userData) {
            paths.history += [
                "History", "History-journal", "History-wal", "History-shm",
                "Visited Links"
            ].map { profile.appendingPathComponent($0) }
            paths.siteData += [
                // Chrome 96 moved the cookie jar into `Network/`; Brave still
                // writes it at the profile root. Both spellings are listed and
                // `existing(_:)` picks whichever this machine has — guessing
                // the user's build would be the wrong kind of certainty.
                "Cookies", "Cookies-journal",
                "Network/Cookies", "Network/Cookies-journal",
                // Single databases shared by every origin, extensions included.
                "Local Storage", "Session Storage"
            ].map { profile.appendingPathComponent($0) }
            // One folder per origin: the sites' go, the extensions' stay.
            paths.siteData += siteOrigins(in: profile.appendingPathComponent("IndexedDB"),
                                          extensionPrefix: "chrome-extension_")
        }
        return paths
    }

    /// Every profile in a Chromium user-data folder: `Default`, `Profile 1`,
    /// `Profile 2`, … — any subfolder holding a `Preferences` file. That also
    /// takes in `System Profile` and `Guest Profile` when they have one, which
    /// is harmless: only the files a profile actually holds survive `existing`.
    static func chromiumProfiles(in userData: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: userData, includingPropertiesForKeys: nil) else {
            return []
        }
        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("Preferences").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Firefox keeps one directory per profile and the user may have several,
    /// so every profile contributes to the same row.
    static func firefoxPaths(profiles: URL) -> BrowserPaths {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: profiles, includingPropertiesForKeys: nil
        ) else { return BrowserPaths() }

        var paths = BrowserPaths()
        for profile in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            // History and bookmarks share places.sqlite. Deleting it, or its
            // write-ahead log, loses bookmarks; the history is cleared inside
            // it instead.
            paths.historyDatabases.append(profile.appendingPathComponent("places.sqlite"))
            paths.siteData += sqliteSet(profile, "cookies.sqlite")
            // Legacy localStorage; modern Firefox writes it under `storage`.
            paths.siteData += sqliteSet(profile, "webappsstore.sqlite")
            // The quota-manager store: IndexedDB, localStorage and the Cache
            // API, one folder per origin. The sites' folders are what
            // Firefox's own "Cookies and Site Data" clears besides the cookie
            // jar; the extensions' folders hold their `storage.local`.
            paths.siteData += siteOrigins(in: profile.appendingPathComponent("storage/default"),
                                          extensionPrefix: "moz-extension+++")
        }
        // Non-profile entries in the directory produce paths that do not exist
        // and drop out in `scan()`.
        return paths
    }

    /// The entries of a per-origin storage folder, less the extension origins
    /// named with `extensionPrefix`. The folder itself stays.
    static func siteOrigins(in directory: URL, extensionPrefix: String) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { !$0.lastPathComponent.lowercased().hasPrefix(extensionPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A SQLite database and the write-ahead sidecars that can resurrect it.
    private static func sqliteSet(_ directory: URL, _ name: String) -> [URL] {
        let base = directory.appendingPathComponent(name).path
        return [base, base + "-wal", base + "-shm"].map { URL(fileURLWithPath: $0) }
    }
}
