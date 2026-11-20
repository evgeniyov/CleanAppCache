import Foundation

// Models live in Models/ScanCategory.swift, Models/CleanableItem.swift, Models/ScanResult.swift

public actor Scanner {
    public static let shared = Scanner()
    
    private var activeScan: (id: UUID, task: Task<ScanResult, Error>)?
    private let duExecutable: URL

    init(duExecutable: URL = URL(fileURLWithPath: "/usr/bin/du")) {
        self.duExecutable = duExecutable
    }

    public func cancel() {
        activeScan?.task.cancel()
    }

    /// One root inside a `.children` category, with its own safety policy.
    struct ChildRoot: Sendable {
        let path: String
        /// May items found here be preselected for cleaning?
        let autoSelect: Bool
        /// Skip entries touched more recently than this. Guards against
        /// deleting scratch files of an app that is using them right now.
        let minAge: TimeInterval
        let excluding: Set<String>

        init(_ path: String, autoSelect: Bool = true, minAge: TimeInterval = 0, excluding: Set<String> = []) {
            self.path = path
            self.autoSelect = autoSelect
            self.excluding = excluding
            self.minAge = minAge
        }
    }

    /// How a category gathers its cleanable items.
    enum CategorySource: Sendable {
        /// List the immediate children of each root (skipping excluded names).
        case children(roots: [ChildRoot], excluding: Set<String>)
        /// Each path itself is a single cleanable item (e.g. one browser's cache dir).
        case directories([String])
        /// Files inside a directory matching the given lowercase extensions.
        case filesMatching(directory: String, extensions: Set<String>)

        /// Representative path shown in scan progress.
        var displayPath: String {
            switch self {
            case let .children(roots, _): return roots.first?.path ?? ""
            case let .directories(paths): return paths.first ?? ""
            case let .filesMatching(directory, _): return directory
            }
        }
    }

    /// Roots handled separately from the top-level user-cache listing.
    /// Google is split by product because the vendor also ships non-browser apps.
    private static let browserCacheNames: Set<String> = [
        "com.apple.Safari", "Google", "Firefox", "Microsoft Edge",
        "BraveSoftware", "com.operasoftware.Opera", "Arc",
        "company.thebrowser.Browser", "Vivaldi"
    ]

    static let googleBrowserNames: Set<String> = ["Chrome", "Chrome Beta", "Chrome Canary", "Chrome Dev"]

    static func userCacheSource(_ root: String) -> CategorySource {
        .children(roots: [ChildRoot(root, excluding: browserCacheNames),
                          ChildRoot(root + "/Google", excluding: googleBrowserNames)],
                  excluding: [])
    }

    static func browserCacheSource(_ root: String) -> CategorySource {
        .directories(browserCacheNames.subtracting(["Google"]).sorted().map { root + "/" + $0 }
                     + googleBrowserNames.sorted().map { root + "/Google/" + $0 })
    }

    /// Absolute paths that no `.children` category offers, whatever the root.
    ///
    /// Matched by full path rather than added to a category's `excluding` names:
    /// those names apply to every root of the category, so excluding
    /// "CleanAppCache" there would also hide a same-named entry under
    /// `/var/log`. The app's own log folder is here because trashing it cuts
    /// off `Log` for the rest of the launch, including the record of the very
    /// cleanup that removed it.
    static let excludedChildPaths: Set<String> = {
        guard let logs = Log.directory else { return [] }
        return [logs.standardizedFileURL.path]
    }()

    public func performFullScan(progressHandler: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        try Task.checkCancellation()
        let id = UUID()
        let task = Task { try await scan(progressHandler: progressHandler) }
        activeScan = (id, task)
        defer { if activeScan?.id == id { activeScan = nil } }
        // Both entry points cancel this run's task group and its live probes.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func scan(progressHandler: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResult {
        try Task.checkCancellation()
        let startTime = Date()

        let home = FileManager.default.homeDirectoryForCurrentUser
        let userCaches = home.appendingPathComponent("Library/Caches").path

        // Per-root policy, not per-category: `~/Library/Logs` is routine to
        // clear, `/var/log` is the system's own logging and is left for the
        // user to opt into. Temp roots additionally ignore anything touched in
        // the last hour, which is the difference between "stale scratch file"
        // and "the file an app is writing to right now".
        let liveWindow = Self.liveWindow(for: .tempFiles)

        let categories: [(ScanCategory, CategorySource)] = [
            // `/System/Library/Caches` is not scanned: SIP restricts it, so
            // listing its contents offered space no delete could reclaim.
            (.systemCache, .children(roots: [
                ChildRoot("/Library/Caches", autoSelect: false)
            ], excluding: [])),
            (.userCache, Self.userCacheSource(userCaches)),
            (.browserJunk, Self.browserCacheSource(userCaches)),
            (.logs, .children(roots: [
                ChildRoot(home.appendingPathComponent("Library/Logs").path),
                ChildRoot("/var/log", autoSelect: false)
            ], excluding: [])),
            (.trash, .children(roots: [
                ChildRoot(home.appendingPathComponent(".Trash").path, autoSelect: false)
            ], excluding: [])),
            (.tempFiles, .children(roots: [
                ChildRoot(NSTemporaryDirectory(), minAge: liveWindow),
                ChildRoot("/tmp", autoSelect: false, minAge: liveWindow)
            ], excluding: [])),
            (.installers, .filesMatching(
                directory: home.appendingPathComponent("Downloads").path,
                extensions: ["dmg", "pkg", "mpkg", "iso", "xip"]
            ))
        ]

        var allItems: [CleanableItem] = []
        var skipped = ScanSkipSummary()
        skipped.record(URL(fileURLWithPath: "/System/Library/Caches"), category: .systemCache, reason: .systemProtected)
        var categorySizes: [ScanCategory: UInt64] = [:]
        let totalCategories = categories.count
        var done = 0

        // Scan categories concurrently with a bounded window. Each category runs
        // its own batched `du`, so overlapping them cuts total scan time. Work
        // happens in `scanCategory` (nonisolated) and honors Task cancellation, so
        // cancelling the scan stops the in-flight workers.
        await withTaskGroup(of: (ScanCategory, CategoryResult).self) { group in
            let maxConcurrency = min(4, totalCategories)
            var next = 0
            // Emits a "category started" event (with its path) so the scan log
            // shows live activity; completion events below carry the sizes.
            func launch(_ index: Int, done: Int) {
                let (category, source) = categories[index]
                progressHandler(ScanProgress(
                    currentCategory: category,
                    categoriesDone: done,
                    totalCategories: totalCategories,
                    currentPath: source.displayPath,
                    partialSize: 0
                ))
                group.addTask { (category, await self.scanCategory(category: category, source: source)) }
            }
            while next < maxConcurrency {
                launch(next, done: 0)
                next += 1
            }
            while let (category, scanned) = await group.next() {
                if Task.isCancelled { group.cancelAll(); break }
                let items = scanned.items
                skipped.merge(scanned.skipped)
                done += 1
                let catSize = items.reduce(0) { $0 + $1.size }
                categorySizes[category] = catSize
                allItems.append(contentsOf: items)
                progressHandler(ScanProgress(
                    currentCategory: category,
                    categoriesDone: done,
                    totalCategories: totalCategories,
                    currentPath: "",
                    partialSize: catSize
                ))
                if next < totalCategories {
                    launch(next, done: done)
                    next += 1
                }
            }
        }

        try Task.checkCancellation()
        let totalSize = allItems.reduce(0) { $0 + $1.size }
        let duration = Date().timeIntervalSince(startTime)

        return ScanResult(
            items: allItems.sorted { $0.size > $1.size },
            totalSize: totalSize,
            duration: duration,
            categorySizes: categorySizes,
            skipped: skipped
        )
    }

    struct CategoryResult: Sendable {
        var items: [CleanableItem] = []
        var skipped = ScanSkipSummary()
    }

    nonisolated func scanCategory(
        category: ScanCategory,
        source: CategorySource,
        inUse: @Sendable (URL) -> Bool = { AppActivityGuard.cacheIsInUse($0) },
        sizeProvider: (@Sendable ([URL]) -> [String: UInt64])? = nil
    ) async -> CategoryResult {
        var result = CategoryResult()
        guard !Task.isCancelled else { return result }
        let fm = FileManager.default
        var identities: [URL: RemovalIdentity] = [:]

        func record(_ url: URL, _ reason: ScanSkipReason) {
            result.skipped.record(url, category: category, reason: reason)
        }
        func exists(_ url: URL) -> Bool {
            do { _ = try url.resourceValues(forKeys: [.isDirectoryKey]); return true }
            catch {
                if !Self.isMissing(error) { record(url, .unreadable) }
                return false
            }
        }
        func contents(_ url: URL) -> [URL] {
            do { return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) }
            catch {
                if !Self.isMissing(error) { record(url, .unreadable) }
                return []
            }
        }
        func eligible(_ url: URL, minAge: TimeInterval) -> Bool {
            guard !Task.isCancelled else { return false }
            guard let identity = RemovalIdentity(at: url) else { record(url, .unreadable); return false }
            if let reason = Self.skipReason(url, minAge: minAge, inUse: inUse) {
                if !Task.isCancelled { record(url, reason) }
                return false
            }
            guard !Task.isCancelled else { return false }
            guard identity.matches(url) else { record(url, .unreadable); return false }
            identities[url] = identity
            return true
        }
        func append(_ urls: [URL], autoSelect: Bool) async {
            guard !Task.isCancelled else { return }
            let candidates = urls.filter { url in
                guard !Task.isCancelled else { return false }
                guard identities[url]?.matches(url) == true else { record(url, .unreadable); return false }
                return true
            }
            var sizes: [String: UInt64] = [:]
            if let sizeProvider {
                sizes = sizeProvider(candidates)
            } else {
                for batch in Self.duBatches(candidates) {
                    guard !Task.isCancelled else { return }
                    sizes.merge(await measureScanBatch(batch, timeout: 30)) { current, _ in current }
                }
            }
            for url in candidates {
                guard !Task.isCancelled else { return }
                var size = sizes[url.path]
                // Retry only missing or uncertain roots from the batch.
                if size == nil, sizeProvider == nil {
                    size = await measureScanBatch([url], timeout: 20, retainPeers: false)[url.path]
                }
                guard !Task.isCancelled else { return }
                guard let identity = identities[url], identity.matches(url) else { record(url, .unreadable); continue }
                guard let size else { record(url, .unreadable); continue }
                if size > 0 {
                    result.items.append(CleanableItem(url: url, category: category, size: size,
                                                      itemCount: 0, autoSelect: autoSelect, removalIdentity: identity))
                }
            }
        }

        switch source {
        case let .children(roots, excluding):
            for root in roots {
                if Task.isCancelled { break }
                let url = URL(fileURLWithPath: root.path)
                var candidates: [URL] = []
                for child in contents(url) {
                    if Task.isCancelled { break }
                    if excluding.contains(child.lastPathComponent) || root.excluding.contains(child.lastPathComponent) { continue }
                    if Self.excludedChildPaths.contains(child.standardizedFileURL.path) {
                        record(child, .ownLogs)
                    } else if eligible(child, minAge: max(root.minAge, Self.liveWindow(for: category))) {
                        candidates.append(child)
                    }
                }
                await append(candidates, autoSelect: root.autoSelect && category.isSafeToAutoClean)
            }
        case let .directories(paths):
            var candidates: [URL] = []
            for path in paths {
                if Task.isCancelled { break }
                let url = URL(fileURLWithPath: path)
                if exists(url), eligible(url, minAge: Self.liveWindow(for: category)) { candidates.append(url) }
            }
            await append(candidates, autoSelect: category.isSafeToAutoClean)
        case let .filesMatching(directory, extensions):
            var packages: [URL] = []
            for url in contents(URL(fileURLWithPath: directory)) {
                if Task.isCancelled { break }
                guard extensions.contains(url.pathExtension.lowercased()), eligible(url, minAge: 0) else { continue }
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if values.isDirectory == true {
                        // Legacy installers are directory packages; their entry size
                        // does not include the payload and can be absent altogether.
                        if ["pkg", "mpkg"].contains(url.pathExtension.lowercased()) { packages.append(url) }
                        continue
                    }
                    guard let size = values.fileSize, size >= 0,
                          let identity = identities[url], identity.matches(url) else {
                        record(url, .unreadable); continue
                    }
                    if size > 0 {
                        result.items.append(CleanableItem(url: url, category: category, size: UInt64(size),
                                                          itemCount: 1, autoSelect: false, removalIdentity: identity))
                    }
                } catch { record(url, .unreadable) }
            }
            await append(packages, autoSelect: false)
        }
        // A partial result is never published as a completed scan.
        return Task.isCancelled ? CategoryResult() : result
    }

    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    nonisolated static func skipReason(_ url: URL, minAge: TimeInterval,
                                      inUse: (URL) -> Bool = AppActivityGuard.cacheIsInUse) -> ScanSkipReason? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return .unreadable }
        if values.isSymbolicLink == true { return .symbolicLink }
        if RemovalCheck.isSystemProtected(url) { return .systemProtected }
        if let rejection = PathGuard.rejectTree(url, beforeInspect: { _ in }, isCancelled: { Task.isCancelled }) {
            if rejection == .managedCache { return .managedCache }
            return rejection == .unverifiedContents ? .unreadable : .safetyProtected
        }
        if inUse(url) { return .inUse }
        return recentSkipReason(url, within: minAge)
    }

    /// How long an item of `category` must have been left alone before it is
    /// offered. Caches and logs get the same live window as temporary files.
    public static func liveWindow(for category: ScanCategory) -> TimeInterval {
        switch category {
        case .tempFiles, .userCache, .browserJunk, .logs: return 3600
        default: return 0
        }
    }

    /// True when `url`, or anything inside it, was modified within `window`.
    ///
    /// A folder's own date changes only when an entry is added or removed
    /// inside it, not when a file already there is written, so an app writing
    /// to its scratch file all day leaves the folder looking untouched. The
    /// walk looks at the entries themselves and treats a tree too large to
    /// check (`limit` entries) as in use.
    public nonisolated static func touchedRecently(_ url: URL, within window: TimeInterval,
                                                    limit: Int = 5_000) -> Bool {
        recentSkipReason(url, within: window, limit: limit) != nil
    }

    /// Unknown contents and traversal limits are conservative skips, not evidence
    /// of a recent write. Cancellation follows the same conservative path.
    nonisolated static func recentSkipReason(_ url: URL, within window: TimeInterval,
                                             limit: Int = 5_000) -> ScanSkipReason? {
        guard window > 0 else { return nil }
        let cutoff = Date().addingTimeInterval(-window)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: keys),
              let modified = values.contentModificationDate else { return .unreadable }
        if values.isSymbolicLink == true { return .symbolicLink }
        if modified > cutoff { return .recent }
        guard values.isDirectory == true else { return nil }
        let unreadable = UnreadableFlag()
        guard let enumerator = FileManager.default.enumerator(
            at: fresh, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in unreadable.set(); return false }) else { return .unreadable }
        var seen = 0
        for case let child as URL in enumerator {
            if Task.isCancelled { return .verificationLimit }
            if unreadable.isSet { return .unreadable }
            seen += 1
            if seen > limit { return .verificationLimit }
            guard let date = (try? child.resourceValues(forKeys: keys))?.contentModificationDate
            else { return .unreadable }
            if date > cutoff { return .recent }
        }
        return unreadable.isSet ? .unreadable : nil
    }

    private final class UnreadableFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    
    /// Batched size calculator: one `du` for the whole set instead of one per
    /// path. Returns a path → bytes map; paths `du` could not size are absent.
    public nonisolated func calculateSizes(at urls: [URL], timeout: TimeInterval = 30) -> [String: UInt64] {
        var result: [String: UInt64] = [:]
        for batch in Self.duBatches(urls) {
            guard !Task.isCancelled else { break }
            let requireSuccess = batch.count == 1 && Self.hasLineBreak(batch[0])
            if let data = runDU(batch, timeout: timeout, requireSuccess: requireSuccess) {
                result.merge(Self.parseDUSizes(data, urls: batch)) { current, _ in current }
            }
        }
        return result
    }

    private nonisolated func measureScanBatch(_ urls: [URL], timeout: TimeInterval,
                                              retainPeers: Bool = true) async -> [String: UInt64] {
        guard let response = await DirectorySizeProbe.captureResponse(executable: duExecutable,
            arguments: ["-sk"] + urls.map(\.path), timeout: timeout) else { return [:] }
        let sizes = Self.parseDUSizes(response.data, urls: urls)
        if response.succeeded { return sizes }
        guard retainPeers, urls.count > 1, response.exited, !response.timedOut,
              !response.diagnostics.isEmpty, response.diagnostics.count < 65_536 else { return [:] }

        // BSD du attaches each traversal error to its path. If any diagnostic
        // cannot be attributed to an operand, no row can be certified.
        let paths = urls.map(\.path)
        var uncertain: Set<String> = []
        for line in String(decoding: response.diagnostics, as: UTF8.self).split(separator: "\n") {
            let roots = paths.filter { line.hasPrefix("du: " + $0 + "/") || line.hasPrefix("du: " + $0 + ": ") }
            guard !roots.isEmpty else { return [:] }
            uncertain.formUnion(roots)
        }
        return sizes.filter { !uncertain.contains($0.key) }
    }

    /// Keep each batch below ARG_MAX. BSD du prints literal paths and cannot
    /// NUL-delimit output, so isolate paths that contain CR or LF.
    private static func duBatches(_ urls: [URL]) -> [[URL]] {
        var batches: [[URL]] = []
        for start in stride(from: 0, to: urls.count, by: 128) {
            let chunk = urls[start..<min(start + 128, urls.count)]
            let ordinary = chunk.filter { !hasLineBreak($0) }
            if !ordinary.isEmpty { batches.append(ordinary) }
            batches.append(contentsOf: chunk.filter(hasLineBreak).map { [$0] })
        }
        return batches
    }

    private static func hasLineBreak(_ url: URL) -> Bool {
        url.path.utf8.contains(10) || url.path.utf8.contains(13)
    }

    private static func parseDUSizes(_ data: Data, urls: [URL]) -> [String: UInt64] {
        func bytes(_ kilobytes: Substring) -> UInt64? {
            guard let kb = UInt64(kilobytes.trimmingCharacters(in: .whitespaces)),
                  kb <= UInt64.max / 1024 else { return nil }
            return kb * 1024
        }

        let output = String(decoding: data, as: UTF8.self)
        if urls.count == 1, let tab = output.firstIndex(of: "\t"),
           let size = bytes(output[..<tab]) {
            return [urls[0].path: size]
        }
        let paths = Set(urls.map(\.path))
        var result: [String: UInt64] = [:]
        for line in output.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let size = bytes(line[..<tab]) else { continue }
            let path = String(line[line.index(after: tab)...])
            if paths.contains(path) { result[path] = size }
        }
        return result
    }

    /// Public size calculator for external use (AppManager)
    public nonisolated func calculateSize(at url: URL) -> UInt64 {
        fastSize(at: url).0
    }
    
    /// Fast size calculation using du command or URLResourceKey
    private nonisolated func fastSize(at url: URL) -> (UInt64, Int) {
        // Try du command first — fastest for directories on macOS
        if let result = sizeViaDU(at: url) {
            return (result, 0)
        }
        
        // Fallback: URL resource values for files
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
           let isDir = values.isDirectory {
            if !isDir, let size = values.fileSize {
                return (UInt64(size), 1)
            }
        }
        
        // Final fallback: quick enumerator count
        return sizeViaEnumerator(at: url)
    }
    
    private nonisolated func sizeViaDU(at url: URL, timeout: TimeInterval = 20) -> UInt64? {
        guard let data = runDU([url], timeout: timeout, requireSuccess: true) else { return nil }
        return Self.parseDUSizes(data, urls: [url])[url.path]
    }

    /// Synchronous sizing for callers outside the Smart Cleanup scan. A failed
    /// bulk traversal may yield lower bounds, while a single size needs success.
    private nonisolated func runDU(_ urls: [URL], timeout: TimeInterval, requireSuccess: Bool) -> Data? {
        let task = Process()
        task.executableURL = duExecutable
        task.arguments = ["-sk"] + urls.map(\.path)
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() }
        catch { return nil }

        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()

        return !requireSuccess || task.terminationStatus == 0 ? data : nil
    }

    /// Fallback enumerator-based sizing with file count
    private nonisolated func sizeViaEnumerator(at url: URL) -> (UInt64, Int) {
        let size = (try? FileManager.default.allocatedSize(of: URL(fileURLWithPath: url.path))) ?? 0
        return (size, 0)
    }
}
