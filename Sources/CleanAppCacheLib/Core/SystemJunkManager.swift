import Foundation
import Darwin

// MARK: - System Junk Entry

public struct SystemJunkEntry: Identifiable, Sendable {

    // MARK: Category

    public enum Category: String, CaseIterable, Sendable {
        case xcodeDerivedData = "xcodeDerivedData"
        case xcodeArchives    = "xcodeArchives"
        case xcodeDeviceLogs  = "xcodeDeviceLogs"
        case iOSBackups       = "iOSBackups"
        case quickLookCache   = "quickLookCache"
        case mailDownloads    = "mailDownloads"
        case brokenDownloads  = "brokenDownloads"

        public var icon: String {
            switch self {
            case .xcodeDerivedData: return "hammer.fill"
            case .xcodeArchives:    return "archivebox.fill"
            case .xcodeDeviceLogs:  return "iphone.and.arrow.forward"
            case .iOSBackups:       return "iphone"
            case .quickLookCache:   return "eye.fill"
            case .mailDownloads:    return "envelope.fill"
            case .brokenDownloads:  return "exclamationmark.circle.fill"
            }
        }

        public var titleKey: String { "systemJunk.\(rawValue).title" }
        public var descKey:  String { "systemJunk.\(rawValue).desc" }

        /// Safe = auto-selected; false = user must explicitly choose.
        public var isSafe: Bool {
            switch self {
            case .xcodeDerivedData, .xcodeDeviceLogs, .quickLookCache: return true
            // Mail Downloads holds attachments the user opened; some are the
            // only local copy. iOS backups are irreplaceable. A paused
            // download is one the user may mean to resume. All stay opt-in.
            case .xcodeArchives, .iOSBackups, .mailDownloads, .brokenDownloads: return false
            }
        }
    }

    // MARK: Fields

    public let id:       UUID
    public let category: Category
    /// Individual files / directories that will be trashed.
    public let urls:      [URL]
    public let totalSize: UInt64
    let removalIdentities: [URL: RemovalIdentity]

    public init(category: Category, urls: [URL], totalSize: UInt64) {
        self.id = UUID()
        self.category = category
        self.urls = urls
        self.totalSize = totalSize
        removalIdentities = urls.reduce(into: [:]) { $0[$1] = RemovalIdentity(at: $1) }
    }

    init(id: UUID = UUID(), category: Category, urls: [URL], totalSize: UInt64,
         removalIdentities: [URL: RemovalIdentity]) {
        self.id = id
        self.category = category
        self.urls = urls
        self.totalSize = totalSize
        self.removalIdentities = removalIdentities
    }

    func matches(_ url: URL) -> Bool { removalIdentities[url]?.matches(url) == true }

    /// The same entry with only the surviving URLs — keeps the row's identity
    /// (and with it the selection) across a partial clean, so a retry is one
    /// click instead of a full rescan.
    public func keeping(urls: [URL], totalSize: UInt64) -> SystemJunkEntry {
        let surviving = Set(urls)
        return SystemJunkEntry(id: id, category: category, urls: urls, totalSize: totalSize,
                               removalIdentities: removalIdentities.filter { surviving.contains($0.key) })
    }

    public var formattedSize: String {
        Fmt.bytes(Int64(totalSize))
    }
}

public struct SystemJunkScanResult: Sendable {
    public let entries: [SystemJunkEntry]
    public let skipped: ScanSkipSummary
}

// MARK: - System Junk Manager

