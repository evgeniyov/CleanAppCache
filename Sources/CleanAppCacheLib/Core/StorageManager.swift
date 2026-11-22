import Foundation

public struct StorageInfo: Sendable {
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let usedBytes: UInt64

    /// User-available capacity for low-disk alerts and free-space history.
    ///
    /// `volumeAvailableCapacityForImportantUsage` counts purgeable space — local
    /// snapshots and evictable caches — as available, which is what Finder and
    /// System Settings report. Plain `volumeAvailableCapacity` does not, and on
    /// this machine the two disagree by 17 GB (52.6 vs 35.3 of 245.1). Every
    /// caller of this API uses the same figure. The startup Storage breakdown
    /// uses physical capacity so allocated volume and folder bytes reconcile.
    public static func read(volume url: URL = URL(fileURLWithPath: "/")) -> StorageInfo? {
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]), let total = values.volumeTotalCapacity, total > 0 else { return nil }

        let free: Int64
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            free = important
        } else if let plain = values.volumeAvailableCapacity {
            free = Int64(plain)
        } else {
            return nil
        }
        let total64 = Int64(total)
        let clamped = min(max(0, free), total64)
        return StorageInfo(totalBytes: UInt64(total64),
                           freeBytes: UInt64(clamped),
                           usedBytes: UInt64(total64 - clamped))
    }


    /// Volume name for the Storage subtitle — "Macintosh HD". Read from
    /// the filesystem rather than hardcoded: renaming the startup disk is a
    /// thing people do.
    public static var volumeName: String {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey])
        return values?.volumeLocalizedName ?? url.lastPathComponent
    }

    /// Filesystem type — "APFS". `getattrlist` is the only route to it that does
    /// not need elevated rights; an unreadable value yields an empty string so
    /// the caller drops the segment rather than printing a guess.
    public static var fileSystemName: String {
        var stat = statfs()
        guard statfs("/", &stat) == 0 else { return "" }
        return withUnsafeBytes(of: &stat.f_fstypename) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!).uppercased()
        }
    }

    public var formattedTotal: String {
        Fmt.bytes(Int64(totalBytes))
    }
    
    public var formattedFree: String {
        Fmt.bytes(Int64(freeBytes))
    }
    
    public var formattedUsed: String {
        Fmt.bytes(Int64(usedBytes))
    }
    
    public var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
    
    public var freePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(freeBytes) / Double(totalBytes)
    }
}

public struct StorageBreakdown: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let icon: String
    public let bytes: UInt64
    enum Contents: Sendable {
        case folder(String)
        case group([StorageItemDetail])
        case volumes([StorageAPFSVolume])
        case remainder(RemainderReason)
    }

    enum RemainderReason: String, Sendable {
        case protected = "Protected Space"
        case unmeasured = "Unmeasured Space"
    }

    let contents: Contents

    public var path: String {
        if case let .folder(path) = contents { return path }
        return ""
    }

    var remainderReason: RemainderReason? {
        if case let .remainder(reason) = contents { return reason }
        return nil
    }

    var hasMembers: Bool {
        switch contents {
        case .group, .volumes: return true
        case .folder, .remainder: return false
        }
    }

    var members: [StorageItemDetail]? {
        switch contents {
        case let .group(members): return members
        case let .volumes(volumes):
            return volumes.map { StorageItemDetail(url: URL(fileURLWithPath: "/dev/" + $0.device),
                                                   size: $0.bytes ?? 0, isDirectory: false,
                                                   sizeKnown: $0.bytes != nil, volume: $0) }
        case .folder, .remainder: return nil
        }
    }

    public var formattedSize: String {
        sizeKnown ? Fmt.bytes(Int64(min(bytes, UInt64(Int64.max)))) : Fmt.none
    }
    
    public let percentOfTotal: Double

    public let sizeKnown: Bool
    public let isPartial: Bool
    public var isResidual: Bool { remainderReason != nil }
    public internal(set) var reconciled: Bool
    public let accessIssues: [StorageAccessIssue]

    public init(name: String, icon: String, bytes: UInt64, path: String, percentOfTotal: Double,
                sizeKnown: Bool = true, isPartial: Bool = false, isResidual: Bool = false,
                reconciled: Bool = true, accessIssues: [StorageAccessIssue] = []) {
        self.name = name
        self.icon = icon
        self.bytes = bytes
        self.contents = isResidual ? .remainder(.unmeasured) : .folder(path)
        self.percentOfTotal = percentOfTotal
        self.sizeKnown = sizeKnown
        self.isPartial = isPartial
        self.reconciled = reconciled
        self.accessIssues = accessIssues
    }

    init(name: String, icon: String, contents: Contents, bytes: UInt64, total: UInt64,
         sizeKnown: Bool, isPartial: Bool, accessIssues: [StorageAccessIssue] = []) {
        self.name = name
        self.icon = icon
        self.contents = contents
        self.bytes = bytes
        self.percentOfTotal = total > 0 ? Double(bytes) / Double(total) : 0
        self.sizeKnown = sizeKnown
        self.isPartial = isPartial
        self.reconciled = true
        self.accessIssues = accessIssues
    }
}

