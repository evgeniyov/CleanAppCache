import Foundation
import AppKit

// MARK: - Leftover models

public struct LeftoverFile: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let locationKey: String   // localization key for the location label
    public let size: UInt64
    var removalIdentity: RemovalIdentity?

    init(url: URL, locationKey: String, size: UInt64, removalIdentity: RemovalIdentity? = nil) {
        self.url = url; self.locationKey = locationKey; self.size = size
        self.removalIdentity = removalIdentity ?? RemovalIdentity(at: url)
    }

    public var formattedSize: String {
        Fmt.bytes(Int64(size))
    }
}

/// All leftover files attributed to one (no-longer-installed) app bundle id.
public struct LeftoverGroup: Identifiable, Sendable {
    public let id: String            // the bundle id key
    public let displayName: String
    public let files: [LeftoverFile]
    public let totalBytes: UInt64
    /// The id's vendor still has an app installed, so these may be that
    /// app's shared components rather than remains. Listed for the user to
    /// judge, never selected in bulk.
    public let uncertain: Bool

    public init(id: String, displayName: String, files: [LeftoverFile],
                totalBytes: UInt64, uncertain: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.files = files
        self.totalBytes = totalBytes
        self.uncertain = uncertain
    }

    public var formattedSize: String {
        Fmt.bytes(Int64(totalBytes))
    }
}

// MARK: - Leftovers manager

