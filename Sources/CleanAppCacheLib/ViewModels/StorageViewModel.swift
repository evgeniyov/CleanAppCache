import Foundation
import SwiftUI

@MainActor
public final class StorageViewModel: ObservableObject {
    @Published public var storageInfo: StorageInfo?
    @Published public var breakdown: [StorageBreakdown] = []
    @Published public var isLoading = false
    @Published public var scanLog: [String] = []
    @Published public private(set) var storageMeasuredAt: Date?
    @Published public private(set) var detailMeasuredAt: Date?
    @Published public private(set) var isDetailSnapshotStale = false
    @Published private(set) var hasMeasuredEmptyListing = false
    public var measuredCategoryBytes: UInt64 {
        breakdown.filter { !$0.isResidual }.reduce(0) { value, row in
            let (sum, overflow) = value.addingReportingOverflow(row.bytes)
            return overflow ? UInt64.max : sum
        }
    }
    public var pendingDetailCount: Int {
        detailItems.filter { !browserMeasuredPaths.contains($0.url) || !$0.sizeKnown || $0.isPartial }.count
    }
    public var blockedDetailCount: Int { detailItems.filter { $0.unavailableReason != nil }.count }
    public var canCompareDetailSizes: Bool { !hasPartialDetail && !isDetailSnapshotStale }
    
    // Detail drill-down
    @Published public var selectedBreakdown: StorageBreakdown?
    @Published public var detailItems: [StorageItemDetail] = []
    @Published public var isLoadingDetail = false
    @Published public var isSizingDetail = false
    @Published public var detailPathStack: [String] = []
    /// Currently highlighted item in the right-pane detail panel.
    @Published public var selectedDetailItem: StorageItemDetail? {
        didSet {
            if oldValue?.url != selectedDetailItem?.url { cancelFolderMeasurement() }
        }
    }
    @Published private(set) var folderMeasurement: StorageItemDetail?
    @Published private(set) var isMeasuringFolder = false
    private var folderMeasurementTask: Task<Void, Never>?
    /// Progress counters for the background sizing phase.
    @Published public var sizingCount: Int = 0
    @Published public var sizingTotal: Int = 0
    
    public enum BrowserMode { case category, unassigned, disk }
    @Published public private(set) var browserMode: BrowserMode = .category
    @Published public private(set) var detailErrorKey: String?
    @Published public private(set) var detailScanLimited = false
    @Published private var browserMeasuredPaths: Set<URL> = []
    private let explorer: StorageExplorer
    private var browserSnapshots = StorageBrowserSnapshots()
    private var browserDirectoryIdentity: StorageDirectoryIdentity?
    var externalVolume: StorageVolume? { explorer.volume }
    private var diskRootPath: String { externalVolume?.url.path ?? "/" }
    public var isVirtualRoot: Bool { browserMode == .unassigned && currentDetailPath.isEmpty }
    public func contributesToDetailTotal(_ item: StorageItemDetail) -> Bool {
        browserMeasuredPaths.contains(item.url)
    }
    public var isBrowserAwaitingMeasurement: Bool {
        browserMode != .category && !hasMeasuredEmptyListing && !isSizingDetail &&
            sizingCount == 0 && browserMeasuredPaths.isEmpty &&
            !detailScanLimited && detailErrorKey == nil
    }
    public var measuredDetailBytes: UInt64 {
        detailItems.filter { $0.sizeKnown && browserMeasuredPaths.contains($0.url) }.reduce(0) { value, item in
            let (sum, overflow) = value.addingReportingOverflow(item.size)
            return overflow ? UInt64.max : sum
        }
    }
    public var hasPartialDetail: Bool {
        detailItems.contains { !$0.sizeKnown || $0.isPartial } || isSizingDetail ||
            browserMeasuredPaths.count != detailItems.count
    }

    // Search & filters
    @Published public var searchText = ""
    @Published public var sortMode: SortMode = .sizeDesc
    @Published public var showOnlyFolders = false
    @Published public var minSizeMB: Double = 0
    
    public enum SortMode: String, CaseIterable {
        case sizeDesc = "Size: Large to Small"
        case sizeAsc = "Size: Small to Large"
        case nameAsc = "Name: A to Z"
        case nameDesc = "Name: Z to A"
    }
    