public struct StorageAccessIssue: Codable, Sendable {
    public let path: String
    public let reasonKey: String
}

public struct StorageItemDetail: Codable, Identifiable, Sendable {
    let volume: StorageAPFSVolume?
    public let id: UUID
    public let url: URL
    public let size: UInt64
    /// Whether `size` is a measurement or a placeholder.
    ///
    /// `du` is given a time budget, and on directories like `/System` it never
    /// finishes inside it — the path then has no size at all. Reported as
    /// `size == 0` it would be indistinguishable from a genuinely empty folder,
    /// and the list would draw a progress spinner for both. That spinner has no
    /// way to stop, so a scan that already gave up would look like it is still
    /// running.
    public let sizeKnown: Bool
    public let isDirectory: Bool
    public let isPartial: Bool
    /// A restriction on the entry itself. Measurement failures below it live in accessIssues.
    public let unavailableReason: String?
    public let accessIssues: [StorageAccessIssue]
    /// The displayed allocation participates in this listing's shared-inode
    /// attribution; a zero can mean another row owns the same blocks.
    public let hasSharedAllocation: Bool
    public let modified: Date?
    public let created: Date?
    public let accessed: Date?

    public init(id: UUID = UUID(), url: URL, size: UInt64, isDirectory: Bool, sizeKnown: Bool = true,
                modified: Date? = nil, created: Date? = nil, accessed: Date? = nil,
                isPartial: Bool = false, unavailableReason: String? = nil, hasSharedAllocation: Bool = false,
                accessIssues: [StorageAccessIssue] = []) {
        self.volume = nil
        self.id = id
        self.url = url
        self.size = size
        self.sizeKnown = sizeKnown
        self.isDirectory = isDirectory
        self.isPartial = isPartial
        self.unavailableReason = unavailableReason
        self.accessIssues = accessIssues
        self.hasSharedAllocation = hasSharedAllocation
        self.modified = modified
        self.created = created
        self.accessed = accessed
    }

    init(url: URL, size: UInt64, isDirectory: Bool, sizeKnown: Bool, volume: StorageAPFSVolume) {
        self.volume = volume
        id = UUID()
        self.url = url
        self.size = size
        self.isDirectory = isDirectory
        self.sizeKnown = sizeKnown
        isPartial = !sizeKnown
        unavailableReason = nil
        accessIssues = []
        hasSharedAllocation = false
        modified = nil
        created = nil
        accessed = nil
    }

    func updatingSize(_ measured: UInt64?) -> StorageItemDetail {
        StorageItemDetail(id: id, url: url, size: measured ?? 0, isDirectory: isDirectory,
                          sizeKnown: measured != nil, modified: modified, created: created, accessed: accessed,
                          isPartial: isPartial, unavailableReason: unavailableReason, hasSharedAllocation: hasSharedAllocation, accessIssues: accessIssues)
    }

    public var name: String {
        if let volume, !volume.name.isEmpty { return volume.name }
        return volume?.roles.first ?? url.lastPathComponent
    }
    public var path: String { url.path }

    public var formattedSize: String {
        guard sizeKnown else { return "—" }
        return Fmt.bytes(Int64(size))
    }
}

