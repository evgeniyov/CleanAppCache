import Foundation
import AppKit

// MARK: - Orphaned background items
//
// Finds launch agents, daemons and privileged helpers whose owning app is
// gone — the classic "ghost login item" / "deleted process" leftovers that
// standard uninstallers miss. Detection is deliberately conservative (two
// hard rules, Apple items excluded) to avoid false positives:
//   1. the program the plist points to no longer exists, or
//   2. the program lives inside an .app bundle that no longer exists.

public struct OrphanItem: Identifiable, Sendable {
    public enum Scope: String, Sendable {
        case userAgent    // ~/Library/LaunchAgents — trashable without admin
        case globalAgent  // /Library/LaunchAgents
        case daemon       // /Library/LaunchDaemons
        case helper       // /Library/PrivilegedHelperTools
    }
    public enum Reason: String, Sendable {
        case binaryMissing   // program file is gone
        case appMissing      // owning .app bundle is gone
    }

    public var id: String { url.path }
    public let label: String
    public let programPath: String
    /// The artifact itself (plist or helper binary).
    public let url: URL
    public let scope: Scope
    public let reason: Reason
    public let size: UInt64
    /// The item's vendor still has an app installed, so it may be that app's
    /// live helper under a vendor-wide name. Listed for the user to judge,
    /// never selected in bulk.
    public var uncertain = false
    // A path alone cannot authorize removal after the scan.
    var scanIdentity: FileSnapshot? = nil
    var scannedPhysicalURL: URL? = nil
    var scannedParentIdentity: FileSnapshot? = nil

    public var needsAdmin: Bool { scope != .userAgent }
    public var scopeKey: String { "orphan.scope.\(scope.rawValue)" }
    public var reasonKey: String { "orphan.reason.\(reason.rawValue)" }
    public var formattedSize: String {
        Fmt.bytes(Int64(size))
    }
}

