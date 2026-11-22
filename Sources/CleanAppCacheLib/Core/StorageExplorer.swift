import Foundation

struct StorageDirectoryIdentity: Codable, Equatable, Sendable {
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init(_ metadata: stat) {
        inode = UInt64(metadata.st_ino)
        birthSeconds = Int64(metadata.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(metadata.st_birthtimespec.tv_nsec)
    }

    var birthDate: Date {
        Date(timeIntervalSince1970: Double(birthSeconds) + Double(birthNanoseconds) / 1_000_000_000)
    }
}

struct StorageBrowserSnapshot: Codable, Sendable {
    let listing: StorageExplorer.Listing
    let measured: Set<URL>
    let date: Date?

    func matchesDirectory(at path: String) -> Bool {
        // The virtual root represents several directories, with no inode of its own.
        if path.isEmpty { return true }
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else { return false }
        let current = StorageDirectoryIdentity(metadata)
        if let saved = listing.directoryIdentity { return saved == current }
        // Older snapshots lack an identity. Keep them unless the directory
        // could not have existed when the measurement was taken.
        guard let date else { return false }
        return current.birthDate <= date
    }

    func removingMissingItems() throws -> Self {
        // Validate only saved rows so newly added files and changed sizes stay
        // out of the measurement until the user measures the list again.
        var missing: Set<URL> = []
        var current = listing
        current.items = try listing.items.filter { item in
            try Task.checkCancellation()
            var metadata = stat()
            if lstat(item.path, &metadata) != 0 && (errno == ENOENT || errno == ENOTDIR) {
                missing.insert(item.url)
                return false
            }
            return true
        }
        return Self(listing: current, measured: measured.subtracting(missing), date: date)
    }
}

/// Folder exploration is independent of the capacity balance. Only metadata is
/// read; a single listing scan owns its inode set, deadline and cancellation.
struct StorageExplorer: Sendable {
    struct Listing: Codable, Sendable {
        var items: [StorageItemDetail]
        var errorKey: String? = nil
        var limited = false
        var directoryIdentity: StorageDirectoryIdentity? = nil
    }

    let home: URL
    let roots: [URL]
    let excluded: [String]
    let devices: Set<dev_t>
    let readDirectory: @Sendable (URL) throws -> [URL]
    let volume: StorageVolume?