public actor StorageManager {
    public static let shared = StorageManager()
    
    nonisolated let diskCache: DiskCacheManager
    private let measure: @Sendable ([URL], TimeInterval) async -> [String: UInt64]
    
    private init() {
        self.init(diskCache: .shared, measure: { urls, timeout in
            await DirectorySizeProbe.measure(urls, timeout: timeout)
        })
    }

    init(diskCache: DiskCacheManager,
         measure: @escaping @Sendable ([URL], TimeInterval) async -> [String: UInt64]) {
        self.diskCache = diskCache
        self.measure = measure
    }

    public func getStorageInfo() async -> StorageInfo? {
        StorageStartupVolume.read()?.capacity ?? StorageInfo.read()
    }

    public func getBreakdown(totalBytes: UInt64, usedBytes: UInt64) async -> [StorageBreakdown] {
        let generation = await diskCache.generation
        guard let startup = StorageStartupVolume.read() else {
            return StorageClassification.breakdown(targets: [], measurement: .init(), total: totalBytes, used: usedBytes)
        }

        async let serviceVolumes = StorageAPFSVolumes.read(startup: startup)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let targets = StorageClassification.targets(volume: startup.url, home: home)
        let hasFullDiskAccess = FullDiskAccess.isGranted()
        let paths = targets.map(\.url.path)
        let measurement: StorageClassification.Measurement
        if let cached = await diskCache.storageMeasurement(device: startup.device, paths: paths,
                                                           hasFullDiskAccess: hasFullDiskAccess) {
            measurement = cached
        } else {
            measurement = await StorageClassification.measure(targets, volume: startup.url)
            if !Task.isCancelled && !measurement.timeLimited && !measurement.bytes.isEmpty {
                await diskCache.saveStorageMeasurement(measurement, device: startup.device, paths: paths,
                                                       hasFullDiskAccess: hasFullDiskAccess, ifGeneration: generation)
            }
        }
        let volumes = await serviceVolumes
        guard !Task.isCancelled, await diskCache.generation == generation else { return [] }
        return StorageClassification.breakdown(targets: targets, measurement: measurement, volumes: volumes,
                                               total: totalBytes, used: usedBytes, hasFullDiskAccess: hasFullDiskAccess)
    }

    // MARK: - Cache invalidation

    /// Expires cached sizes affected by a set of just-deleted URLs. Each
    /// deleted item shrinks every ancestor, so the disk-cache size of the item
    /// and the whole chain up to the root expires — otherwise the Storage view
    /// keeps showing pre-cleanup sizes for up to an hour.
    public func invalidate(deleted urls: [URL]) async {
        guard !urls.isEmpty else { return }
        var expiredPaths: Set<String> = []
        for url in urls {
            // Collect the item and each ancestor so their cached sizes expire.
            var ancestor: URL? = url
            while let a = ancestor, a.path != "/" {
                expiredPaths.insert(a.path)
                ancestor = a.deletingLastPathComponent()
            }
        }
        await diskCache.invalidate(paths: Array(expiredPaths), includingDescendantsOf: urls.map(\.path))
        await MainActor.run {
            NotificationCenter.default.post(name: .storageCacheInvalidated, object: nil)
        }
    }

    /// Clears every cached size. Cheap safety net a view can call before a
    /// manual rescan so results always reflect the current disk state.
    public func invalidateAll() async {
        // The on-disk size cache has to go, or "clear cache" leaves stale
        // directory sizes in place for up to an hour (24 h for files).
        await diskCache.clear()
        await MainActor.run {
            NotificationCenter.default.post(name: .storageCacheInvalidated, object: nil)
        }
    }

    /// Allocated bytes from metadata only: no file content, cloud hydration or
    /// symlink traversal. A directory needs a recursive measurement instead.
    nonisolated static func allocatedLeafSize(at url: URL) -> UInt64? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT != S_IFDIR, metadata.st_blocks >= 0 else { return nil }
        return UInt64(metadata.st_blocks) * 512
    }

    /// One stat per entry supplies type, allocation and dates together. Asking
    /// URLResourceValues for the same metadata and then statting every leaf
    /// duplicates work in folders with thousands of ordinary files.
    public func getDirectoryListing(for path: String, sorted: Bool = true) async -> [StorageItemDetail] {
        guard !Task.isCancelled,
              let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil) else { return [] }
        var items: [StorageItemDetail] = []
        items.reserveCapacity(contents.count)
        for url in contents {
            guard !Task.isCancelled else { break }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                items.append(StorageItemDetail(url: url, size: 0, isDirectory: false, sizeKnown: false))
                continue
            }
            let directory = metadata.st_mode & S_IFMT == S_IFDIR
            let known = !directory && metadata.st_blocks >= 0
            func date(_ value: timespec) -> Date {
                Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000)
            }
            items.append(StorageItemDetail(url: url, size: known ? UInt64(metadata.st_blocks) * 512 : 0,
                                           isDirectory: directory, sizeKnown: known,
                                           modified: date(metadata.st_mtimespec), created: date(metadata.st_birthtimespec),
                                           accessed: date(metadata.st_atimespec)))
        }
        return sorted ? items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } : items
    }

    /// Resolves leaf metadata and cache hits before measuring uncached paths.
    /// Completed directory measurements, including valid zeros, are persisted.
    func bulkDirectorySizes(urls: [URL], timeout: TimeInterval) async -> [String: UInt64] {
        guard !urls.isEmpty else { return [:] }
        let generation = await diskCache.generation

        var result: [String: UInt64] = [:]
        var uncached: [URL] = []

        for url in urls {
            guard !Task.isCancelled else { break }
            if let size = Self.allocatedLeafSize(at: url) {
                result[url.path] = size
            } else if let cached = await diskCache.getSize(for: url.path) {
                result[url.path] = cached
            } else {
                uncached.append(url)
            }
        }

        guard !uncached.isEmpty else {
            return await diskCache.generation == generation ? result : [:]
        }

        let pending = uncached
        let rawSizes = await measure(pending, timeout)

        for url in uncached {
            guard !Task.isCancelled else { break }
            guard let size = rawSizes[url.path] else { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            // A completed zero-byte measurement is valid. Failed/cancelled
            // probes have no map entry and never enter the cache.
            guard await diskCache.setSize(size, for: url.path, isDirectory: isDir, ifGeneration: generation)
            else { return [:] }
            result[url.path] = size
        }

        return await diskCache.generation == generation ? result : [:]
    }

    // MARK: - Streaming directory contents (for progressive UI)

    /// Leaf metadata and cached results arrive before recursive work. Each
    /// uncached directory has its own clock and one of four bounded I/O lanes.
    /// Reusing the listing avoids a second directory enumeration and preserves
    /// row identities while their measurements arrive.
    nonisolated func streamDirectory(path: String, listing: [StorageItemDetail]? = nil) -> AsyncStream<StorageItemDetail> {
        AsyncStream { [self] continuation in
            let producerTask = Task.detached {
                let items: [StorageItemDetail]
                if let listing { items = listing }
                else { items = await self.getDirectoryListing(for: path, sorted: false) }
                var pending: [StorageItemDetail] = []
                for item in items {
                    guard !Task.isCancelled else { continuation.finish(); return }
                    if item.unavailableReason != nil || item.sizeKnown {
                        continuation.yield(item)
                    } else if let cached = await self.cachedSize(for: item.url.path) {
                        continuation.yield(item.updatingSize(cached))
                    } else {
                        pending.append(item)
                    }
                }
                let timeout: TimeInterval = items.count <= 40 ? 45 : 20
                await withTaskGroup(of: StorageItemDetail.self) { group in
                    var next = 0
                    func enqueue(_ item: StorageItemDetail) {
                        group.addTask {
                            let sizes = await self.bulkDirectorySizes(urls: [item.url], timeout: timeout)
                            return item.updatingSize(sizes[item.url.path])
                        }
                    }
                    while next < min(4, pending.count) { enqueue(pending[next]); next += 1 }
                    while let item = await group.next() {
                        guard !Task.isCancelled else { group.cancelAll(); break }
                        continuation.yield(item)
                        if next < pending.count { enqueue(pending[next]); next += 1 }
                    }
                }
                if !Task.isCancelled { await self.persistDiskCache() }
                continuation.finish()
            }
            continuation.onTermination = { _ in producerTask.cancel() }
        }
    }

    private func cachedSize(for path: String) async -> UInt64? {
        await diskCache.getSize(for: path)
    }

    private func persistDiskCache() async {
        await diskCache.saveToDisk()
    }


}

public extension Notification.Name {
    /// Posted after any deletion invalidates cached sizes. Views that keep their
    /// own derived caches (e.g. `StorageViewModel.detailCache`) listen for this
    /// so a cleanup performed on another tab doesn't leave them showing files
    /// that no longer exist.
    static let storageCacheInvalidated = Notification.Name("CleanAppCache.storageCacheInvalidated")
}