public actor OrphanScanner {
    public static let shared = OrphanScanner()
    private init() {}

    public func scan() async -> [OrphanItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        // Helpers are named after their vendor as often as after their app
        // (`us.zoom.ZoomDaemon` for `us.zoom.xos`, `com.docker.vmnetd`), so a
        // prefix of an app id does not find their owner. The inventory holds
        // the helpers apps ship inside their bundles, and the vendors.
        let inventory = await AppManager.shared.installedInventory()

        var items: [OrphanItem] = []

        // Launch agents / daemons (plists).
        let plistDirs: [(URL, OrphanItem.Scope)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), .userAgent),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .globalAgent),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .daemon)
        ]
        for (dir, scope) in plistDirs {
            guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            for url in contents where url.pathExtension == "plist" {
                guard var item = Self.classifyPlist(url: url, scope: scope) else { continue }
                // The program is gone, but a vendor with an app still
                // installed may put it back (Zoom reinstalls its daemon on
                // demand); the job is then not the remains of anything.
                if let vendor = AppManager.vendorToken(of: item.label.lowercased()),
                   inventory.vendors.contains(vendor) {
                    item.uncertain = true
                }
                items.append(item)
            }
        }

        // Privileged helper tools (binaries named by reverse-DNS). Apple provides
        // no removal API — developers routinely leave these behind.
        let helpersDir = URL(fileURLWithPath: "/Library/PrivilegedHelperTools")
        if let helpers = try? fm.contentsOfDirectory(at: helpersDir, includingPropertiesForKeys: nil) {
            for url in helpers {
                if let item = Self.classifyHelper(url: url, inventory: inventory) {
                    items.append(item)
                }
            }
        }

        // User-actionable first, then by label.
        return items.sorted {
            if $0.needsAdmin != $1.needsAdmin { return !$0.needsAdmin }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    // MARK: Classification

    nonisolated static func classifyPlist(url: URL, scope: OrphanItem.Scope) -> OrphanItem? {
        guard let identity = FileSnapshot(at: url), identity.isRegularFile else { return nil }
        let physical = url.standardizedFileURL.resolvingSymlinksInPath()
        let parent = FileSnapshot(at: physical.deletingLastPathComponent())
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let label = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        guard !label.lowercased().hasPrefix("com.apple.") else { return nil }

        var program = (plist["Program"] as? String) ?? ""
        if program.isEmpty,
           let args = plist["ProgramArguments"] as? [String],
           let first = args.first { program = first }
        guard program.hasPrefix("/") else { return nil }

        let reason: OrphanItem.Reason
        if let range = program.range(of: ".app/") {
            // Program inside an app bundle: orphaned when the bundle is gone.
            let appPath = String(program[..<range.lowerBound]) + ".app"
            guard RemovalCheck.isMissing(URL(fileURLWithPath: appPath)) else { return nil }
            reason = .appMissing
        } else {
            // Standalone binary: orphaned when the file is gone. A bare name
            // (`sh`, `python3`) is looked up on launchd's PATH at launch, so
            // a relative `fileExists` says nothing about it.
            guard RemovalCheck.isMissing(URL(fileURLWithPath: program)) else { return nil }
            reason = .binaryMissing
        }

        guard identity.matches(url), physical == url.standardizedFileURL.resolvingSymlinksInPath(),
              parent?.isSameObject(at: physical.deletingLastPathComponent()) == true else { return nil }
        var item = OrphanItem(label: label, programPath: program, url: url,
                              scope: scope, reason: reason, size: allocatedSize(url))
        item.scanIdentity = identity
        item.scannedPhysicalURL = physical
        item.scannedParentIdentity = parent
        return item
    }

    /// Inventory is valid only while the installation state remains unchanged.
    func removalValidator(for items: [OrphanItem]) async -> @Sendable (URL) -> Bool {
        let baseline = Self.installationState()
        await AppManager.shared.invalidateBundleIDCache()
        let inventory = await AppManager.shared.installedInventory()
        return Self.removalValidator(for: items, inventory: inventory, baseline: baseline)
    }

    nonisolated static func removalValidator(
        for items: [OrphanItem], inventory: AppManager.InstalledInventory,
        baseline: InstallationState?,
        readInstallationState: @escaping @Sendable () -> InstallationState? = { installationState() },
        applicationExists: @escaping @Sendable (String) -> Bool = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        },
        jobDirectories: [URL] = defaultJobDirectories
    ) -> @Sendable (URL) -> Bool {
        let selected = Dictionary(items.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        return { url in
            guard let item = selected[url], let baseline,
                  readInstallationState() == baseline else { return false }
            return isStillOrphan(item, inventory: inventory, applicationExists: applicationExists,
                                 jobDirectories: jobDirectories)
        }
    }

    struct InstallationState: Equatable, Sendable {
        var files: [String: FileSnapshot] = [:]
        var runningBundleIDs: Set<String> = []
    }

    /// Only installation metadata is read; app contents are never sized or hashed.
    /// A changed directory invalidates the entire batch, including helpers with vendor-wide names.
    nonisolated static func installationState(
        roots: [URL] = defaultApplicationRoots,
        runningBundleIDs: Set<String> = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
    ) -> InstallationState? {
        let fm = FileManager.default
        var state = InstallationState(runningBundleIDs: runningBundleIDs)
        func record(_ url: URL) -> Bool {
            guard let snapshot = FileSnapshot(at: url) else { return RemovalCheck.isMissing(url) }
            state.files[url.path] = snapshot
            let physical = url.resolvingSymlinksInPath()
            if physical != url {
                guard let target = FileSnapshot(at: physical) else { return false }
                state.files[physical.path] = target
            }
            return true
        }
        func walk(_ directory: URL, depth: Int) -> Bool {
            guard record(directory) else { return false }
            if RemovalCheck.isMissing(directory) { return true }
            guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            else { return false }
            for entry in entries {
                guard record(entry) else { return false }
                if entry.pathExtension.lowercased() == "app" {
                    // Watch bundle metadata and the folders whose embedded ids feed the inventory.
                    for suffix in ["Contents", "Contents/Info.plist", "Info.plist", "Contents/Library",
                                   "Contents/PlugIns", "Contents/Extensions", "Contents/XPCServices",
                                   "Contents/Helpers", "Contents/Frameworks", "Contents/Library/LoginItems",
                                   "Contents/Library/LaunchServices", "Contents/Library/SystemExtensions",
                                   "Contents/Library/QuickLook", "Contents/Library/Spotlight"] {
                        guard record(entry.appendingPathComponent(suffix)) else { return false }
                    }
                } else if depth > 0,
                          (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    guard walk(entry, depth: depth - 1) else { return false }
                }
            }
            return state.files[directory.path]?.matches(directory) == true
        }
        for root in roots {
            guard walk(root, depth: 1) else { return nil }
        }
        return state
    }

    private static let defaultApplicationRoots = [
        URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    ]

    /// The same predicate is usable at the Trash boundary and in scratch-only tests.
    nonisolated static func isStillOrphan(
        _ item: OrphanItem, inventory: AppManager.InstalledInventory,
        applicationExists: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
        jobDirectories: [URL] = defaultJobDirectories
    ) -> Bool {
        guard let identity = item.scanIdentity, identity.isRegularFile,
              identity.matches(item.url),
              let physical = item.scannedPhysicalURL,
              physical == item.url.standardizedFileURL.resolvingSymlinksInPath(),
              item.scannedParentIdentity?.isSameObject(at: physical.deletingLastPathComponent()) == true
        else { return false }
        let current: OrphanItem?
        if item.scope == .helper {
            current = classifyHelper(url: item.url, inventory: inventory,
                                     applicationExists: applicationExists, jobDirectories: jobDirectories)
        } else {
            current = classifyPlist(url: item.url, scope: item.scope)
            guard !isOwned(item.label, inventory: inventory, applicationExists: applicationExists),
                  !plistHasInstalledOwner(item.url, inventory: inventory, applicationExists: applicationExists)
            else { return false }
        }
        guard let current, current.label == item.label, current.programPath == item.programPath,
              current.reason == item.reason, identity.matches(item.url),
              physical == item.url.standardizedFileURL.resolvingSymlinksInPath(),
              item.scannedParentIdentity?.isSameObject(at: physical.deletingLastPathComponent()) == true
        else { return false }
        // A newly installed vendor can own a shared helper under another bundle id.
        if let vendor = AppManager.vendorToken(of: item.label.lowercased()),
           inventory.vendors.contains(vendor), !item.uncertain { return false }
        return true
    }

    nonisolated static func classifyHelper(
        url: URL, inventory: AppManager.InstalledInventory,
        applicationExists: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
        jobDirectories: [URL] = defaultJobDirectories
    ) -> OrphanItem? {
        let name = url.lastPathComponent.lowercased()
        guard name.filter({ $0 == "." }).count >= 2, !name.hasPrefix("com.apple."),
              let identity = FileSnapshot(at: url), identity.isRegularFile else { return nil }
        let physical = url.standardizedFileURL.resolvingSymlinksInPath()
        let parent = FileSnapshot(at: physical.deletingLastPathComponent())
        guard !isOwned(name, inventory: inventory, applicationExists: applicationExists),
              !jobs(referencing: url, associatedWithAnyOf: inventory.bundleIDs,
                    directories: jobDirectories, applicationExists: applicationExists),
              identity.matches(url) else { return nil }
        var item = OrphanItem(label: url.lastPathComponent, programPath: url.path,
                              url: url, scope: .helper, reason: .appMissing, size: allocatedSize(url))
        item.scanIdentity = identity
        item.scannedPhysicalURL = physical
        item.scannedParentIdentity = parent
        if let vendor = AppManager.vendorToken(of: name), inventory.vendors.contains(vendor) {
            item.uncertain = true
        }
        return item
    }

    nonisolated private static func isOwned(
        _ label: String, inventory: AppManager.InstalledInventory, applicationExists: (String) -> Bool
    ) -> Bool {
        let name = label.lowercased()
        if inventory.bundleIDs.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) { return true }
        var prefix = name
        while prefix.contains(".") {
            if applicationExists(prefix) { return true }
            guard let dot = prefix.lastIndex(of: ".") else { break }
            prefix = String(prefix[..<dot])
        }
        return false
    }

    nonisolated private static func plistHasInstalledOwner(
        _ url: URL, inventory: AppManager.InstalledInventory, applicationExists: (String) -> Bool
    ) -> Bool {
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return true }
        let associated = (dict["AssociatedBundleIdentifiers"] as? [String])
            ?? (dict["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        return associated.contains { inventory.bundleIDs.contains($0.lowercased()) || applicationExists($0) }
    }

    private static let defaultJobDirectories = [
        URL(fileURLWithPath: "/Library/LaunchDaemons"), URL(fileURLWithPath: "/Library/LaunchAgents")
    ]

    /// True when a launchd job in `/Library` runs `helper` and names, in
    /// `AssociatedBundleIdentifiers`, an app that is installed — the way
    /// macOS itself attributes a background item to its app.
    nonisolated private static func jobs(referencing helper: URL, associatedWithAnyOf installed: Set<String>,
                             directories: [URL], applicationExists: (String) -> Bool) -> Bool {
        let fm = FileManager.default
        for directory in directories {
            let dir = directory.path
            guard let plists = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in plists where name.hasSuffix(".plist") {
                guard let dict = NSDictionary(contentsOfFile: dir + "/" + name) as? [String: Any] else { continue }
                let program = (dict["Program"] as? String)
                    ?? (dict["ProgramArguments"] as? [String])?.first
                guard program == helper.path else { continue }
                let associated: [String]
                if let one = dict["AssociatedBundleIdentifiers"] as? String { associated = [one] }
                else { associated = dict["AssociatedBundleIdentifiers"] as? [String] ?? [] }
                if associated.contains(where: { installed.contains($0.lowercased()) || applicationExists($0) }) { return true }
            }
        }
        return false
    }

    nonisolated private static func allocatedSize(_ url: URL) -> UInt64 {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return UInt64(v?.totalFileAllocatedSize ?? v?.fileSize ?? 0)
    }
}
