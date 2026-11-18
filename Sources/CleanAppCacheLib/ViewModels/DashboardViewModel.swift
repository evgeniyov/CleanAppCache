import Foundation
import SwiftUI

@MainActor
public final class DashboardViewModel: ObservableObject {
    @Published public var scanResult: ScanResult? {
        didSet { updateExcludedItems() }
    }
    @Published public var isScanning = false
    @Published public var selectedItems: Set<UUID> = []
    @Published private(set) var excludedPaths: [String]
    @Published private(set) var excludedItemIDs: Set<UUID> = []
    private let defaults: UserDefaults
    private static let exclusionsKey = "cleanup.excludedPaths"
    @Published public var cleaningProgress: Double = 0
    @Published public var isCleaning = false

    // Progress state
    @Published public var scanProgress: ScanProgress?
    @Published public var scanLog: [String] = []

    /// Whether the result shown is from the cross-launch cache (stale data).
    @Published public var showingCachedResult = false

    /// The cached-result toast fires from the Dashboard's `onAppear`, which
    /// runs on every return to the tab — this lives here (the object that
    /// survives tab switches) so the toast and its VoiceOver announcement post
    /// once per cache load, not once per visit.
    public var cachedResultAnnounced = false

    /// When the displayed result was produced. Needed by the view for both the
    /// "nothing found" state ("checked at …") and the cached-result toast:
    /// `showingCachedResult` alone says the data is stale but not how stale,
    /// so without it a result up to 24 hours old reads as freshly scanned.
    @Published public var lastScanDate: Date?

    /// What a finished clean did, with the two amounts kept apart: bytes
    /// erased for good are free space now, bytes moved to the Trash are not
    /// until the Trash is emptied. A single total would report both as freed.
    public struct CleanupOutcome: Equatable, Sendable {
        public let freedBytes: UInt64
        public let trashedBytes: UInt64

        public init(freedBytes: UInt64, trashedBytes: UInt64) {
            self.freedBytes = freedBytes
            self.trashedBytes = trashedBytes
        }
    }

    /// Set after a clean that removed anything → the view shows the result
    /// panel, which clears it when dismissed. Nothing else clears it, so a
    /// caller reading it back after a clean resets it to nil first.
    @Published public var cleanupOutcome: CleanupOutcome?
    @Published public private(set) var cleanupSkipped = ScanSkipSummary()

    /// The whole account of the last clean, including what failed, for
    /// surfaces that cannot show the window's toasts — the menu-bar popover
    /// has no toast overlay, and with the window closed an Undo posted there
    /// reached no one.
    public struct CleanReport: Sendable {
        public let trashedBytes: UInt64
        public let erasedBytes: UInt64
        public let cleanedCount: Int
        public let alreadyGoneCount: Int
        public let failedCount: Int
        public let trashed: [TrashService.Trashed]
        /// The History record, so an Undo from another surface can correct it.
        public let historyRecord: UUID?
    }

    public private(set) var lastCleanReport: CleanReport?

    private let scanner: any ScannerProtocol
    private let scanCacheDirectory: URL
    private var scanGeneration = UUID()
    private var scanTask: Task<Void, Never>?

    // MARK: - Init

    /// Injectable init for testing; defaults to the shared Scanner singleton.
    ///
    /// `loadCache` exists because the app is not sandboxed: a test process
    /// reads the *user's* real `scan_cache.json`, so any assertion about a
    /// freshly constructed view model would pass on CI and fail on a machine
    /// where the app has been run.
    public init(scanner: any ScannerProtocol = Scanner.shared, loadCache: Bool = true,
                cacheDirectory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.excludedPaths = defaults.stringArray(forKey: Self.exclusionsKey) ?? []
        self.scanner = scanner
        self.scanCacheDirectory = cacheDirectory ?? AppPaths.support
        if loadCache { loadScanCache() }
    }

    // MARK: - Scan lifecycle

    /// A rescan asked for while one was running — after a clean or an Undo.
    /// Dropping it left the list showing items measured before they moved.
    private var rescanRequested = false

