import Foundation

/// Caches directory sizes on disk so scans are instant on app restart
public actor DiskCacheManager {
    public static let shared = DiskCacheManager()
    
    private let cacheURL: URL
    private var memoryCache: [String: CacheEntry] = [:]
    private var browserSnapshots: [String: StorageBrowserSnapshot] = [:]
    private let fileManager = FileManager.default
    /// A measurement may outlive a deletion or cache reset. Its generation
    /// prevents a late result from restoring entries that have been expired.
    private(set) var generation = UUID()
    
    private struct CacheEntry: Codable, Sendable {
        let size: UInt64
        let timestamp: Date
        let isDirectory: Bool
    }
    
    private struct CacheFile: Codable {
        var entries: [String: CacheEntry]
        var version: Int
        var browserSnapshots: [String: StorageBrowserSnapshot]?
    }
    
    private init() {
        self.init(directory: AppPaths.support)
    }

    init(directory: URL) {
        // An injected directory keeps tests and separate app builds from reading
        // or replacing the installed app's cache.
        let fm = FileManager.default
        let appFolder = directory
        let cacheURL = appFolder.appendingPathComponent("sizeCache.json")
        self.cacheURL = cacheURL

        try? fm.createDirectory(at: appFolder, withIntermediateDirectories: true)

        // Load from disk
        if let data = try? Data(contentsOf: cacheURL),
           let cacheFile = try? JSONDecoder().decode(CacheFile.self, from: data) {
            self.memoryCache = cacheFile.entries
            self.browserSnapshots = cacheFile.browserSnapshots ?? [:]
        }
    }
    
    public func getSize(for path: String) -> UInt64? {
        guard let entry = memoryCache[path] else { return nil }
        // Cache valid for 1 hour for directories, 24 hours for files
        let maxAge: TimeInterval = entry.isDirectory ? 3600 : 86400
        if Date().timeIntervalSince(entry.timestamp) < maxAge {
            return entry.size
        }
        return nil
    }
    
    public func setSize(_ size: UInt64, for path: String, isDirectory: Bool) {
        memoryCache[path] = CacheEntry(size: size, timestamp: Date(), isDirectory: isDirectory)
    }

    func setSize(_ size: UInt64, for path: String, isDirectory: Bool, ifGeneration expected: UUID) -> Bool {
        guard generation == expected else { return false }
        setSize(size, for: path, isDirectory: isDirectory)
        return true
    }

    func browserSnapshot(for key: String) -> (snapshot: StorageBrowserSnapshot?, generation: UUID) {
        (browserSnapshots[key], generation)
    }

    func saveBrowserSnapshot(_ snapshot: StorageBrowserSnapshot, for key: String,
                             ifGeneration expected: UUID) -> Bool {
        guard generation == expected else { return false }
        browserSnapshots[key] = snapshot
        if browserSnapshots.count > 64,
           let oldest = browserSnapshots.filter({ $0.key != key })
               .min(by: { ($0.value.date ?? .distantPast) < ($1.value.date ?? .distantPast) }) {
            browserSnapshots.removeValue(forKey: oldest.key)
        }
        persist()
        return true
    }

    func clearBrowserSnapshots() {
        generation = UUID()
        guard !browserSnapshots.isEmpty else { return }
        browserSnapshots.removeAll()
        persist()
    }

    /// Drops the cached size for these exact paths. Call after deleting files so
    /// stale sizes aren't served for a folder whose contents just changed.
    public func invalidate(paths: [String], includingDescendantsOf roots: [String] = []) {
        generation = UUID()
        // Browser snapshots also include descendant sizes and can span several roots.
        browserSnapshots.removeAll()
        for path in paths { memoryCache.removeValue(forKey: path) }
        let prefixes = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        memoryCache = memoryCache.filter { key, _ in
            !roots.contains(key) && !prefixes.contains(where: key.hasPrefix)
        }
        // Invalidation is durable before notifying views: relaunching before
        // another scan must not reload the old entries from the JSON file.
        persist()
    }

    /// Drops every cached entry whose path is `prefix` or lives under it. Use the
    /// parent directory of a deleted item to expire the folder that shrank.
    public func invalidate(under prefix: String) {
        invalidate(paths: [], includingDescendantsOf: [prefix])
    }

    public func saveToDisk() async {
        persist()
    }

    private func persist() {
        // Prune expired entries before persisting so the file can't grow without
        // bound as more paths are scanned over time.
        let now = Date()
        memoryCache = memoryCache.filter { _, entry in
            let maxAge: TimeInterval = entry.isDirectory ? 3600 : 86400
            return now.timeIntervalSince(entry.timestamp) < maxAge
        }
        let cacheFile = CacheFile(entries: memoryCache, version: 1, browserSnapshots: browserSnapshots)
        do {
            let data = try JSONEncoder().encode(cacheFile)
            // Atomic write: a crash/interleave mid-write would otherwise leave a
            // truncated JSON that fails to decode and silently wipes the cache.
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Log.error("Failed to persist size cache: \(error.localizedDescription)")
        }
    }
    
    /// Returns whether the on-disk cache file is actually gone — the caller's
    /// "caches cleared" toast must not report success over a failed unlink.
    @discardableResult
    public func clear() -> Bool {
        generation = UUID()
        memoryCache.removeAll()
        browserSnapshots.removeAll()
        do {
            try fileManager.removeItem(at: cacheURL)
            return true
        } catch let error as NSError {
            // Never written yet is success, not a failure to surface.
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError { return true }
            Log.error("Size cache removal failed: \(error.localizedDescription)")
            return false
        }
    }
}