    public var filteredDetailItems: [StorageItemDetail] {
        var items = detailItems
        
        // Search filter
        if !searchText.isEmpty {
            items = items.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        // Folder filter
        if showOnlyFolders {
            items = items.filter { $0.isDirectory }
        }
        
        // Size filter
        let minBytes = UInt64(minSizeMB * 1024 * 1024)
        if minBytes > 0 {
            items = items.filter { !$0.sizeKnown || $0.isPartial || $0.size >= minBytes }
        }
        
        // Unknown sizes form a separate group, rather than masquerading as
        // zero-byte entries. Equal values have a stable alphabetical order.
        let bySize: (StorageItemDetail, StorageItemDetail, Bool) -> Bool = { left, right, descending in
            if left.sizeKnown != right.sizeKnown { return left.sizeKnown }
            if left.size != right.size { return descending ? left.size > right.size : left.size < right.size }
            return left.path.localizedCaseInsensitiveCompare(right.path) == .orderedAscending
        }
        let isDiskRoot = browserMode == .disk && currentDetailPath == diskRootPath
        let byName: (StorageItemDetail, StorageItemDetail, ComparisonResult) -> Bool = { left, right, order in
            if isDiskRoot {
                let leftHidden = left.name.hasPrefix(".")
                let rightHidden = right.name.hasPrefix(".")
                if leftHidden != rightHidden { return !leftHidden }
                if left.isDirectory != right.isDirectory { return left.isDirectory }
            }
            return left.name.localizedStandardCompare(right.name) == order
        }
        switch sortMode {
        case .sizeDesc:
            items.sort { bySize($0, $1, true) }
        case .sizeAsc:
            items.sort { bySize($0, $1, false) }
        case .nameAsc:
            items.sort { byName($0, $1, .orderedAscending) }
        case .nameDesc:
            items.sort { byName($0, $1, .orderedDescending) }
        }
        
        return items
    }
    
    public var currentDetailPath: String {
        detailPathStack.last ?? selectedBreakdown?.path ?? "/"
    }
    
    public var canGoBack: Bool {
        detailPathStack.count > 1
    }
    
    // Cache
    private var detailCache: [String: [StorageItemDetail]] = [:]
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = UUID()

    private let manager: StorageManager
    private var hasLoaded = false
    
    private var invalidationObserver: StorageInvalidationObservation?

    public convenience init(manager: StorageManager = .shared) {
        self.init(manager: manager, explorer: .live)
    }

    init(manager: StorageManager, explorer: StorageExplorer) {
        self.manager = manager
        self.explorer = explorer
        // A cleanup on any other tab expires the manager's caches but not this
        // view model's drill-down cache; without this observer Storage keeps
        // listing files that have already been deleted.
        invalidationObserver = StorageInvalidationObservation(NotificationCenter.default.addObserver(
            forName: .storageCacheInvalidated, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidateDetailState() }
        })
    }