    public func startScan() {
        // A scan during a clean would list items the clean is about to move;
        // the clean rescans when it ends.
        guard !isCleaning else { return }
        guard !isScanning else { rescanRequested = true; return }
        rescanRequested = false

        // Cancel any in-flight scan. Only the task is cancelled here: signalling
        // the actor as well raced with the scan we are about to start, because
        // the two messages arrive in an unspecified order and the cancellation
        // could land in the middle of the new scan.
        scanTask?.cancel()

        scanGeneration = UUID()
        let generation = scanGeneration
        isScanning = true
        showingCachedResult = false
        scanResult = nil
        selectedItems.removeAll()
        scanLog.removeAll()
        scanProgress = nil

        // Swift 6: [weak self] prevents the task from keeping the VM alive.
        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await scanner.performFullScan(progressHandler: { [weak self] progress in
                    // Scanner calls back from its own actor; hop to MainActor.
                    Task { @MainActor [weak self] in
                        guard let self, self.scanGeneration == generation, self.isScanning else { return }
                        self.scanProgress = progress
                        if !progress.currentPath.isEmpty {
                            self.scanLog.append("Scanning \(progress.currentCategory.rawValue): \(progress.currentPath)")
                            if self.scanLog.count > 50 {
                                self.scanLog.removeFirst(self.scanLog.count - 50)
                            }
                        }
                    }
                })

                guard !Task.isCancelled, self.scanGeneration == generation else { return }
                self.scanResult = result
                self.lastScanDate = Date()
                self.selectSafe()
                self.scanLog.append("Scan complete in \(String(format: "%.1f", result.duration))s")
                self.saveScanCache(result)
            } catch {
                guard !Task.isCancelled, self.scanGeneration == generation else { return }
                // Surfaced as a toast: a failure stored only in view-model
                // state nobody reads would make a scan that threw go quiet.
                ToastCenter.shared.error(Localizer.shared.s("cleanup.scanFailed"),
                                         error.localizedDescription)
            }
            self.isScanning = false
            self.scanProgress = nil
            if self.rescanRequested { self.startScan() }
        }
    }

    public func cancelScan() {
        scanGeneration = UUID()
        rescanRequested = false
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        scanProgress = nil
        // The structured scan workers inherit task cancellation. An unscoped
        // actor message could arrive after a replacement scan has started.
    }

    // MARK: - Selection helpers

    func alwaysSkip(_ url: URL) {
        guard !isCleaning else { return }
        let path = url.standardizedFileURL.path
        guard !excludedPaths.contains(path) else { return }
        excludedPaths.append(path)
        exclusionsChanged()
    }

    func removeExclusion(_ path: String) {
        guard !isCleaning else { return }
        excludedPaths.removeAll { $0 == path }
        exclusionsChanged()
    }

    private func exclusionsChanged() {
        defaults.set(excludedPaths, forKey: Self.exclusionsKey)
        updateExcludedItems()
    }

    private func updateExcludedItems() {
        guard let result = scanResult, !excludedPaths.isEmpty else {
            excludedItemIDs = []
            return
        }
        let protected = Set(excludedPaths.flatMap { path in
            [path.lowercased(), URL(fileURLWithPath: path).resolvingSymlinksInPath().path.lowercased()]
        })
        excludedItemIDs = Set(result.items.filter { item in
            let url = item.url.standardizedFileURL
            let spellings = [url.path.lowercased(), url.resolvingSymlinksInPath().path.lowercased()]
            // Excluding a child also protects a candidate that would remove its entire parent.
            return spellings.contains { path in
                protected.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
            }
        }.map(\.id))
        selectedItems.subtract(excludedItemIDs)
    }

    var cleanableItems: [CleanableItem] {
        scanResult?.items.filter { !excludedItemIDs.contains($0.id) } ?? []
    }

    var displayedSkipSummary: ScanSkipSummary {
        var summary = scanResult?.skipped ?? ScanSkipSummary()
        for item in scanResult?.items ?? [] where excludedItemIDs.contains(item.id) {
            summary.record(item.url, category: item.category, reason: .userExcluded)
        }
        return summary
    }

    public func toggleSelection(for item: CleanableItem) {
        guard !excludedItemIDs.contains(item.id) else { return }
        if selectedItems.contains(item.id) {
            selectedItems.remove(item.id)
        } else {
            selectedItems.insert(item.id)
        }
    }

    public func selectAll() {
        selectedItems = Set(cleanableItems.map(\.id))
    }

    /// True when the selection contains Trash contents, which are erased rather
    /// than moved to the Trash. The confirmation wording depends on it.
    public var selectionIncludesTrash: Bool {
        guard let result = scanResult else { return false }
        return result.items.contains { $0.category == .trash && selectedItems.contains($0.id) }
    }

    /// True when the selection reaches into the system's folders
    /// (`/Library/Caches`, `/var/log`, `/tmp`), where most entries belong to
    /// root and go to the Trash only through Finder and a password. The
    /// confirmation says so before the dialog appears.
    public var selectionReachesSystemFolders: Bool {
        guard let result = scanResult else { return false }
        let uid = getuid()
        return result.items.contains { item in
            guard selectedItems.contains(item.id) else { return false }
            if Self.systemRoots.contains(where: { item.url.path.hasPrefix($0) }) { return true }
            // Something another account owns in the Trash (a bundle Finder
            // moved there after a password) is erased as root.
            var st = stat()
            return item.category == .trash && lstat(item.url.path, &st) == 0 && st.st_uid != uid
        }
    }

    private static let systemRoots = [
        "/Library/Caches/", "/var/log/", "/private/var/log/", "/tmp/", "/private/tmp/"
    ]

    /// Bytes of the selection that live in the Trash and are therefore erased
    /// outright. The warning has to name the amount — "part of this is
    /// permanent" is not something a user can weigh.
    public var selectedTrashSize: UInt64 {
        guard let result = scanResult else { return 0 }
        return result.items
            .filter { $0.category == .trash && selectedItems.contains($0.id) }
            .reduce(0) { $0 &+ $1.size }
    }

    public var formattedSelectedTrashSize: String {
        Fmt.bytes(Int64(selectedTrashSize))
    }

    public func deselectAll() {
        selectedItems.removeAll()
    }

    /// Selects only items in categories that are safe to clean by default.
    public func selectSafe() {
        selectedItems = Set(cleanableItems.filter(\.autoSelect).map(\.id))
    }

    /// Toggles selection of every item within a category.
    public func toggleCategory(_ category: ScanCategory) {
        guard let result = scanResult else { return }
        let ids = result.items(for: category).map(\.id).filter { !excludedItemIDs.contains($0) }
        guard !ids.isEmpty else { return }
        if ids.allSatisfy({ selectedItems.contains($0) }) {
            ids.forEach { selectedItems.remove($0) }
        } else {
            ids.forEach { selectedItems.insert($0) }
        }
    }

    public func isCategoryFullySelected(_ category: ScanCategory) -> Bool {
        guard let result = scanResult else { return false }
        let ids = result.items(for: category).map(\.id).filter { !excludedItemIDs.contains($0) }
        return !ids.isEmpty && ids.allSatisfy { selectedItems.contains($0) }
    }

    public func categoryHasItems(_ category: ScanCategory) -> Bool {
        guard let result = scanResult else { return false }
        return !result.items(for: category).isEmpty
    }

    public var selectedSize: UInt64 {
        guard let result = scanResult else { return 0 }
        return result.items
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    public var formattedSelectedSize: String {
        Fmt.bytes(Int64(selectedSize))
    }

    // MARK: - Cleaning

    /// A confirmation authorizes one set from one scan, even when another
    /// surface changes the shared selection while the dialog is open.
    public struct CleanupSelection: Identifiable, Sendable {
        struct CategorySummary: Identifiable {
            let category: ScanCategory
            let count: Int
            let bytes: UInt64
            var id: ScanCategory { category }
        }

        public let id = UUID()
        fileprivate let items: [CleanableItem]
        fileprivate let generation: UUID
        public let reachesSystemFolders: Bool
        public var count: Int { items.count }
        public var size: UInt64 { items.reduce(0) { $0 &+ $1.size } }
        public var includesTrash: Bool { items.contains { $0.category == .trash } }

        var categorySummaries: [CategorySummary] {
            let grouped = Dictionary(grouping: items, by: \.category)
            return ScanCategory.allCases.compactMap { category in
                guard let items = grouped[category] else { return nil }
                return CategorySummary(category: category, count: items.count,
                                       bytes: items.reduce(0) { $0 &+ $1.size })
            }
        }
    }

    public func prepareCleanup(safeOnly: Bool = false) -> CleanupSelection? {
        guard !showingCachedResult else {
            ToastCenter.shared.show(Toast(style: .info, title: Localizer.shared.s("cleanup.refreshBeforeCleaning")))
            startScan()
            return nil
        }
        guard !isCleaning, !isScanning, scanResult != nil else { return nil }
        updateExcludedItems()
        let items = cleanableItems.filter { safeOnly ? $0.autoSelect : selectedItems.contains($0.id) }
        guard !items.isEmpty else { return nil }
        let uid = getuid()
        let reachesSystemFolders = items.contains { item in
            if Self.systemRoots.contains(where: { item.url.path.hasPrefix($0) }) { return true }
            var st = stat()
            return item.category == .trash && lstat(item.url.path, &st) == 0 && st.st_uid != uid
        }
        return CleanupSelection(items: items, generation: scanGeneration,
                                reachesSystemFolders: reachesSystemFolders)
    }

    private enum CleanupAttempt: Sendable {
        case alreadyGone
        case skipped(ScanSkipReason)
        case trashed(TrashService.Result)
        case erased(DeletionService.Result)
    }

    /// Moves every selected item to the Trash, except items of the Trash
    /// category: their contents are already in the Trash, so they are erased
    /// for good, and only that part frees space immediately. Returns whether a clean actually ran — a caller that raced the reentry
    /// guard (the menu-bar quick clean against the window's dialog) must not
    /// announce a completion that never happened.
    @discardableResult
    public func cleanSelectedItems(selection: CleanupSelection? = nil) async -> Bool {
        guard let prepared = selection ?? prepareCleanup() else { return false }
        let identities = Dictionary(prepared.items.compactMap { item in
            item.removalIdentity.map { (item.url, $0) }
        }, uniquingKeysWith: { first, _ in first })
        return await cleanSelectedItems(
            selection: prepared,
            trash: { url in
                TrashService.trash([url], validationObstacle: .changedSinceScan) {
                    identities[$0]?.matches($0) == true
                }
            },
            retryTrash: { urls in
                await TrashService.trashEscalating(urls, validationObstacle: .changedSinceScan) {
                    identities[$0]?.matches($0) == true
                }
            }
        )
    }

    func cleanSelectedItems(selection: CleanupSelection? = nil,
                            trash: @escaping @Sendable (URL) -> TrashService.Result,
                            retryTrash: ([URL]) async -> TrashService.Result) async -> Bool {
        // Reentry guard: the window's confirmation dialog and the menu-bar
        // quick clean share this view model, and each checks `isCleaning` only
        // before its own await — a dialog left open bypasses that check once a
        // clean starts. @MainActor makes this check-then-set atomic.
        guard !isCleaning, !isScanning else { return false }
        guard !showingCachedResult else {
            ToastCenter.shared.show(Toast(style: .info, title: Localizer.shared.s("cleanup.refreshBeforeCleaning")))
            startScan()
            return false
        }
        guard let result = scanResult else { return false }
        updateExcludedItems()
        let itemsToClean: [CleanableItem]
        if let selection {
            let currentIDs = Set(cleanableItems.map(\.id))
            guard selection.generation == scanGeneration,
                  selection.items.allSatisfy({ currentIDs.contains($0.id) }) else {
                ToastCenter.shared.error(Localizer.shared.s("cleanup.selectionChanged"))
                return false
            }
            itemsToClean = selection.items
        } else {
            itemsToClean = cleanableItems.filter { selectedItems.contains($0.id) }
        }
        guard !itemsToClean.isEmpty else { return false }

        isCleaning = true
        cleanupSkipped = ScanSkipSummary()
        cleaningProgress = 0
        let total = Double(itemsToClean.count)
        // The per-item pause only exists to animate the progress bar. On large
        // batches it would add real latency (1000 items ≈ 20 s of pure sleep),
        // so pace only small batches and let big ones delete at full speed.
        let perItemDelay: UInt64 = itemsToClean.count <= 60 ? 20_000_000 : 0
        // Two counters, because the two paths are not equivalent: `erasedBytes`
        // is gone for good, `trashedBytes` is what Undo can actually bring back.
        // Reporting the sum as recoverable promised more than Undo delivers.
        var erasedBytes: UInt64 = 0
        var trashedBytes: UInt64 = 0
        var deletedCount = 0
        var alreadyGoneCount = 0
        var blockedCount = 0
        var skippedLive = 0
        var trashed: [TrashService.Trashed] = []
        var failed: [URL] = []
        var obstacles: [URL: RemovalObstacle] = [:]
        // Refused for want of rights; retried together after the loop so one
        // password covers the batch.
        var needRootTrash: [URL] = []
        var needRootDelete: [URL] = []
        let sizes = Dictionary(itemsToClean.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
        let categories = Dictionary(itemsToClean.map { ($0.url, $0.category) }, uniquingKeysWith: { a, _ in a })
        let trashIdentities = Dictionary(itemsToClean.compactMap { item in
            item.removalIdentity.map { (item.url, $0) }
        }, uniquingKeysWith: { first, _ in first })

        func recordBlocked(_ urls: [URL]) {
            blockedCount += urls.count
            for url in urls {
                cleanupSkipped.record(url, category: categories[url], reason: .safetyProtected)
            }
        }

        for (index, item) in itemsToClean.enumerated() {
            if Task.isCancelled { break }

            // Off the main actor: the recency walk, the Trash move and a
            // permanent unlink of a multi-GB cache folder all take seconds, which
            // on the main actor beachballs the window with the bar frozen. The
            // awaits also give big batches (perItemDelay == 0) their only
            // suspension points, so the bar actually renders between items.
            let url = item.url
            let window = Scanner.liveWindow(for: item.category)
            let permanent = item.category == .trash
            let identity = item.removalIdentity
            let outcome = await Task.detached(priority: .userInitiated) { () -> CleanupAttempt in
                if RemovalCheck.isMissing(url) { return .alreadyGone }
                if identity?.matches(url) != true {
                    return .erased(DeletionService.Result(
                        deleted: [], failed: [url], obstacles: [url: .changedSinceScan], freedBytes: 0))
                }
                // The result may be hours old (the cross-launch cache): a temp
                // entry that came back to life since is left alone.
                if let reason = Scanner.skipReason(url, minAge: window) {
                    return RemovalCheck.isMissing(url) ? .alreadyGone : .skipped(reason)
                }
                if permanent, DeletionService.administratorTarget(for: url) != nil,
                   RemovalCheck.deleteObstacle(at: url) == .needsAdmin {
                    // Straight to the password: erasing what this account can
                    // first would leave a half-deleted bundle in the Trash if
                    // the password is then refused.
                    return .erased(DeletionService.Result(
                        deleted: [], failed: [url], obstacles: [url: .needsAdmin], freedBytes: 0))
                }
                return permanent
                    ? .erased(DeletionService.delete([url], knownSizes: sizes,
                                                     validationObstacle: .changedSinceScan) {
                        identity?.matches($0) == true
                    })
                    : .trashed(trash(url))
            }.value

            switch outcome {
            case .alreadyGone:
                alreadyGoneCount += 1
            case .skipped(let reason):
                cleanupSkipped.record(url, category: item.category, reason: reason)
                if reason == .inUse || reason == .recent { skippedLive += 1 }
                else { blockedCount += 1 }
            case .erased(let r):
                if !r.deleted.isEmpty {
                    erasedBytes += r.freedBytes; deletedCount += r.deleted.count
                } else if !r.alreadyGone.isEmpty {
                    alreadyGoneCount += r.alreadyGone.count
                } else if !r.blocked.isEmpty {
                    recordBlocked(r.blocked)
                } else if r.obstacles[url] == .needsAdmin, DeletionService.administratorTarget(for: url) != nil {
                    needRootDelete.append(url)
                } else {
                    failed.append(url); obstacles[url] = r.obstacles[url]
                }
            case .trashed(let r):
                if r.count > 0 {
                    trashedBytes += r.freedBytes; deletedCount += r.count
                    trashed.append(contentsOf: r.trashed)
                } else if !r.alreadyGone.isEmpty {
                    alreadyGoneCount += r.alreadyGone.count
                } else if !r.blocked.isEmpty {
                    recordBlocked(r.blocked)
                } else if r.obstacles[url] == .needsAdmin {
                    needRootTrash.append(url)
                } else {
                    failed.append(url); obstacles[url] = r.obstacles[url]
                }
            }

            cleaningProgress = Double(index + 1) / total
            if perItemDelay > 0 { try? await Task.sleep(nanoseconds: perItemDelay) }
        }

        // What needs an administrator: `/Library/Caches`, `/var/log` and root's
        // files in `/tmp` go to the Trash through Finder, which asks for the
        // password; root-owned items already in the Trash (an app bundle
        // Finder moved there) are erased as root after one password.
        let loc = Localizer.shared
        var escalation: EscalationOutcome?
        if !needRootTrash.isEmpty {
            let unchanged = needRootTrash.filter { url in
                if RemovalCheck.isMissing(url) { alreadyGoneCount += 1; return false }
                guard trashIdentities[url]?.matches(url) == true else {
                    failed.append(url); obstacles[url] = .changedSinceScan
                    return false
                }
                return true
            }
            let r = unchanged.isEmpty ? TrashService.Result(trashed: [], failed: [], freedBytes: 0)
                : await retryTrash(unchanged)
            trashedBytes += r.freedBytes
            deletedCount += r.count
            alreadyGoneCount += r.alreadyGone.count
            trashed.append(contentsOf: r.trashed)
            recordBlocked(r.blocked)
            failed += r.failed
            for url in r.failed { obstacles[url] = r.obstacles[url] }
            escalation = r.escalation
        }
        if !needRootDelete.isEmpty {
            let r = await DeletionService.deleteEscalating(
                needRootDelete, knownSizes: sizes, prompt: loc.s("cleanup.adminPrompt"), identities: trashIdentities)
            erasedBytes += r.freedBytes
            deletedCount += r.deleted.count
            alreadyGoneCount += r.alreadyGone.count
            recordBlocked(r.blocked)
            // The elevated result can list a refusal in both arrays.
            let blocked = Set(r.blocked)
            failed += r.failed.filter { !blocked.contains($0) }
            for url in r.failed { obstacles[url] = r.obstacles[url] }
            escalation = escalation ?? r.escalation
        }

        cleaningProgress = 1.0

        // Expire cached sizes for the folders that just shrank so the Storage
        // tab doesn't keep showing pre-cleanup numbers.
        await StorageManager.shared.invalidate(deleted: itemsToClean.map(\.url))

        let freed = erasedBytes + trashedBytes
        let selectedByCategory = Dictionary(grouping: itemsToClean, by: \.category)
        let movedByCategory = Dictionary(grouping: trashed) { categories[$0.original] }
        let categoryReports = ScanCategory.allCases.compactMap { category -> CleanupRecord.Report.Category? in
            guard let selected = selectedByCategory[category] else { return nil }
            if category == .trash {
                return .init(category: category, selected: selected.count,
                             removed: deletedCount - trashed.count, bytes: erasedBytes)
            }
            let moved = movedByCategory[category] ?? []
            return .init(category: category, selected: selected.count, removed: moved.count,
                         bytes: moved.reduce(0) { $0 &+ $1.movedBytes })
        }
        let failureCounts = failed.reduce(into: [RemovalObstacle: Int]()) { counts, url in
            counts[obstacles[url] ?? .other, default: 0] += 1
        }
        var reportSkips = cleanupSkipped.counts
        let excludedCount = result.items.count { excludedItemIDs.contains($0.id) }
        if excludedCount > 0 { reportSkips[.userExcluded] = excludedCount }
        let report = CleanupRecord.Report(
            categories: categoryReports, skipped: reportSkips, failed: failureCounts,
            alreadyGone: alreadyGoneCount,
            notAttempted: max(0, itemsToClean.count - deletedCount - alreadyGoneCount - cleanupSkipped.totalCount - failed.count))
        let record = CleanupHistory.shared.log(.smartCleanup, items: deletedCount,
                                               freedBytes: erasedBytes, trashedBytes: trashedBytes,
                                               report: report)

        if !trashed.isEmpty {
            let captured = trashed
            let r = TrashService.Result(trashed: captured, failed: [], freedBytes: trashedBytes)
            TrashService.presentToast(r) { [weak self] in
                let n = TrashService.restore(captured, recordingUndoOf: record)
                TrashService.presentRestore(n)
                if n > 0 { self?.startScan() }
            }
        } else if deletedCount > 0 {
            ToastCenter.shared.success(
                loc.s("toast.deleted"),
                loc.f("toast.deletedFmt", Fmt.plural("plural.items", deletedCount), Fmt.bytes(Int64(freed)))
            )
        }
        if alreadyGoneCount > 0 {
            ToastCenter.shared.show(Toast(
                style: .info,
                title: loc.f("cleanup.alreadyGoneFmt", Fmt.plural("plural.objects", alreadyGoneCount))
            ))
        }
        if skippedLive > 0 {
            ToastCenter.shared.show(Toast(
                style: .info,
                title: loc.f("cleanup.skippedLiveFmt", Fmt.plural("plural.objects", skippedLive)),
                duration: 6
            ))
        }
        if blockedCount > 0 {
            ToastCenter.shared.error(loc.f("guard.blockedFmt", Fmt.plural("plural.protectedPaths", blockedCount)))
        }
        RemovalReport.present(failed: failed, obstacles: obstacles, escalation: escalation,
                              permanent: failed.allSatisfy { url in
                                  itemsToClean.first { $0.url == url }?.category == .trash })
        lastCleanReport = CleanReport(trashedBytes: trashedBytes, erasedBytes: erasedBytes,
                                      cleanedCount: deletedCount, alreadyGoneCount: alreadyGoneCount,
                                      failedCount: failed.count + blockedCount + skippedLive,
                                      trashed: trashed, historyRecord: record)

        if freed > 0 {
            cleanupOutcome = CleanupOutcome(freedBytes: erasedBytes, trashedBytes: trashedBytes)
        }

        isCleaning = false
        startScan()
        return true
    }

    // MARK: - Cross-launch result cache

    private static let cacheMaxAge: TimeInterval = 86400   // 24 h

    private func cacheFileURL() -> URL? {
        let dir = scanCacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scan_cache.json")
    }

    private func saveScanCache(_ result: ScanResult) {
        guard let url = cacheFileURL() else { return }
        // The Trash and Installers categories are lists of file names the user
        // deleted or downloaded; persisting them writes that inventory to disk
        // and leaves it there long after the Trash itself was emptied. They are
        // also the two cheapest categories to rescan.
        let items = result.items.filter { $0.category != .trash && $0.category != .installers }
        // Totals recomputed over what is actually persisted. Carrying the full
        // scan's numbers would make the sidebar badge and Storage's cleanable
        // card promise gigabytes the restored list can neither show nor clean.
        var categorySizes: [ScanCategory: UInt64] = [:]
        for item in items { categorySizes[item.category, default: 0] &+= item.size }
        let persisted = ScanResult(
            items: items,
            totalSize: items.reduce(UInt64(0)) { $0 &+ $1.size },
            duration: result.duration,
            categorySizes: categorySizes,
            skipped: result.skipped
        )
        let cached = ScanResult.Cached(from: persisted)
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// Deletes the cross-launch scan cache. Public so Settings' "reset caches"
    /// actually clears it; otherwise a stale file sits on disk forever once it
    /// ages out. Returns whether the file is actually
    /// gone: the cache holds file names from the user's Trash and Downloads,
    /// so "reset caches" must not report success over a failed unlink (a
    /// uchg-locked file, a re-permissioned parent).
    @discardableResult
    public func clearScanCache() -> Bool {
        guard let url = cacheFileURL() else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch let error as NSError {
            // Already gone is success, not a failure to report.
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError { return true }
            Log.error("Scan cache removal failed: \(error.localizedDescription)")
            return false
        }
    }

    private func loadScanCache() {
        guard let url = cacheFileURL(),
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(ScanResult.Cached.self, from: data)
        else { return }

        // Expired: delete rather than just ignore. Ignoring left the file — and
        // the file names in it — on disk indefinitely.
        guard Date().timeIntervalSince(cached.savedAt) < Self.cacheMaxAge else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let result = cached.toScanResult()
        scanResult = result
        lastScanDate = cached.savedAt
        selectSafe()
        showingCachedResult = true
        cachedResultAnnounced = false
    }
}
