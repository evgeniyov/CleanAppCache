import Foundation
import AppKit
import SwiftUI
// For `MDItemCreate` / `kMDItemLastUsedDate`: Spotlight is the only thing on the
// machine that records when an app was *launched* — see
// `AppManager.lastOpenedDate(of:)`.
import CoreServices

public struct InstalledApp: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let url: URL
    public let name: String
    public let bundleIdentifier: String?
    public let version: String?
    public let size: UInt64
    public var associatedFiles: [AssociatedFile]
    /// When the .app was added to its folder (best "installed on" proxy), if known.
    public let installDate: Date?
    /// When the app was last *launched*, if the system knows — the uninstaller's
    /// last-launched column. `nil` means unknown, which the screen renders as
    /// "—" and never treats as "old". Read by `lastOpenedDate(of:)`.
    ///
    /// A `var` with a default so the memberwise initializer does not require
    /// it from call sites that have no launch date to pass.
    public var lastOpened: Date? = nil
    /// Another installed copy with the same bundle id (Xcode and Xcode-beta).
    /// The two read and write the same `~/Library` entries, so none of them
    /// is listed as this copy's to delete.
    public var sharedDataWith: URL? = nil
    var removalIdentity: RemovalIdentity?

    init(url: URL, name: String, bundleIdentifier: String?, version: String?, size: UInt64,
         associatedFiles: [AssociatedFile], installDate: Date?, lastOpened: Date? = nil,
         sharedDataWith: URL? = nil) {
        self.url = url; self.name = name; self.bundleIdentifier = bundleIdentifier
        self.version = version; self.size = size; self.associatedFiles = associatedFiles
        self.installDate = installDate; self.lastOpened = lastOpened; self.sharedDataWith = sharedDataWith
        removalIdentity = RemovalIdentity(at: url, bundle: true)
    }

    /// Full path to the .app bundle.
    public var path: String { url.path }
    /// Folder that contains the .app (e.g. "/Applications").
    public var folderPath: String { url.deletingLastPathComponent().path }

    public var formattedSize: String {
        Fmt.bytes(Int64(totalSize))
    }
    
    public var totalSize: UInt64 {
        size + associatedFiles.reduce(0) { $0 + $1.size }
    }
    
    public static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool {
        lhs.url == rhs.url
    }
}

public struct AssociatedFile: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let url: URL
    public let type: AssociatedFileType
    public let size: UInt64
    var removalIdentity: RemovalIdentity?

    init(url: URL, type: AssociatedFileType, size: UInt64) {
        self.url = url; self.type = type; self.size = size
        removalIdentity = RemovalIdentity(at: url)
    }
    
    public var name: String {
        url.lastPathComponent
    }
    
    public var formattedSize: String {
        Fmt.bytes(Int64(size))
    }
}

public enum AssociatedFileType: String, CaseIterable, Sendable {
    case cache = "Cache"
    case preference = "Preferences"
    case container = "Container"
    case groupContainer = "Group Container"
    case savedState = "Saved State"
    case log = "Log"
    case support = "Application Support"
    /// HTTPStorages, WebKit and Cookies: what an app's web views keep.
    case webData = "Web Data"

    public var icon: String {
        switch self {
        case .cache: return "folder.fill"
        case .preference: return "gear"
        case .container: return "archivebox"
        case .groupContainer: return "square.stack.3d.up"
        case .savedState: return "doc.on.doc"
        case .log: return "doc.text"
        case .support: return "wrench"
        case .webData: return "globe"
        }
    }
}