    public func loadStorageInfoIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        loadStorageInfo()
    }
    
    public func reloadStorageInfo() {
        hasLoaded = true
        // Drop drill-down results so a manual rescan reflects post-cleanup state
        // (the manager's size caches are already expired at the delete sites).
        detailCache.removeAll()
        browserSnapshots.entries.removeAll()
        Task {
            await manager.diskCache.clearBrowserSnapshots()
            loadStorageInfo()
        }
    }
    
    private func loadStorageInfo() {
        guard !isLoading else { return }
        isLoading = true
        breakdown = []
        scanLog.removeAll()
        
        Task {
            if let info = await manager.getStorageInfo() {
                self.storageInfo = info
                self.scanLog.append("Total: \(info.formattedTotal)")
                self.scanLog.append("Used: \(info.formattedUsed) (\(Int(info.usedPercent * 100))%)")
                self.scanLog.append("Free: \(info.formattedFree)")
                
                self.scanLog.append("Analyzing directories...")
                let breakdown = await manager.getBreakdown(totalBytes: info.totalBytes, usedBytes: info.usedBytes)
                self.breakdown = breakdown
                self.storageMeasuredAt = Date()
                self.scanLog.append("Done. Found \(breakdown.count) categories.")
            } else {
                self.scanLog.append("Failed to read storage info")
            }
            self.isLoading = false
        }
    }
    
    public func loadDetail(for breakdown: StorageBreakdown) {
        detailTask?.cancel()
        detailTask = nil
        browserMode = .category
        detailErrorKey = nil
        detailScanLimited = false
        selectedBreakdown = breakdown
        detailPathStack = [breakdown.path]
        detailItems = []
        browserMeasuredPaths.removeAll()
        selectedDetailItem = nil
        searchText = ""
        sortMode = .sizeDesc
        showOnlyFolders = false
        minSizeMB = 0
        guard !breakdown.isResidual else {
            detailGeneration = UUID()
            isLoadingDetail = false
            isSizingDetail = false
            sizingCount = 0
            sizingTotal = 0
            return
        }
        loadCurrentPath()
    }

    /// A sheet owns its navigation and cancellation. Its results never replace
    /// the category preview that remains visible in the parent window.
    func makeDetailBrowser() -> StorageViewModel {
        let browser = StorageViewModel(manager: manager, explorer: explorer)
        browser.storageInfo = storageInfo
        browser.storageMeasuredAt = storageMeasuredAt
        browser.breakdown = breakdown
        browser.browserSnapshots = browserSnapshots
        browser.detailCache = detailCache
        return browser
    }

    func makeVolumeBrowser(_ volume: StorageVolume, capacity: StorageInfo) -> StorageViewModel {
        let browser = StorageViewModel(manager: manager, explorer: StorageExplorer(volume: volume, home: explorer.home))
        browser.storageInfo = capacity
        browser.openDiskBrowser(path: volume.url.path)
        return browser
    }

    public func openUnassignedFolders() {
        openBrowser(mode: .unassigned, path: "")
    }

    public func openDiskBrowser(path: String = "/") {
        openBrowser(mode: .disk, path: path)
    }

    private func openBrowser(mode: BrowserMode, path: String) {
        cancelDetailSizing()
        browserMode = mode
        selectedBreakdown = nil
        detailPathStack = [path]
        selectedDetailItem = nil
        searchText = ""
        sortMode = mode == .disk && path == diskRootPath ? .nameAsc : .sizeDesc
        showOnlyFolders = false
        minSizeMB = 0
        loadCurrentPath()
    }

    private func saveBrowserSnapshot() {
        guard browserMode != .category, !isDetailSnapshotStale,
              !detailItems.isEmpty || hasMeasuredEmptyListing else { return }
        browserSnapshots.entries[browserCacheKey] = StorageBrowserSnapshot(
            listing: .init(items: detailItems, errorKey: detailErrorKey, limited: detailScanLimited || isSizingDetail,
                           directoryIdentity: browserDirectoryIdentity),
            measured: browserMeasuredPaths, date: detailMeasuredAt)
        if browserSnapshots.entries.count > 64 {
            let oldest = browserSnapshots.entries.filter { $0.key != browserCacheKey }
                .min { ($0.value.date ?? .distantPast) < ($1.value.date ?? .distantPast) }
            if let oldest { browserSnapshots.entries.removeValue(forKey: oldest.key) }
        }
    }

    public func cancelDetailSizing() {
        cancelFolderMeasurement()
        saveBrowserSnapshot()
        if isLoadingDetail { detailErrorKey = "detail.scanCancelled" }
        detailScanLimited = detailScanLimited || isSizingDetail
        detailTask?.cancel()
        detailTask = nil
        detailGeneration = UUID()
        isLoadingDetail = false
        isSizingDetail = false
    }

    func measureSelectedFolder() {
        guard let item = selectedDetailItem, item.canBrowseInStorage,
              item.path != "/", !isLoadingDetail, !isSizingDetail else { return }
        cancelFolderMeasurement()
        isMeasuringFolder = true
        let unassigned = browserMode == .unassigned
        folderMeasurementTask = Task { [weak self, explorer] in
            let worker = Task.detached(priority: .utility) {
                explorer.measureFolder(item.url, unassigned: unassigned)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled else { return }
            self.folderMeasurement = result
            self.isMeasuringFolder = false
            self.folderMeasurementTask = nil
        }
    }

    func cancelFolderMeasurement() {
        folderMeasurementTask?.cancel()
        folderMeasurementTask = nil
        folderMeasurement = nil
        isMeasuringFolder = false
    }

    public func popToDetailPath(_ index: Int) {
        guard detailPathStack.indices.contains(index) else { return }
        cancelDetailSizing()
        detailPathStack = Array(detailPathStack.prefix(index + 1))
        selectedDetailItem = nil
        searchText = ""
        loadCurrentPath()
    }

    public func reloadCurrentDetail() {
        reloadCurrentDetail(measureBrowser: false)
    }

    private func reloadCurrentDetail(measureBrowser: Bool) {
        cancelDetailSizing()
        selectedDetailItem = nil
        detailCache.removeValue(forKey: currentDetailPath)
        browserSnapshots.entries.removeValue(forKey: browserCacheKey)
        loadCurrentPath(measureBrowser: measureBrowser, refreshBrowser: true)
    }

    private var browserCacheKey: String {
        let pathKey = "\(browserMode):\(currentDetailPath)"
        guard let externalVolume else { return pathKey }
        return "volume:\(externalVolume.uuid ?? String(externalVolume.device)):\(pathKey)"
    }

    private var persistsBrowserMeasurements: Bool { externalVolume == nil || externalVolume?.uuid != nil }

    var canMeasureBrowserListing: Bool {
        browserMode != .category && currentDetailPath != "/" &&
            (!currentDetailPath.isEmpty || !detailItems.isEmpty) &&
            !isLoadingDetail && !isSizingDetail && detailErrorKey == nil
    }

    public func measureBrowserListing() {
        guard canMeasureBrowserListing else { return }
        // A new listing revalidates entry restrictions and discards sizes from the previous pass.
        reloadCurrentDetail(measureBrowser: true)
    }

    private func startBrowserMeasurement(cacheGeneration: UUID) {
        let items = detailItems
        guard !items.isEmpty else { return }
        let generation = detailGeneration
        let unassigned = browserMode == .unassigned
        isSizingDetail = true
        sizingTotal = items.count
        detailTask = Task { [weak self, explorer] in
            guard let self else { return }
            var received = 0
            let progress = DetailSizingProgress(items)
            progress.completed.removeAll()
            let publisher = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    guard let self, self.detailGeneration == generation else { return }
                    if progress.dirty { self.publishDetailProgress(progress) }
                }
            }
            defer { publisher.cancel() }
            for await item in explorer.stream(items, unassigned: unassigned) {
                guard !Task.isCancelled, self.detailGeneration == generation else { return }
                if let index = progress.positions[item.url] { progress.items[index] = item }
                progress.completed.insert(item.url)
                progress.dirty = true
                received += 1
                if items.count <= 20 || received == 1 { self.publishDetailProgress(progress) }
            }
            guard !Task.isCancelled, self.detailGeneration == generation else { return }
            self.publishDetailProgress(progress)
            guard !Task.isCancelled, self.detailGeneration == generation else { return }
            self.detailScanLimited = self.detailScanLimited || received != items.count
                || self.detailItems.contains { !$0.sizeKnown || $0.isPartial }
            if received > 0 {
                let snapshot = StorageBrowserSnapshot(
                    listing: .init(items: self.detailItems, limited: self.detailScanLimited,
                                   directoryIdentity: self.browserDirectoryIdentity),
                    measured: progress.completed, date: self.detailMeasuredAt)
                let accepted = await self.persistBrowserMeasurement(snapshot, generation: cacheGeneration)
                guard !Task.isCancelled, self.detailGeneration == generation else { return }
                self.isDetailSnapshotStale = !accepted
            }
            self.isSizingDetail = false
            self.saveBrowserSnapshot()
        }
    }

    private func persistBrowserMeasurement(_ snapshot: StorageBrowserSnapshot, generation: UUID) async -> Bool {
        guard persistsBrowserMeasurements else { return await manager.diskCache.generation == generation }
        return await manager.diskCache.saveBrowserSnapshot(snapshot, for: browserCacheKey, ifGeneration: generation)
    }

    private func loadBrowserPath(measure: Bool, refresh: Bool) {
        let generation = detailGeneration
        let path = currentDetailPath
        let unassigned = browserMode == .unassigned
        let key = browserCacheKey
        let cached = browserSnapshots.entries[key]
        let persists = persistsBrowserMeasurements
        browserDirectoryIdentity = nil
        detailMeasuredAt = nil
        isDetailSnapshotStale = false
        hasMeasuredEmptyListing = false
        detailItems = []
        browserMeasuredPaths.removeAll()
        detailErrorKey = nil
        detailScanLimited = false
        isLoadingDetail = true
        isSizingDetail = false
        sizingCount = 0
        sizingTotal = 0
        detailTask = Task { [weak self, explorer, cache = manager.diskCache] in
            let (saved, cacheGeneration) = await cache.browserSnapshot(for: key)
            guard !Task.isCancelled, self?.detailGeneration == generation else { return }
            if let candidate = cached ?? (persists ? saved : nil), !refresh {
                let fromDisk = cached == nil
                let validation = Task.detached(priority: .utility) { () throws -> StorageBrowserSnapshot? in
                    guard explorer.volume?.isMounted() != false,
                          candidate.matchesDirectory(at: path) else { return nil }
                    return fromDisk ? try candidate.removingMissingItems() : candidate
                }
                let snapshot = await withTaskCancellationHandler {
                    try? await validation.value
                } onCancel: {
                    validation.cancel()
                }
                guard !Task.isCancelled, let self, self.detailGeneration == generation else { return }
                if let snapshot {
                    self.restoreBrowserSnapshot(snapshot, fromDisk: fromDisk,
                                                removedItems: snapshot.listing.items.count < candidate.listing.items.count)
                    return
                }
                self.browserSnapshots.entries.removeValue(forKey: key)
            }
            let work = Task.detached(priority: .utility) { explorer.listing(path: path, unassigned: unassigned) }
            let listing = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, self.detailGeneration == generation else { return }
            self.detailItems = listing.items
            self.detailErrorKey = listing.errorKey
            self.detailScanLimited = listing.limited
            self.browserDirectoryIdentity = listing.directoryIdentity
            if measure && listing.items.isEmpty && listing.errorKey == nil && !listing.limited {
                let snapshot = StorageBrowserSnapshot(listing: listing, measured: [], date: Date())
                let accepted = await self.persistBrowserMeasurement(snapshot, generation: cacheGeneration)
                guard !Task.isCancelled, self.detailGeneration == generation else { return }
                self.restoreBrowserSnapshot(snapshot, fromDisk: false)
                self.isDetailSnapshotStale = !accepted
                self.saveBrowserSnapshot()
                return
            }
            self.isLoadingDetail = false
            // Broad entry points show paths first; only an explicitly opened
            // subtree starts sizing. Neither entry point walks the whole disk.
            let autoMeasure = !path.isEmpty && path != self.diskRootPath && !explorer.containsCategories(path)
            if listing.errorKey == nil && (measure || autoMeasure) {
                self.startBrowserMeasurement(cacheGeneration: cacheGeneration)
            }
        }
    }

    private func restoreBrowserSnapshot(_ snapshot: StorageBrowserSnapshot, fromDisk: Bool, removedItems: Bool = false) {
        browserDirectoryIdentity = snapshot.listing.directoryIdentity
        detailItems = snapshot.listing.items
        browserMeasuredPaths = snapshot.measured
        detailErrorKey = snapshot.listing.errorKey
        detailScanLimited = snapshot.listing.limited
        detailMeasuredAt = snapshot.date
        // A cached list with all its old rows removed may still contain new files.
        hasMeasuredEmptyListing = !removedItems && snapshot.listing.items.isEmpty &&
            snapshot.date != nil && snapshot.listing.errorKey == nil && !snapshot.listing.limited
        isDetailSnapshotStale = fromDisk || (snapshot.date.map { Date().timeIntervalSince($0) > 30 } ?? false)
        sizingCount = snapshot.measured.count
        sizingTotal = detailItems.count
        isLoadingDetail = false
    }

    public func pushPath(_ path: String) {
        detailTask?.cancel()
        detailTask = nil
        detailPathStack.append(path)
        selectedDetailItem = nil
        searchText = ""
        loadCurrentPath()
    }

    public func popPath() {
        detailTask?.cancel()
        detailTask = nil
        guard detailPathStack.count > 1 else {
            detailGeneration = UUID()
            selectedBreakdown = nil
            detailPathStack.removeAll()
            detailItems = []
            return
        }
        detailPathStack.removeLast()
        selectedDetailItem = nil
        searchText = ""
        loadCurrentPath()
    }

    private func loadCurrentPath(measureBrowser: Bool = false, refreshBrowser: Bool = false) {
        detailGeneration = UUID()
        let generation = detailGeneration
        let path = currentDetailPath
        detailErrorKey = nil
        if browserMode != .category { loadBrowserPath(measure: measureBrowser, refresh: refreshBrowser); return }
        isDetailSnapshotStale = false
        detailMeasuredAt = nil
        hasMeasuredEmptyListing = false
        detailScanLimited = false

        if let cached = detailCache[path] {
            detailItems = cached
            browserMeasuredPaths = Set(cached.map(\.url))
            isLoadingDetail = false
            isSizingDetail = false
            sizingCount = cached.count
            sizingTotal = cached.count
            return
        }

        isLoadingDetail = true
        isSizingDetail = false
        sizingCount = 0
        sizingTotal = 0
        detailItems = []
        browserMeasuredPaths.removeAll()

        detailTask = Task { [weak self] in
            guard let self else { return }

            // Phase 1: one-level metadata, with leaf sizes ready immediately.
            let work = Task.detached(priority: .utility) { [explorer] in
                explorer.listing(path: path, unassigned: false)
            }
            let response = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            let listing = response.items
            guard !Task.isCancelled, self.detailGeneration == generation else { return }

            self.detailErrorKey = response.errorKey
            self.detailItems = listing
            // The listing phase is over either way. Leaving this true for an
            // empty listing would keep the pane on the "scanning…" state
            // forever (nothing else clears the flag on this path) instead of
            // the designed empty-or-blocked state the views gate on.
            self.isLoadingDetail = false
            self.sizingTotal = listing.count

            guard !listing.isEmpty else {
                self.isSizingDetail = false
                return
            }

            // Keep every pending row visible, replacing measurements by URL.
            // Even a directory with fewer than twenty entries must publish its
            // first completed size before a slow sibling finishes.
            // Leaf metadata is immediately visible, but only one shared inode
            // pass can supply the total across leaves and sibling directories.
            self.isSizingDetail = true
            let progress = DetailSizingProgress(listing)
            progress.completed.removeAll()
            self.sizingCount = progress.completed.count
            let publisher = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    guard let self, self.detailGeneration == generation else { return }
                    if progress.dirty {
                        self.publishDetailProgress(progress)
                    }
                }
            }
            defer { publisher.cancel() }
            var received = 0
            let budget: TimeInterval = listing.count <= 40 ? 45 : 20
            for await item in explorer.stream(listing, unassigned: false, budget: budget, perItemBudget: true) {
                guard !Task.isCancelled, self.detailGeneration == generation else { return }
                guard let index = progress.positions[item.url] else { continue }
                progress.items[index] = item
                progress.completed.insert(item.url)
                progress.dirty = true
                received += 1
                if listing.count <= 20 || received == 1 {
                    self.publishDetailProgress(progress)
                }
            }

            guard !Task.isCancelled, self.detailGeneration == generation else { return }
            self.publishDetailProgress(progress)
            // Failed measurements remain retryable on the next visit.
            if progress.completed.count == listing.count && progress.items.allSatisfy({ $0.sizeKnown && !$0.isPartial }) {
                self.detailCache[path] = progress.items
            }
            self.isLoadingDetail = false
            self.isSizingDetail = false
        }
    }
    
    private func publishDetailProgress(_ progress: DetailSizingProgress) {
        detailMeasuredAt = Date()
        detailItems = progress.items
        browserMeasuredPaths = progress.completed
        sizingCount = progress.completed.count
        if let selectedDetailItem, let index = progress.positions[selectedDetailItem.url] {
            self.selectedDetailItem = progress.items[index]
        }
        progress.dirty = false
        saveBrowserSnapshot()
    }

    public func clearCache() {
        invalidateDetailState()
    }

    private func invalidateDetailState() {
        // Keep visible rows for orientation, but reject in-flight measurements
        // and cached navigation snapshots produced before the filesystem change.
        cancelDetailSizing()
        detailCache.removeAll()
        browserSnapshots.entries.removeAll()
        isDetailSnapshotStale = !detailItems.isEmpty || detailMeasuredAt != nil
    }
    
    public func revealInFinder(url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "")
    }
    
    public func openInFinder(url: URL) {
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private final class StorageBrowserSnapshots {
    var entries: [String: StorageBrowserSnapshot] = [:]
}

/// Sheet models are short-lived; releasing their observation also unregisters
/// its weak callback without crossing MainActor from the model's deinitializer.
private final class StorageInvalidationObservation {
    private let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

/// Shared only by MainActor tasks: measurement updates and the 10 Hz publisher.
@MainActor
private final class DetailSizingProgress {
    var items: [StorageItemDetail]
    let positions: [URL: Int]
    var completed: Set<URL>
    var dirty = false
    init(_ listing: [StorageItemDetail]) {
        items = listing
        positions = Dictionary(listing.enumerated().map { ($0.element.url, $0.offset) }, uniquingKeysWith: { a, _ in a })
        completed = Set(listing.filter(\.sizeKnown).map(\.url))
    }
}