    init(volume: StorageVolume, home: URL) {
        self.volume = volume
        self.home = Self.normalized(home)
        roots = []
        excluded = []
        devices = [volume.device]
        readDirectory = { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
    }

    static var live: StorageExplorer {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return StorageExplorer(home: home,
                               roots: ["/Users", "/Library", "/private", "/opt", "/usr/local"].map { URL(fileURLWithPath: $0) },
                               excluded: StorageClassification.fixedFolderPaths(home: home),
                               volumes: [URL(fileURLWithPath: "/"), URL(fileURLWithPath: StorageStartupVolume.dataPath), home])
    }

    init(home: URL, roots: [URL], excluded: [URL], volumes: [URL],
         readDirectory: @escaping @Sendable (URL) throws -> [URL] = {
             try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
         }) {
        self.home = Self.normalized(home)
        self.volume = nil
        self.readDirectory = readDirectory
        self.roots = roots.map(Self.normalized)
        self.excluded = excluded.map { Self.normalized($0).path }
        self.devices = Set(volumes.compactMap { url in
            var metadata = stat()
            return stat(url.path, &metadata) == 0 ? metadata.st_dev : nil
        })
    }

    /// Resolve parent aliases such as /var without following a final symlink.
    /// Listings and exclusions must use the same spelling of their root.
    private static func normalized(_ url: URL) -> URL {
        guard url.path != "/" else { return url }
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { return url }
        defer { free(parent) }
        let base = String(cString: parent)
        return URL(fileURLWithPath: (base == "/" ? "/" : base + "/") + url.lastPathComponent)
    }

    func isExcluded(_ path: String) -> Bool {
        excluded.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Credential stores and private conversation histories remain metadata-only.
    /// Hidden build/model caches can be explored without opening these stores.
    private func isPrivate(_ path: String) -> Bool {
        func logicalPath(_ path: String) -> String {
            let dataPath = StorageStartupVolume.dataPath
            return path.hasPrefix(dataPath + "/") ? String(path.dropFirst(dataPath.count)) : path
        }
        let logical = logicalPath(path)
        let homePath = logicalPath(home.path)
        let relative = logical.hasPrefix(homePath + "/") ? String(logical.dropFirst(homePath.count + 1)).lowercased() : ""
        return [".ssh", ".gnupg", ".aws", ".azure", ".kube", ".codex", ".config/gcloud",
                "library/keychains", "library/mail", "library/messages"].contains {
            relative == $0 || relative.hasPrefix($0 + "/")
        }
    }

    func containsCategories(_ path: String) -> Bool {
        excluded.contains { $0.hasPrefix(path == "/" ? "/" : path + "/") }
    }

    func listing(path: String, unassigned: Bool) -> Listing {
        guard !Task.isCancelled else { return Listing(items: [], errorKey: "detail.scanCancelled", limited: true) }
        guard volume?.isMounted() != false else { return Listing(items: [], errorKey: "storage.volumeUnavailable") }
        if path.isEmpty && unassigned { return frontier() }
        let path = Self.normalized(URL(fileURLWithPath: path)).path
        if isPrivate(path) { return Listing(items: [], errorKey: "detail.privateMetadata") }
        if unassigned && isExcluded(path) { return Listing(items: [], errorKey: "detail.alreadyCategorized") }
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return Listing(items: [], errorKey: Self.errorKey(errno)) }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { return Listing(items: [], errorKey: "detail.notDirectory") }
        guard devices.contains(metadata.st_dev) else { return Listing(items: [], errorKey: "detail.externalVolume") }
        do {
            let urls = try readDirectory(URL(fileURLWithPath: path))
            var items: [StorageItemDetail] = []
            for url in urls {
                try Task.checkCancellation()
                if !unassigned || !isExcluded(url.path) { items.append(item(url, unassigned: unassigned)) }
            }
            // Cancellation must also interrupt a wide directory's sort after
            // enumeration finishes, not only suppress its eventual publication.
            try Task.checkCancellation()
            try items.sort {
                try Task.checkCancellation()
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return Listing(items: items, directoryIdentity: StorageDirectoryIdentity(metadata))
        } catch is CancellationError {
            return Listing(items: [], errorKey: "detail.scanCancelled", limited: true)
        } catch {
            return Listing(items: [], errorKey: Self.errorKey(error))
        }
    }

    /// Split only ancestors of classified folders. An untouched subtree is a
    /// candidate, not a claim that its whole physical size explains the balance.
    private func frontier() -> Listing {
        var result = Listing(items: [])
        var pending = roots
        var visited: Set<String> = []
        while let url = pending.popLast() {
            guard !Task.isCancelled else { result.limited = true; break }
            guard visited.count < 300 else { result.limited = true; break }
            guard visited.insert(url.path).inserted, !isExcluded(url.path) else { continue }
            if containsCategories(url.path) {
                let children = listing(path: url.path, unassigned: true)
                if let error = children.errorKey {
                    result.items.append(item(url, unassigned: true, reason: error))
                } else {
                    // Hidden folders participate in the overview. Sensitive
                    // stores are shown with a reason and never traversed.
                    for child in children.items {
                        pending.append(child.url)
                    }
                }
            } else {
                var metadata = stat()
                if lstat(url.path, &metadata) != 0 && errno == ENOENT { continue }
                result.items.append(item(url, unassigned: true))
            }
        }
        return result
    }

    private func item(_ url: URL, unassigned: Bool, reason: String? = nil) -> StorageItemDetail {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            return StorageItemDetail(url: url, size: 0, isDirectory: true, sizeKnown: false,
                                     unavailableReason: reason ?? Self.errorKey(errno))
        }
        let directory = metadata.st_mode & S_IFMT == S_IFDIR
        let blocked = reason ?? (isPrivate(url.path) ? "detail.privateMetadata" : nil)
            ?? (!devices.contains(metadata.st_dev) ? "detail.externalVolume" : nil)
            ?? (unassigned && containsCategories(url.path) ? "detail.alreadyCategorized" : nil)
        return StorageItemDetail(url: url, size: !directory && blocked == nil ? UInt64(max(0, metadata.st_blocks)) * 512 : 0,
                                 isDirectory: directory, sizeKnown: !directory && blocked == nil && metadata.st_nlink <= 1,
                                 modified: Date(timeIntervalSince1970: Double(metadata.st_mtimespec.tv_sec)),
                                 created: Date(timeIntervalSince1970: Double(metadata.st_birthtimespec.tv_sec)),
                                 accessed: Date(timeIntervalSince1970: Double(metadata.st_atimespec.tv_sec)),
                                 unavailableReason: blocked, hasSharedAllocation: !directory && metadata.st_nlink > 1)
    }

    func stream(_ items: [StorageItemDetail], unassigned: Bool, budget: TimeInterval = 20,
                perItemBudget: Bool = false) -> AsyncStream<StorageItemDetail> {
        AsyncStream { continuation in
            let owner = Task.detached(priority: .utility) {
                let seen = Inodes()
                let duration = UInt64(min(60, max(0, budget)) * 1_000_000_000)
                let deadline = DispatchTime.now().uptimeNanoseconds + duration
                await withTaskGroup(of: StorageItemDetail.self) { group in
                    var next = 0
                    func enqueue(_ item: StorageItemDetail) {
                        group.addTask {
                            let limit = perItemBudget ? DispatchTime.now().uptimeNanoseconds + duration : deadline
                            return measure(item, unassigned: unassigned, deadline: limit, seen: seen)
                        }
                    }
                    while next < min(4, items.count) { enqueue(items[next]); next += 1 }
                    while let value = await group.next() {
                        guard !Task.isCancelled else { group.cancelAll(); break }
                        continuation.yield(value)
                        if next < items.count && (perItemBudget || DispatchTime.now().uptimeNanoseconds < deadline) {
                            enqueue(items[next]); next += 1
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in owner.cancel() }
        }
    }

    /// An independent total for one folder, with its own deadline and inode set.
    func measureFolder(_ url: URL, unassigned: Bool) -> StorageItemDetail {
        let url = Self.normalized(url)
        guard volume?.isMounted() != false else {
            return StorageItemDetail(url: url, size: 0, isDirectory: true, sizeKnown: false,
                                     unavailableReason: "storage.volumeUnavailable")
        }
        let reason = unassigned && isExcluded(url.path) ? "detail.alreadyCategorized" : nil
        let entry = item(url, unassigned: unassigned, reason: reason)
        if !entry.isDirectory && entry.unavailableReason == nil {
            return StorageItemDetail(url: entry.url, size: 0, isDirectory: false,
                                     sizeKnown: false, unavailableReason: "detail.notDirectory")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 60_000_000_000
        return measure(entry, unassigned: unassigned, deadline: deadline, seen: Inodes())
    }

    private struct Identity: Hashable { let device: dev_t; let inode: ino_t }
    private final class Inodes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: Set<Identity> = []
        func claim(_ value: Identity) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return values.insert(value).inserted
        }
    }

    private func measure(_ item: StorageItemDetail, unassigned: Bool, deadline: UInt64, seen: Inodes) -> StorageItemDetail {
        guard item.unavailableReason == nil else { return item }
        var rootMetadata = stat()
        guard lstat(item.path, &rootMetadata) == 0 else {
            return StorageItemDetail(id: item.id, url: item.url, size: 0, isDirectory: item.isDirectory,
                                     sizeKnown: false, unavailableReason: Self.errorKey(errno))
        }
        guard devices.contains(rootMetadata.st_dev), !(unassigned && (isExcluded(item.path) || containsCategories(item.path))) else {
            return item
        }
        var pending = [item.url]
        var size: UInt64 = 0
        var partial = false
        var entryReason: String?
        var sharedAllocation = false
        var issues: [StorageAccessIssue] = []
        func record(_ path: String, _ key: String, blocksEntry: Bool = false) {
            partial = true
            // Descendant failures limit the size without restricting access to the entry.
            if blocksEntry && path == item.path { entryReason = key }
            if issues.count < 8 { issues.append(StorageAccessIssue(path: path, reasonKey: key)) }
        }
        while let url = pending.popLast() {
            guard !Task.isCancelled else { record(item.path, "detail.scanCancelled"); break }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { record(item.path, "detail.timeBudget"); break }
            if isPrivate(url.path) { record(url.path, "detail.privateMetadata", blocksEntry: true); continue }
            if unassigned && isExcluded(url.path) { continue }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                record(url.path, Self.errorKey(errno), blocksEntry: true)
                continue
            }
            // Symlinks are leaves. Every recursive root stays on its own
            // filesystem; mounted descendants never join its allocation.
            guard metadata.st_dev == rootMetadata.st_dev else {
                record(url.path, "detail.externalVolume", blocksEntry: true)
                continue
            }
            let directory = metadata.st_mode & S_IFMT == S_IFDIR
            if !directory && metadata.st_nlink > 1 {
                sharedAllocation = true
                guard seen.claim(Identity(device: metadata.st_dev, inode: metadata.st_ino)) else { continue }
            }
            let allocated = UInt64(max(0, metadata.st_blocks)) * 512
            let (sum, overflow) = size.addingReportingOverflow(allocated)
            size = overflow ? UInt64.max : sum
            if directory {
                do { pending.append(contentsOf: try readDirectory(url)) }
                catch { record(url.path, Self.errorKey(error), blocksEntry: true) }
            }
        }
        return StorageItemDetail(id: item.id, url: item.url, size: size, isDirectory: item.isDirectory,
                                 sizeKnown: !(partial && size == 0), modified: item.modified, created: item.created,
                                 accessed: item.accessed, isPartial: partial, unavailableReason: entryReason,
                                 hasSharedAllocation: sharedAllocation, accessIssues: issues)
    }

    private static func errorKey(_ code: Int32) -> String {
        code == EACCES || code == EPERM ? "detail.accessDenied" : "detail.unavailable"
    }

    private static func errorKey(_ error: Error) -> String {
        let e = error as NSError
        if e.domain == NSPOSIXErrorDomain { return errorKey(Int32(e.code)) }
        return e.code == NSFileReadNoPermissionError ? "detail.accessDenied" : "detail.unavailable"
    }
}