public actor LeftoversManager {
    public static let shared = LeftoversManager()
    private init() {}

    private let appManager = AppManager.shared

    /// Locations under ~/Library where app data accumulates. Each entry is keyed
    /// by a bundle id (folder) or a "<bundleid>.<ext>" file.
    private struct Source {
        let url: URL
        let locKey: String
        let stripExtension: Bool   // true for Preferences (*.plist) / savedState
    }

    public func scan() async -> [LeftoverGroup] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lib = home.appendingPathComponent("Library")
        let sources: [Source] = [
            Source(url: lib.appendingPathComponent("Preferences"), locKey: "leftovers.loc.prefs", stripExtension: true),
            Source(url: lib.appendingPathComponent("Caches"), locKey: "leftovers.loc.caches", stripExtension: false),
            Source(url: lib.appendingPathComponent("Application Support"), locKey: "leftovers.loc.appSupport", stripExtension: false),
            Source(url: lib.appendingPathComponent("Containers"), locKey: "leftovers.loc.containers", stripExtension: false),
            Source(url: lib.appendingPathComponent("Saved Application State"), locKey: "leftovers.loc.savedState", stripExtension: true),
            Source(url: lib.appendingPathComponent("HTTPStorages"), locKey: "leftovers.loc.httpStorages", stripExtension: false),
            Source(url: lib.appendingPathComponent("WebKit"), locKey: "leftovers.loc.webKit", stripExtension: false)
        ]

        // What is installed — app ids, the ids of bundles inside them, app
        // names and vendors — so nothing belonging to an installed app is
        // offered as a leftover. No sizing, no associated-file lookup.
        let inventory = await appManager.installedInventory()

        let fm = FileManager.default
        var byBundle: [String: [LeftoverFile]] = [:]
        var uncertainKeys: Set<String> = []

        for source in sources {
            guard let contents = try? fm.contentsOfDirectory(at: source.url, includingPropertiesForKeys: nil) else { continue }
            for url in contents {
                var key = url.lastPathComponent
                if source.stripExtension {
                    key = url.deletingPathExtension().lastPathComponent
                    // saved state files end with ".savedState" → strip that too
                    if key.hasSuffix(".savedState") { key = (key as NSString).deletingPathExtension }
                }
                let verdict = classify(key, inventory: inventory)
                guard verdict != .notLeftover else { continue }
                guard let identity = RemovalIdentity(at: url) else { continue }
                let size = (try? fm.allocatedSize(of: url)) ?? 0
                guard identity.matches(url), identity.object.matches(url) else { continue }
                let bundleKey = key.lowercased()
                if verdict == .uncertain { uncertainKeys.insert(bundleKey) }
                byBundle[bundleKey, default: []].append(
                    LeftoverFile(url: url, locationKey: source.locKey, size: size, removalIdentity: identity)
                )
            }
        }

        return byBundle.map { bundleKey, files in
            let total = files.reduce(UInt64(0)) { $0 + $1.size }
            return LeftoverGroup(id: bundleKey, displayName: friendlyName(bundleKey),
                                 files: files.sorted { $0.size > $1.size }, totalBytes: total,
                                 uncertain: uncertainKeys.contains(bundleKey))
        }
        .filter { $0.totalBytes > 0 }
        .sorted { $0.totalBytes > $1.totalBytes }
    }

    /// A stale result cannot authorize removing a replacement or a reinstalled app's data.
    func removalValidator(for groups: [LeftoverGroup]) async -> @Sendable (URL) -> Bool {
        let baseline = OrphanScanner.installationState()
        await appManager.invalidateBundleIDCache()
        let inventory = await appManager.installedInventory()
        return Self.removalValidator(for: groups, inventory: inventory, baseline: baseline)
    }

    nonisolated static func removalValidator(
        for groups: [LeftoverGroup], inventory: AppManager.InstalledInventory,
        baseline: OrphanScanner.InstallationState?,
        readInstallationState: @escaping @Sendable () -> OrphanScanner.InstallationState? = {
            OrphanScanner.installationState()
        },
        applicationExists: @escaping @Sendable (String) -> Bool = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    ) -> @Sendable (URL) -> Bool {
        let selected = Dictionary(groups.flatMap { group in
            group.files.map { ($0.url, (file: $0, key: group.id, uncertain: group.uncertain)) }
        }, uniquingKeysWith: { first, _ in first })
        return { url in
            guard let candidate = selected[url], let baseline,
                  readInstallationState() == baseline,
                  let identity = candidate.file.removalIdentity,
                  identity.matches(url), identity.object.matches(url) else { return false }
            let verdict = Self.classify(candidate.key, inventory: inventory, applicationExists: applicationExists)
            return verdict == .leftover || (verdict == .uncertain && candidate.uncertain)
        }
    }

    enum Verdict: Equatable {
        case notLeftover
        case leftover
        /// Not installed, but a sibling from the same vendor is.
        case uncertain
    }

    /// Only an id-shaped name that nothing installed claims is a leftover.
    /// Beyond `isLeftoverBundleKey`, a name equal to an installed app's name
    /// is that app's (`Yandex.Disk.2`), and an id whose vendor still has an
    /// app installed is `uncertain`: vendors share components across their
    /// apps (`com.microsoft.office`, `com.blackmagic-design.DaVinciResolve`
    /// next to `…DaVinciResolveLite`).
    func classify(_ key: String, inventory: AppManager.InstalledInventory) -> Verdict {
        Self.classify(key, inventory: inventory)
    }

    nonisolated static func classify(
        _ key: String, inventory: AppManager.InstalledInventory,
        applicationExists: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    ) -> Verdict {
        let lower = key.lowercased()
        if inventory.names.contains(lower) { return .notLeftover }
        guard isLeftoverBundleKey(key, installedIDs: inventory.bundleIDs, applicationExists: applicationExists) else { return .notLeftover }
        let candidate = lower.hasPrefix("group.") ? String(lower.dropFirst("group.".count)) : lower
        if let vendor = AppManager.vendorToken(of: candidate), inventory.vendors.contains(vendor) {
            return .uncertain
        }
        return .leftover
    }

    /// Conservative test: only flag reverse-DNS bundle-id-style names (≥2 dots,
    /// no spaces) that aren't installed and aren't Apple/system components.
    func isLeftoverBundleKey(_ key: String, installedIDs: Set<String>) -> Bool {
        Self.isLeftoverBundleKey(key, installedIDs: installedIDs)
    }

    nonisolated private static func isLeftoverBundleKey(
        _ key: String, installedIDs: Set<String>, applicationExists: (String) -> Bool = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        }
    ) -> Bool {
        let lower = key.lowercased()
        // Must look like a bundle id: at least two dots, only id-safe chars.
        let dots = key.filter { $0 == "." }.count
        guard dots >= 2, !key.contains(" ") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-_")
        guard key.lowercased().unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        // Exclude system / Apple / known-safe namespaces.
        let systemPrefixes = ["com.apple.", "apple.", "group.com.apple.", "org.swift.",
                              "com.google.gsa", "systemgroup."]
        if systemPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }

        // App Groups are shared containers: "group.com.acme.app" holds data
        // belonging to com.acme.app and its extensions.
        var candidate = lower
        if candidate.hasPrefix("group.") { candidate = String(candidate.dropFirst("group.".count)) }

        // installedIDs only walks /Applications, /System/Applications and
        // ~/Applications. An app run from ~/Downloads, the Desktop or an
        // external volume is invisible to it, and its live — possibly running —
        // settings and caches were offered here as remains of an "uninstalled"
        // app. Ask LaunchServices as the fallback, the same lookup
        // PrivacyManager already relies on. The lookup is the expensive half,
        // so the id set is always consulted first.
        func isInstalled(_ id: String) -> Bool {
            installedIDs.contains(id) || applicationExists(id)
        }

        // Installed → not a leftover.
        if isInstalled(candidate) { return false }

        // An exact match is not enough. Extensions, XPC helpers, widgets and
        // cookie stores are named "<installedID>.<suffix>" and never appear in
        // installedIDs themselves — treating them as orphaned data would offer
        // to delete the working state of an app the user still has installed
        // (e.g. ~/Library/Containers/com.microsoft.Outlook.CalendarExtension).
        // Walk the dotted prefixes and bail as soon as an installed app claims one.
        var prefix = candidate
        while let dot = prefix.lastIndex(of: ".") {
            prefix = String(prefix[prefix.startIndex..<dot])
            guard prefix.contains(".") else { break }   // stop before bare "com"
            if isInstalled(prefix) { return false }
        }
        return true
    }

    private func friendlyName(_ bundleKey: String) -> String {
        // "com.google.chrome" → "Chrome"
        let last = bundleKey.split(separator: ".").last.map(String.init) ?? bundleKey
        guard let first = last.first else { return last }
        return first.uppercased() + String(last.dropFirst())
    }
}