public actor SystemJunkManager {
    public static let shared = SystemJunkManager()
    private init() {}
    private static let downloadActivityWindow: TimeInterval = 600

    // MARK: Scan

    public func scan() async -> [SystemJunkEntry] {
        await scanWithReport().entries
    }

    public func scanWithReport() async -> SystemJunkScanResult {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var entries: [SystemJunkEntry] = []
        var skipped = ScanSkipSummary()

        // Xcode DerivedData — one sub-directory per project
        await add(
            .xcodeDerivedData,
            urls: subdirs(home.appendingPathComponent("Library/Developer/Xcode/DerivedData"), skipped: &skipped),
            to: &entries, skipped: &skipped
        )

        // Xcode Archives — date-grouped folders
        await add(
            .xcodeArchives,
            urls: subdirs(home.appendingPathComponent("Library/Developer/Xcode/Archives"), skipped: &skipped),
            to: &entries, skipped: &skipped
        )

        // Xcode iOS Device Logs
        await add(
            .xcodeDeviceLogs,
            urls: flatContents(home.appendingPathComponent("Library/Developer/Xcode/iOS Device Logs"), skipped: &skipped),
            to: &entries, skipped: &skipped
        )

        // iOS / iPadOS Backups made via Finder
        await add(
            .iOSBackups,
            urls: subdirs(home.appendingPathComponent("Library/Application Support/MobileSync/Backup"), skipped: &skipped),
            to: &entries, skipped: &skipped
        )

        // Quick Look thumbnail caches
        let qlURLs = [
            "Library/Caches/com.apple.QuickLook.thumbnailcache",
            "Library/Caches/com.apple.coreservices.QuickLook"
        ]
        .map { home.appendingPathComponent($0) }
        .filter { url in
            do { _ = try FileManager.default.attributesOfItem(atPath: url.path); return true }
            catch {
                if !Self.isAbsent(error) { skipped.record(url, reason: .unreadable) }
                return false
            }
        }
        await add(.quickLookCache, urls: qlURLs, to: &entries, skipped: &skipped)

        // Mail Downloads (attachments saved by Mail.app)
        await add(
            .mailDownloads,
            urls: flatContents(home.appendingPathComponent(
                "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"), skipped: &skipped),
            to: &entries, skipped: &skipped
        )

        // Broken / incomplete downloads in ~/Downloads and ~/Desktop.
        // A `.crdownload`/`.part` file is exactly what an *in-progress* download
        // looks like, so skip anything written in the last 10 minutes — deleting
        // those would kill an active download. Safari's `.download` is a
        // folder whose own date stays put while the file inside it grows, so
        // the check looks inside.
        let brokenExts: Set<String> = ["crdownload", "part", "download", "aria2"]
        let searchDirs = [home.appendingPathComponent("Downloads"),
                          home.appendingPathComponent("Desktop")]
        let broken: [URL] = searchDirs.flatMap { dir in
            flatContents(dir, skipped: &skipped).filter { url in
                guard brokenExts.contains(url.pathExtension.lowercased()) else { return false }
                if !Self.canMoveToTrash(url, category: .brokenDownloads) {
                    skipped.record(url, reason: .recent)
                    return false
                }
                return true
            }
        }
        await add(.brokenDownloads, urls: broken, to: &entries, skipped: &skipped)

        return SystemJunkScanResult(entries: entries.sorted { $0.totalSize > $1.totalSize }, skipped: skipped)
    }

    // MARK: Clean

    /// Moves each item in the entry to the Trash. The result's `trashed` and
    /// `alreadyGone` are what left the disk — the caller needs them to keep a
    /// partially failed entry alive with only its survivors — and its
    /// `trashed` list is what Undo puts back.
    public func clean(_ entry: SystemJunkEntry) async -> TrashService.Result {
        clean(entry, mover: nil)
    }

    /// `mover` replaces the real Trash so tests can run the same validation
    /// and accounting inside a scratch directory.
    func clean(_ entry: SystemJunkEntry, mover: ((URL) throws -> URL)?) -> TrashService.Result {
        // The caller escalates permission refusals together, in one Finder request.
        let validation: (URL) -> Bool = { url in
            entry.matches(url) && Self.canMoveToTrash(url, category: entry.category) && entry.matches(url)
        }
        let result = mover.map { TrashService.trash(entry.urls, validation: validation, mover: $0) }
            ?? TrashService.trash(entry.urls, validation: validation)
        return Self.classifyChanges(result, entries: [entry])
    }

    /// Preserve the activity diagnosis unless the selected filesystem object changed.
    static func classifyChanges(_ result: TrashService.Result, entries: [SystemJunkEntry]) -> TrashService.Result {
        var obstacles = result.obstacles
        for url in result.validationRejected {
            if entries.contains(where: { $0.urls.contains(url) && !$0.matches(url) }) {
                obstacles[url] = .changedSinceScan
            }
        }
        return TrashService.Result(trashed: result.trashed, failed: result.failed, blocked: result.blocked,
                                   alreadyGone: result.alreadyGone, obstacles: obstacles,
                                   validationRejected: result.validationRejected,
                                   escalation: result.escalation, freedBytes: result.freedBytes)
    }

    static func canMoveToTrash(_ url: URL, category: SystemJunkEntry.Category) -> Bool {
        switch category {
        case .brokenDownloads: return !Scanner.touchedRecently(url, within: downloadActivityWindow)
        case .xcodeDerivedData: return !AppActivityGuard.developerIsInUse(url)
        default: return !AppActivityGuard.cacheIsInUse(url)
        }
    }

    // MARK: Helpers

    private func add(_ category: SystemJunkEntry.Category,
                     urls: [URL],
                     to entries: inout [SystemJunkEntry], skipped: inout ScanSkipSummary) async {
        guard !urls.isEmpty else { return }
        let identities = urls.reduce(into: [URL: RemovalIdentity]()) { $0[$1] = RemovalIdentity(at: $1) }
        let sizes = await StorageManager.shared.bulkDirectorySizes(urls: urls, timeout: 30)
        let measured = urls.filter { sizes[$0.path] != nil && identities[$0]?.matches($0) == true }
        let measuredSet = Set(measured)
        for url in urls where !measuredSet.contains(url) {
            skipped.record(url, reason: .unreadable)
        }
        guard !measured.isEmpty else { return }
        let total = measured.reduce(UInt64(0)) { $0 + (sizes[$1.path] ?? 0) }
        entries.append(SystemJunkEntry(category: category, urls: measured, totalSize: total,
                                       removalIdentities: identities.filter { measuredSet.contains($0.key) }))
    }

    private func subdirs(_ url: URL, skipped: inout ScanSkipSummary) -> [URL] {
        Self.directoryContents(url, directoriesOnly: true, skipped: &skipped)
    }

    private func flatContents(_ url: URL, skipped: inout ScanSkipSummary) -> [URL] {
        Self.directoryContents(url, skipped: &skipped)
    }

    private static func isAbsent(_ error: Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError)
            || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOENT))
    }

    /// A nonexistent optional root is normal; an unreadable one is not empty.
    static func directoryContents(_ url: URL, directoriesOnly: Bool = false,
                                  skipped: inout ScanSkipSummary,
                                  read: (URL) throws -> [URL] = {
                                      try FileManager.default.contentsOfDirectory(at: $0,
                                          includingPropertiesForKeys: [.isDirectoryKey])
                                  }) -> [URL] {
        do {
            let urls = try read(url)
            guard directoriesOnly else { return urls }
            return urls.filter { child in
                do { return try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
                catch { skipped.record(child, reason: .unreadable); return false }
            }
        } catch {
            if !isAbsent(error) { skipped.record(url, reason: .unreadable) }
            return []
        }
    }
}