public actor AppManager {
    public static let shared = AppManager()
    
    private init() {}
    
    /// One entry of the pre-built `~/Library` index: the folder/file name (lower-
    /// cased for matching) plus which associated-file category it belongs to.
    private struct LibraryEntry: Sendable {
        let type: AssociatedFileType
        /// Lowercased name of an app-specific entry; shared groups never enter the index.
        let lowerName: String
        let url: URL
        let identity: RemovalIdentity?
    }

    /// `ABCDE12345.group.com.acme.app` → `com.acme.app`. App groups are named
    /// `group.<id>` or `<TeamID>.<id>`; a Team ID is ten uppercase letters or
    /// digits. A name left with fewer than two dots after stripping
    /// (`UBF8T346G9.Office`) is a suite-wide group shared by several apps and
    /// matches no single bundle id.
    nonisolated static func groupMatchName(_ name: String) -> String {
        var rest = Substring(name)
        if let dot = rest.firstIndex(of: "."), rest.distance(from: rest.startIndex, to: dot) == 10,
           rest[..<dot].allSatisfy({ ($0.isUppercase && $0.isASCII) || $0.isNumber }) {
            rest = rest[rest.index(after: dot)...]
        }
        if rest.lowercased().hasPrefix("group.") { rest = rest.dropFirst("group.".count) }
        return rest.lowercased()
    }

    public func findInstalledApps(progress: (@Sendable (Int, Int, String) -> Void)? = nil) async -> [InstalledApp] {
        guard !Task.isCancelled else { return [] }
        let appURLs = discoverAppBundles()
        guard !Task.isCancelled, !appURLs.isEmpty else { return [] }
        // List the ~/Library locations ONCE and match every app against the
        // in-memory index: O(dirs + apps × matches) instead of re-listing every
        // dir per app, which is O(apps × dirs).
        let index = buildLibraryIndex()
        guard !Task.isCancelled else { return [] }
        // Needed so a `<bundleID>.`-prefix match cannot claim a sibling app's data.
        let installedIDs = installedBundleIDs()
        guard !Task.isCancelled else { return [] }
        let total = appURLs.count

        // Size apps concurrently. Each app's sizing spawns du subprocesses (bundle
        // + associated files) that are I/O-bound, so a bounded sliding window is
        // dramatically faster than sizing one app at a time. Matching against the
        // prebuilt index is pure. Work runs in nonisolated tasks so the actor isn't
        // the bottleneck.
        let maxConcurrency = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
        var apps: [InstalledApp] = []
        apps.reserveCapacity(total)
        var done = 0

        await withTaskGroup(of: InstalledApp?.self) { group in
            var next = 0
            while next < min(maxConcurrency, total), !Task.isCancelled {
                let url = appURLs[next]
                guard group.addTaskUnlessCancelled(operation: {
                    Self.parse(url: url, index: index, installedIDs: installedIDs)
                }) else { break }
                next += 1
            }
            while let result = await group.next() {
                guard !Task.isCancelled else { group.cancelAll(); break }
                done += 1
                if let app = result {
                    apps.append(app)
                    progress?(done, total, app.name)
                } else {
                    progress?(done, total, "")
                }
                if next < total {
                    let url = appURLs[next]
                    guard group.addTaskUnlessCancelled(operation: {
                        Self.parse(url: url, index: index, installedIDs: installedIDs)
                    }) else { break }
                    next += 1
                }
            }
        }
        guard !Task.isCancelled else { return [] }
        if apps.contains(where: { $0.bundleIdentifier == nil && !$0.associatedFiles.isEmpty }) {
            let owners = Self.installedNameOwners()
            for index in apps.indices where apps[index].bundleIdentifier == nil {
                let app = apps[index]
                if Self.otherNameOwner(named: app.name, outside: app.url, in: owners) {
                    apps[index].associatedFiles = []
                }
            }
        }
        guard !Task.isCancelled else { return [] }
        return Self.separateSharedData(apps).sorted { $0.name < $1.name }
    }

    /// Clears the associated files of every app whose bundle id another
    /// listed app also has, and names the other copy. The files are matched by
    /// bundle id, so they are the other copy's working data as much as this
    /// one's; uninstalling one copy must not erase the other's settings.
    nonisolated static func separateSharedData(_ apps: [InstalledApp]) -> [InstalledApp] {
        var byID: [String: [Int]] = [:]
        for (index, app) in apps.enumerated() {
            guard let id = app.bundleIdentifier?.lowercased(), !id.isEmpty else { continue }
            byID[id, default: []].append(index)
        }
        var result = apps
        for indices in byID.values where indices.count > 1 {
            for index in indices {
                result[index].associatedFiles = []
                result[index].sharedDataWith = indices.first { $0 != index }.map { apps[$0].url }
            }
        }
        return result
    }

    /// Fast bundle-ID-only enumeration: reads CFBundleIdentifier from each app's
    /// Info.plist without sizing or associated-file lookup. Used by Leftovers to
    /// know what's installed cheaply (includes system apps so their data isn't
    /// mistaken for a leftover).
    public func installedBundleIDs() -> Set<String> {
        // Leftovers, Orphans and the uninstaller all need this, and each call
        // walks ~400 bundles parsing an Info.plist apiece. A short TTL keeps
        // consecutive tab visits from repeating the whole traversal while still
        // noticing an app the user just dragged to the Trash.
        if let cached = cachedBundleIDs,
           Date().timeIntervalSince(cached.at) < Self.bundleIDCacheTTL {
            return cached.ids
        }
        var ids: Set<String> = []
        for url in Self.appBundles(in: Self.appRoots(includingSystem: true)) {
            let info = url.appendingPathComponent("Contents/Info.plist")
            if let plist = NSDictionary(contentsOf: info),
               let bid = plist["CFBundleIdentifier"] as? String {
                ids.insert(bid.lowercased())
            }
        }
        cachedBundleIDs = (ids, Date())
        return ids
    }

    private var cachedBundleIDs: (ids: Set<String>, at: Date)?
    private var cachedInventory: (inventory: InstalledInventory, at: Date)?
    private static let bundleIDCacheTTL: TimeInterval = 60

    /// Drop the cache after an install/uninstall so the next scan sees reality.
    public func invalidateBundleIDCache() {
        cachedBundleIDs = nil
        cachedInventory = nil
    }

    // MARK: - Installed inventory

    /// Everything an installed app is known by, for deciding whether a
    /// `~/Library` entry belongs to something still installed.
    ///
    /// An app's own bundle id is not enough: its extensions, login items and
    /// XPC services have ids of their own, often under another vendor prefix
    /// (`com.bitrixsoft.bitrix24desktop.finder-ext` inside
    /// `ru.bitrix.bitrix24desktop`), some apps name their support folder
    /// after the app rather than the id (`Yandex.Disk.2`), and a vendor's
    /// shared components (`com.microsoft.office`) belong to whichever of its
    /// apps is installed.
    public struct InstalledInventory: Sendable {
        /// Lowercased ids of installed apps, of every bundle inside them, and
        /// of running apps.
        public let bundleIDs: Set<String>
        /// Lowercased app names: the bundle's file name and `CFBundleName`.
        public let names: Set<String>
        /// Vendor tokens of those ids (`microsoft`, `blackmagic-design`).
        public let vendors: Set<String>
    }

    public func installedInventory() async -> InstalledInventory {
        await installedInventory(refreshing: false)
    }

    func installedInventory(refreshing: Bool) async -> InstalledInventory {
        if !refreshing, let cached = cachedInventory,
           Date().timeIntervalSince(cached.at) < Self.bundleIDCacheTTL {
            return cached.inventory
        }
        let fm = FileManager.default
        var ids: Set<String> = []
        var names: Set<String> = []

        func infoPlist(of url: URL) -> NSDictionary? {
            NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                ?? NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
        }
        for url in Self.appBundles(in: Self.appRoots(includingSystem: true)) {
            let info = infoPlist(of: url)
            if let id = info?["CFBundleIdentifier"] as? String { ids.insert(id.lowercased()) }
            names.insert(url.deletingPathExtension().lastPathComponent.lowercased())
            if let name = info?["CFBundleName"] as? String { names.insert(name.lowercased()) }
            for sub in Self.embeddedBundleFolders {
                let folder = url.appendingPathComponent(sub)
                guard let embedded = try? fm.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil) else { continue }
                for item in embedded {
                    if let id = infoPlist(of: item)?["CFBundleIdentifier"] as? String { ids.insert(id.lowercased()) }
                    // Privileged helpers ship as bare binaries named by id.
                    if sub == "Contents/Library/LaunchServices" {
                        ids.insert(item.lastPathComponent.lowercased())
                    }
                }
            }
        }
        ids.formUnion(await Self.runningBundleIDs())

        let inventory = InstalledInventory(
            bundleIDs: ids,
            names: names,
            vendors: Set(ids.compactMap(Self.vendorToken(of:)))
        )
        cachedInventory = (inventory, Date())
        return inventory
    }

    /// Folders inside an app bundle that hold bundles with ids of their own.
    private static let embeddedBundleFolders = [
        "Contents/PlugIns", "Contents/Extensions", "Contents/XPCServices",
        "Contents/Helpers", "Contents/Frameworks", "Contents/Library/LoginItems",
        "Contents/Library/LaunchServices", "Contents/Library/SystemExtensions",
        "Contents/Library/QuickLook", "Contents/Library/Spotlight"
    ]

    @MainActor
    private static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
    }

    /// The organisation a reverse-DNS id names: `com.microsoft.word` →
    /// `microsoft`, `jetbrains.py.253` → `jetbrains`. Nil for tokens that name
    /// no one in particular — every Electron app defaults to `com.electron.*`.
    nonisolated static func vendorToken(of id: String) -> String? {
        let parts = id.lowercased().split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let token = String(topLevelDomains.contains(String(parts[0])) ? parts[1] : parts[0])
        guard token.count >= 3, !genericVendorTokens.contains(token) else { return nil }
        return token
    }

    private static let topLevelDomains: Set<String> = [
        "com", "org", "net", "io", "co", "app", "dev", "me", "pro", "info", "biz", "tv", "ai",
        "us", "uk", "ru", "de", "fr", "jp", "cn", "ch", "nl", "se", "it", "eu", "cc", "sh",
        "to", "ly", "so", "xyz", "edu", "gov", "local", "su", "ua", "by", "kz", "pl", "es"
    ]

    private static let genericVendorTokens: Set<String> = [
        "electron", "github", "example", "company", "yourcompany", "mycompany",
        "unknown", "test", "apps", "application"
    ]

    /// Discovers `.app` bundles the user can uninstall: /Applications,
    /// /Applications/Utilities, ~/Applications, plus one level into vendor
    /// subfolders (e.g. /Applications/Setapp). System apps are deliberately
    /// excluded — the uninstaller must never offer to delete Safari, Mail, etc.
    private func discoverAppBundles() -> [URL] {
        Self.appBundles(in: Self.appRoots(includingSystem: false))
    }

    /// Where installed apps live. The uninstaller lists only the user's
    /// folders; ownership checks also count the system apps, whose data must
    /// never be taken for another app's.
    nonisolated static func appRoots(includingSystem: Bool) -> [URL] {
        let user = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        ]
        guard includingSystem else { return user }
        return user + [
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]
    }

    /// Every `.app` directly in `roots` or one folder below (a vendor folder
    /// such as /Applications/Setapp), each once. Discovery and the installed-id
    /// sets share this walk so they cannot disagree about what is installed.
    nonisolated static func appBundles(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        var seen: Set<String> = []
        var bundles: [URL] = []
        func walk(_ dir: URL, depth: Int) {
            guard let contents = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
            for url in contents {
                if url.pathExtension.lowercased() == "app" {
                    if seen.insert(url.standardizedFileURL.path).inserted { bundles.append(url) }
                } else if depth > 0,
                          (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    walk(url, depth: depth - 1)
                }
            }
        }
        for root in roots where fm.fileExists(atPath: root.path) { walk(root, depth: 1) }
        return bundles
    }

    /// An app row must represent a package with its own executable, even
    /// when its plist has no bundle identifier.
    nonisolated static func uninstallableBundleInfo(at url: URL) -> NSDictionary? {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        let info = contents.appendingPathComponent("Info.plist")
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        guard url.pathExtension.lowercased() == "app",
              (FileSnapshot(at: url)?.mode ?? 0) & S_IFMT == S_IFDIR,
              (FileSnapshot(at: contents)?.mode ?? 0) & S_IFMT == S_IFDIR,
              (FileSnapshot(at: macOS)?.mode ?? 0) & S_IFMT == S_IFDIR,
              FileSnapshot(at: info)?.isRegularFile == true,
              let plist = NSDictionary(contentsOf: info), plist["CFBundlePackageType"] as? String == "APPL",
              let name = plist["CFBundleExecutable"] as? String, !name.isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { return nil }
        let executable = macOS.appendingPathComponent(name)
        guard FileSnapshot(at: executable)?.isRegularFile == true,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return plist
    }

    nonisolated static func installedNameOwners(
        in roots: [URL] = appRoots(includingSystem: true)
    ) -> [String: Set<String>] {
        var owners: [String: Set<String>] = [:]
        for url in appBundles(in: roots) {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                ?? NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            let names = [url.deletingPathExtension().lastPathComponent,
                         info?["CFBundleName"] as? String, info?["CFBundleDisplayName"] as? String]
            for name in names.compactMap({ $0 }) { owners[name.lowercased(), default: []].insert(path) }
        }
        return owners
    }

    /// Lists the `~/Library` locations where apps keep per-app data, once,
    /// into a flat index. Each entry there is named after one bundle id —
    /// the folder, the plist, or the group container.
    private func buildLibraryIndex() -> [LibraryEntry] {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        let searchPaths: [(String, AssociatedFileType)] = [
            ("Caches", .cache),
            ("Preferences", .preference),
            ("Preferences/ByHost", .preference),
            ("Containers", .container),
            ("Group Containers", .groupContainer),
            ("Application Scripts", .container),
            ("Saved Application State", .savedState),
            ("Logs", .log),
            ("Application Support", .support),
            ("HTTPStorages", .webData),
            ("WebKit", .webData),
            ("Cookies", .webData)
        ]
        var index: [LibraryEntry] = []
        for (folder, type) in searchPaths {
            guard !Task.isCancelled else { return [] }
            guard let contents = try? fm.contentsOfDirectory(
                at: library.appendingPathComponent(folder), includingPropertiesForKeys: nil) else { continue }
            let grouped = folder == "Group Containers" || folder == "Application Scripts"
            for item in contents {
                guard !Task.isCancelled else { return [] }
                let name = item.lastPathComponent
                guard !Self.preservesSharedData(at: item, type: type) else { continue }
                index.append(LibraryEntry(type: type,
                                          lowerName: grouped ? Self.groupMatchName(name) : name.lowercased(),
                                          url: item, identity: RemovalIdentity(at: item)))
            }
        }
        return index
    }

    /// Parses one app bundle into an `InstalledApp`. `nonisolated static` so it can
    /// run concurrently in a task group without serializing on the actor.
    private nonisolated static func parse(
        url: URL,
        index: [LibraryEntry],
        installedIDs: Set<String>
    ) -> InstalledApp? {
        guard !Task.isCancelled, let identity = RemovalIdentity(at: url, bundle: true),
              let plist = uninstallableBundleInfo(at: url) else { return nil }
        let bundleID = (plist["CFBundleIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let version = plist["CFBundleShortVersionString"] as? String

        let name = url.deletingPathExtension().lastPathComponent
        guard !Task.isCancelled else { return nil }
        let size = Scanner.shared.calculateSize(at: url)
        guard !Task.isCancelled else { return nil }
        let associatedFiles = matchAssociatedFiles(
            appName: name, bundleID: bundleID, bundle: url, index: index, installedIDs: installedIDs
        )

        // "Date added" is the closest proxy for when the app was installed;
        // fall back to the bundle's creation date.
        let dateVals = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
        let installDate = dateVals?.addedToDirectoryDate ?? dateVals?.creationDate

        guard identity.matches(url) else { return nil }
        var app = InstalledApp(
            url: url,
            name: name,
            bundleIdentifier: bundleID,
            version: version,
            size: size,
            associatedFiles: associatedFiles,
            installDate: installDate,
            lastOpened: lastOpenedDate(of: url)
        )
        app.removalIdentity = identity
        return app
    }

    nonisolated static func otherNameOwner(named name: String, outside bundle: URL, in owners: [String: Set<String>]) -> Bool {
        let path = bundle.standardizedFileURL.resolvingSymlinksInPath().path
        return owners[name.lowercased()]?.contains { $0 != path } == true
    }

    /// When `url`'s bundle was last launched, or nil if nothing on this machine
    /// knows.
    ///
    /// **Spotlight wins.** `kMDItemLastUsedDate` is written by LaunchServices
    /// when the app is *opened*, so it means what the column claims to mean.
    /// The alternative — the bundle's access date, the key
    /// `LargeFilesViewModel` reads for its own last-used column — only
    /// means "something touched this", and on the measured machine it lags the
    /// launch date badly (Keka: Spotlight 26 Jun, atime 11 Apr).
    ///
    /// **The access date is the fallback,** for the two cases Spotlight cannot
    /// answer: an app that has not been launched since it was indexed (nearly
    /// every stock /System app here returns nil), and a volume with indexing
    /// switched off, where there is no metadata at all. It is safe to fall back
    /// to because reading a bundle does not move it — measured on this APFS
    /// volume, neither `contentsOfDirectory` nor the `du` this very scan runs
    /// over each app changed a bundle's access date — so the uninstaller cannot
    /// pollute its own answer and report every app as "opened just now".
    ///
    /// nil from both stays nil: the screen prints "—", sorts the row last and never
    /// counts it as stale. "We do not know" is not "opened long ago".
    ///
    /// Cost: ~1 ms per bundle (90 apps in 86 ms, measured). This runs once per
    /// app inside the uninstaller scan, which already spawns a `du` per app —
    /// never on the 2 s / 5 s sampling path.
    private nonisolated static func lastOpenedDate(of url: URL) -> Date? {
        if let item = MDItemCreate(nil, url.path as CFString),
           let value = MDItemCopyAttribute(item, kMDItemLastUsedDate),
           let launched = value as? Date {
            return launched
        }
        return (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
    }

    /// The installed bundle id that owns `name`, i.e. the longest installed id
    /// that `name` equals or extends. `com.acme.app.helper` is owned by
    /// `com.acme.app`; `com.acme.apple` is owned by nothing just because
    /// `com.acme.app` exists.
    ///
    /// `applicationExists` adds apps the folder walk does not see: one run
    /// from Downloads or an external disk still owns the data named after it.
    nonisolated static func owningBundleID(of name: String, installed: Set<String>,
                                           applicationExists: (String) -> Bool = { _ in false }) -> String? {
        if installed.contains(name) || applicationExists(name) { return name }
        var prefix = name
        while let dot = prefix.lastIndex(of: ".") {
            prefix = String(prefix[prefix.startIndex..<dot])
            guard prefix.contains(".") else { return nil }
            if installed.contains(prefix) || applicationExists(prefix) { return prefix }
        }
        return nil
    }

    /// Whether `name` belongs to an app other than `bundleID`, either one the
    /// folder walk installed or one LaunchServices knows elsewhere. The
    /// uninstaller checks this before taking a `<bundleID>.`-prefixed entry:
    /// `com.acme.app.pro` run from Downloads keeps its data when `com.acme.app`
    /// is removed.
    nonisolated static func ownedByAnotherApp(_ name: String, bundleID: String, bundle: URL,
                                              installed: Set<String>) -> Bool {
        let owner = owningBundleID(of: name, installed: installed) { id in
            id != bundleID && !registeredCopies(of: id, outside: bundle).isEmpty
        }
        return owner.map { $0 != bundleID } ?? false
    }

    /// Apps with `id` that LaunchServices knows, still on disk, outside
    /// `bundle` (its own embedded helpers do not count as another app) and
    /// outside the Trash.
    nonisolated static func registeredCopies(of id: String, outside bundle: URL) -> [URL] {
        let own = bundle.standardizedFileURL.path.lowercased()
        let trash = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash").path.lowercased()
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).filter { url in
            let path = url.standardizedFileURL.path
            return !PathGuard.isUnder(path.lowercased(), own)
                && !PathGuard.isUnder(path.lowercased(), trash)
                && FileManager.default.fileExists(atPath: path)
        }
    }

    /// Group names do not prove exclusive ownership, even when they equal a bundle id.
    /// Apply this at discovery and again to stale selections before any delete route.
    nonisolated static func preservesSharedData(at url: URL, type: AssociatedFileType) -> Bool {
        if type == .groupContainer { return true }
        func grouped(_ candidate: URL) -> Bool {
            let parent = candidate.deletingLastPathComponent().lastPathComponent.lowercased()
            if parent == "group containers" { return true }
            guard parent == "application scripts" else { return false }
            return groupMatchName(candidate.lastPathComponent) != candidate.lastPathComponent.lowercased()
        }
        return grouped(url) || grouped(url.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// Only the exact bundle-id script directory proves an individual app owns it.
    /// A prefix or a display-name fallback may instead name another app or a group.
    nonisolated static func scriptOwnerMatches(_ url: URL, bundleID: String?) -> Bool {
        for candidate in [url, url.standardizedFileURL.resolvingSymlinksInPath()] {
            if candidate.deletingLastPathComponent().lastPathComponent.lowercased() == "application scripts" {
                guard let bid = bundleID?.lowercased(), !bid.isEmpty,
                      candidate.lastPathComponent.lowercased() == bid else { return false }
            }
        }
        return true
    }

    private nonisolated static func matchAssociatedFiles(
        appName: String,
        bundleID: String?,
        bundle: URL,
        index: [LibraryEntry],
        installedIDs: Set<String>
    ) -> [AssociatedFile] {
        let appNameLower = appName.lowercased()
        var files: [AssociatedFile] = []
        var matched: [LibraryEntry] = []
        for entry in index {
            guard Self.scriptOwnerMatches(entry.url, bundleID: bundleID) else { continue }
            // Match strictly on the bundle identifier. A reverse-DNS bundle ID
            // is globally unique, so an exact match or a `<bundleID>.`-prefix
            // match (catches `com.app.plist`, `com.app.savedState`,
            // `com.app.helper`, …) is safe. We deliberately do NOT fall back to
            // substring matching on the display name: a short/common app name
            // ("Code", "Update", "Mail") would lexically collide with unrelated
            // bundles' folders and permanently delete THEIR data.
            var match: Bool
            if let bid = bundleID?.lowercased(), !bid.isEmpty {
                match = entry.lowerName == bid || entry.lowerName.hasPrefix(bid + ".")
                // A `<bid>.`-prefix match can belong to a *different* installed
                // app: uninstalling com.adobe.acrobat would otherwise take
                // com.adobe.acrobat.reader's data with it. Whoever owns the
                // longest matching installed id wins.
                if match, entry.lowerName != bid,
                   Self.ownedByAnotherApp(entry.lowerName, bundleID: bid, bundle: bundle,
                                          installed: installedIDs) {
                    match = false
                }
            } else {
                // No bundle ID known: only an exact, whole-name folder match.
                match = entry.lowerName == appNameLower
            }
            if match { matched.append(entry) }
        }

        // Size every match in one batched `du` instead of a subprocess each —
        // per-file subprocesses would dominate the cost of an uninstaller scan.
        guard !Task.isCancelled else { return [] }
        let sizes = Scanner.shared.calculateSizes(at: matched.map(\.url))
        for entry in matched {
            guard entry.identity?.matches(entry.url) == true else { continue }
            var file = AssociatedFile(
                url: entry.url,
                type: entry.type,
                size: sizes[entry.url.path] ?? 0
            )
            file.removalIdentity = entry.identity
            files.append(file)
        }
        return files
    }
    
    // MARK: - Uninstall

    /// What the confirmation must say before an uninstall starts: whether a
    /// password will be asked for, which apps will be quit, and whose data
    /// stays because another copy of the app uses it.
    public struct UninstallCheck: Sendable {
        public let app: InstalledApp
        /// This account cannot remove the bundle (installed by a package or
        /// the App Store, owned by root), or some of its data; an
        /// administrator password will be asked for.
        public let needsAdmin: Bool
        /// The app is running and will be asked to quit first.
        public let isRunning: Bool
        /// Another installed copy with the same bundle id. Its settings,
        /// caches and containers are the same files, so they stay.
        public let sharedWith: URL?
    }

    public func check(_ apps: [InstalledApp]) async -> [UninstallCheck] {
        let running = await Self.runningBundlePaths()
        return apps.map { app in
            let shared = Self.otherCopy(of: app)
            // The confirmation must announce every password prompt the
            // uninstall will raise, including one for root-owned data only.
            let needsAdmin = RemovalCheck.deleteObstacle(at: app.url) == .needsAdmin
                || (shared == nil && app.associatedFiles.contains {
                    !Self.preservesSharedData(at: $0.url, type: $0.type)
                        && Self.scriptOwnerMatches($0.url, bundleID: app.bundleIdentifier)
                        && RemovalCheck.deleteObstacle(at: $0.url) == .needsAdmin
                })
            return UninstallCheck(
                app: app,
                needsAdmin: needsAdmin,
                isRunning: Self.hasRunningComponent(in: app.url, paths: running),
                sharedWith: shared
            )
        }
    }

    /// Outcome of uninstalling one app.
    public struct UninstallResult: Sendable {
        public let app: InstalledApp
        public var bundleRemoved = false
        /// Why the bundle stayed, when it did and the reason is known.
        public var bundleObstacle: RemovalObstacle?
        /// Refused by `PathGuard`: escalating would not help, because the
        /// administrator path checks the same guard.
        public var bundleBlocked = false
        /// The path no longer names the bundle selected by the scan; rescan before retrying.
        public var bundleChanged = false
        /// Still running after being asked to quit; nothing was deleted.
        public var stillRunning = false
        /// How the administrator step ended for this app, when it had one.
        public var escalation: EscalationOutcome?
        public var associatedRemoved = 0
        /// Support files that stayed although the bundle went.
        public var associatedFailed: [URL] = []
        public var associatedObstacles: [URL: RemovalObstacle] = [:]
        /// Data entries retained because their scan-time identities no longer match.
        public var associatedChanged: [URL] = []
        /// The associated files were left alone because another copy of the
        /// app uses them.
        public var sharedDataKept = false
        public var freedBytes: UInt64 = 0

        public init(app: InstalledApp) { self.app = app }
    }

    /// Uninstalls `apps`: each bundle first, then — only once the bundle is
    /// gone — its associated files, all deleted permanently.
    ///
    /// The order is the safety property. Data removed first and a bundle that
    /// then refused left an installed app without its settings or documents.
    ///
    /// - Running apps are asked to quit and given a few seconds; one that
    ///   stays open is skipped whole.
    /// - Bundles this account cannot remove, and any associated files that
    ///   need root, are deleted as root after **one** administrator password
    ///   for the whole batch, with `adminPrompt` as the dialog's explanation.
    ///   Each app's data is chained after its bundle in that one command.
    /// - An app that shares its bundle id with another installed copy keeps
    ///   its associated files: they belong to both.
    public func uninstall(_ apps: [InstalledApp], adminPrompt: String) async -> [UninstallResult] {
        await uninstall(apps, adminPrompt: adminPrompt) { url in
            let paths = Set(NSWorkspace.shared.runningApplications.compactMap {
                $0.isTerminated ? nil : $0.bundleURL?.standardizedFileURL.path
            })
            if Self.hasRunningComponent(in: url, paths: paths) { return true }
            return DeletionService.isBundleRunning(url)
        }
    }

    func uninstall(_ apps: [InstalledApp], adminPrompt: String,
                   applicationRoots: [URL] = appRoots(includingSystem: true),
                   bundleIsRunning: @Sendable (URL) -> Bool?) async -> [UninstallResult] {
        var results = apps.map(UninstallResult.init(app:))
        invalidateBundleIDCache()
        let checks = await check(apps)
        let currentIDs = installedBundleIDs()

        // 1. Quit what is running. A bundle removed under a running app is
        //    rewritten by that app on quit: its settings and caches come back.
        for (index, app) in apps.enumerated() where app.removalIdentity?.matches(app.url) != true
            || Self.uninstallableBundleInfo(at: app.url) == nil {
            results[index].bundleChanged = true
            results[index].bundleObstacle = .changedSinceScan
        }
        let toQuit = checks.enumerated().filter {
            $0.element.isRunning && !results[$0.offset].bundleChanged
        }.map(\.offset)
        if !toQuit.isEmpty {
            let stillOpen = await Self.quit(toQuit.map { apps[$0].url })
            for index in toQuit where Self.hasRunningComponent(in: apps[index].url, paths: stillOpen) {
                results[index].stillRunning = true
            }
        }

        func associated(_ index: Int, keepNameMatchedData: Bool) -> [URL] {
            guard checks[index].sharedWith == nil, !keepNameMatchedData else { return [] }
            // Presence is tested with lstat: a dangling symlink still has to go.
            let app = apps[index]
            return app.associatedFiles.filter { file in
                guard !Self.preservesSharedData(at: file.url, type: file.type) else { return false }
                guard Self.scriptOwnerMatches(file.url, bundleID: app.bundleIdentifier) else { return false }
                guard let bid = app.bundleIdentifier?.lowercased(), !bid.isEmpty else {
                    return file.url.lastPathComponent.lowercased() == app.url.deletingPathExtension().lastPathComponent.lowercased()
                }
                let name = Self.groupMatchName(file.url.lastPathComponent)
                return !Self.ownedByAnotherApp(name, bundleID: bid, bundle: app.url, installed: currentIDs)
            }.map(\.url).filter { !RemovalCheck.isMissing($0) }
        }

        // 2. Bundles this account can remove, then their data.
        var adminGroups: [[URL]] = []
        var adminOwner: [Int] = []          // app index for each admin group
        var adminBundles: Set<URL> = []
        var identities: [URL: RemovalIdentity] = [:]
        for app in apps {
            identities[app.url] = app.removalIdentity
            for file in app.associatedFiles { identities[file.url] = file.removalIdentity }
        }
        for (index, app) in apps.enumerated() where !results[index].stillRunning && !results[index].bundleChanged {
            let name = app.url.deletingPathExtension().lastPathComponent
            let keepNameMatchedData = (app.bundleIdentifier ?? "").isEmpty && !app.associatedFiles.isEmpty
                && Self.otherNameOwner(named: name, outside: app.url, in: Self.installedNameOwners(in: applicationRoots))
            results[index].sharedDataKept = (checks[index].sharedWith != nil && !app.associatedFiles.isEmpty)
                || keepNameMatchedData
                || app.associatedFiles.contains { Self.preservesSharedData(at: $0.url, type: $0.type) }
            guard app.removalIdentity?.matches(app.url) == true, Self.uninstallableBundleInfo(at: app.url) != nil else {
                results[index].bundleChanged = true
                results[index].bundleObstacle = .changedSinceScan
                continue
            }
            if PathGuard.reject(app.url) != nil {
                Log.error("PathGuard refused uninstalling \(app.url.path)")
                results[index].bundleBlocked = true
                continue
            }
            if RemovalCheck.deleteObstacle(at: app.url) == .needsAdmin {
                adminGroups.append([app.url] + associated(index, keepNameMatchedData: keepNameMatchedData))
                adminOwner.append(index)
                adminBundles.insert(app.url)
                continue
            }
            var activity: Bool? = false
            let bundle = DeletionService.delete([app.url], knownSizes: [app.url: app.size],
                                                validationObstacle: .changedSinceScan) {
                guard app.removalIdentity?.matches($0) == true else { return false }
                activity = bundleIsRunning($0)
                return activity == false && Self.uninstallableBundleInfo(at: $0) != nil
                    && app.removalIdentity?.matches($0) == true
            }
            if bundle.deleted.isEmpty && bundle.alreadyGone.isEmpty {
                if activity == true {
                    results[index].stillRunning = true
                    continue
                }
                if app.removalIdentity?.matches(app.url) != true || Self.uninstallableBundleInfo(at: app.url) == nil {
                    results[index].bundleChanged = true
                    results[index].bundleObstacle = .changedSinceScan
                    continue
                }
                let obstacle = activity == nil ? .other : bundle.obstacles[app.url]
                if obstacle == .needsAdmin {
                    adminGroups.append([app.url] + associated(index, keepNameMatchedData: keepNameMatchedData))
                    adminOwner.append(index)
                    adminBundles.insert(app.url)
                } else {
                    results[index].bundleObstacle = obstacle
                    results[index].bundleBlocked = !bundle.blocked.isEmpty
                }
                continue
            }
            // A missing path may be an app moved elsewhere. A same-named bundle
            // in the Trash does not establish identity, so it never authorizes data removal.
            guard !bundle.deleted.isEmpty else {
                results[index].bundleChanged = true
                results[index].bundleObstacle = .changedSinceScan
                continue
            }
            results[index].bundleRemoved = true
            results[index].freedBytes += bundle.freedBytes

            let data = associated(index, keepNameMatchedData: keepNameMatchedData)
            let removed = DeletionService.delete(data, knownSizes: Dictionary(
                apps[index].associatedFiles.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a }),
                validationObstacle: .changedSinceScan) { identities[$0]?.matches($0) == true }
            results[index].associatedRemoved = removed.deleted.count + removed.alreadyGone.count
            results[index].freedBytes += removed.freedBytes
            let needRoot = removed.failed.filter {
                removed.obstacles[$0] == .needsAdmin && DeletionService.administratorTarget(for: $0) != nil
            }
            results[index].associatedFailed = (removed.failed + removed.blocked).filter { !needRoot.contains($0) }
            results[index].associatedObstacles = removed.obstacles
            results[index].associatedChanged = removed.failed.filter { identities[$0]?.matches($0) != true }
            for url in needRoot {
                adminGroups.append([url])
                adminOwner.append(index)
            }
        }

        // 3. Everything that needs root, under one password.
        if !adminGroups.isEmpty {
            let groups = adminGroups
            let scanIdentities = identities
            let bundles = adminBundles
            let measured = Dictionary(groups.flatMap { $0 }.map {
                ($0, (try? FileManager.default.allocatedSize(of: URL(fileURLWithPath: $0.path), reclaiming: true)) ?? 0)
            }, uniquingKeysWith: { a, _ in a })
            let admin = await Task.detached(priority: .userInitiated) {
                DeletionService.deleteAsAdministrator(groups, prompt: adminPrompt, identities: scanIdentities,
                                                      appBundles: bundles)
            }.value
            let removed = Set(admin.removed)
            for (group, index) in zip(adminGroups, adminOwner) {
                results[index].escalation = admin.outcome
                guard let head = group.first else { continue }
                let isBundle = head == apps[index].url
                if isBundle {
                    if removed.contains(head) {
                        results[index].bundleRemoved = true
                        results[index].freedBytes += measured[head] ?? 0
                    } else {
                        results[index].stillRunning = admin.running.contains(head)
                        results[index].bundleChanged = admin.changed.contains(head)
                        results[index].bundleObstacle = admin.obstacles[head] ?? .needsAdmin
                        results[index].bundleBlocked = admin.refused.contains(head)
                    }
                }
                let data = isBundle ? Array(group.dropFirst()) : group
                results[index].associatedChanged += data.filter { admin.changed.contains($0) }
                let gone = data.filter { removed.contains($0) }
                results[index].associatedRemoved += gone.count
                results[index].freedBytes += gone.reduce(UInt64(0)) { $0 + (measured[$1] ?? 0) }
                // An app that stayed installed keeps its data on purpose; only
                // data whose bundle went counts as a failure.
                if !isBundle || removed.contains(head) {
                    for url in data where !removed.contains(url) {
                        results[index].associatedFailed.append(url)
                        results[index].associatedObstacles[url] = admin.obstacles[url] ?? .other
                    }
                }
            }
        }

        if results.contains(where: \.bundleRemoved) { invalidateBundleIDCache() }
        return results
    }

    /// Standardized paths of the app bundles running right now, this app's
    /// own excluded: asking itself to quit would end the uninstall it is
    /// running. Its bundle can go while it runs; it stays in memory until quit.
    @MainActor
    private static func runningBundlePaths() -> Set<String> {
        let own = Bundle.main.bundleURL.standardizedFileURL.path
        return Set(NSWorkspace.shared.runningApplications.compactMap {
            $0.bundleURL?.standardizedFileURL.path
        }).subtracting([own])
    }

    /// Asks the apps at `bundles` to quit, the way ⌘Q does, and waits up to
    /// eight seconds. Returns the standardized paths of those still running —
    /// one may be showing an unsaved-changes sheet, which is the user's call.
    @MainActor
    private static func quit(_ bundles: [URL]) async -> Set<String> {
        let paths = Set(bundles.map { $0.standardizedFileURL.path })
        func running() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter {
                guard let url = $0.bundleURL else { return false }
                return paths.contains(where: { PathGuard.isUnder(url.standardizedFileURL.path, $0) })
                    && !$0.isTerminated
            }
        }
        for app in running() { app.terminate() }
        for _ in 0..<40 {
            if running().isEmpty { return [] }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return Set(running().compactMap { $0.bundleURL?.standardizedFileURL.path })
    }

    /// Another copy of `app` that LaunchServices knows, still on disk and not
    /// in the Trash — Xcode next to Xcode-beta, or a second copy in
    /// ~/Applications. Both read and write the same `~/Library` entries, which
    /// are named after the shared bundle id.
    private nonisolated static func otherCopy(of app: InstalledApp) -> URL? {
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return nil }
        return registeredCopies(of: bundleID, outside: app.url).first
    }

    nonisolated static func hasRunningComponent(in bundle: URL, paths: Set<String>) -> Bool {
        let root = bundle.standardizedFileURL.path
        return paths.contains { PathGuard.isUnder($0, root) }
    }
}
