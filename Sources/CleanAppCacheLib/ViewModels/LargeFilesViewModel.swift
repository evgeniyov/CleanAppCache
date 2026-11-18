import Foundation

/// How many `find` matches we are willing to `stat` before giving up on ranking.
private let largeFileStatLimit = 20_000
/// How many results the list shows.
private let largeFileResultLimit = 500

public struct LargeFile: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let size: UInt64
    public let modified: Date?
    public let accessed: Date?
    /// Whether this process may move the file to the Trash. Decided by the
    /// scanner so the row never has to ask the filesystem while drawing.
    public let isDeletable: Bool
    let snapshot: FileSnapshot?

    init(url: URL, size: UInt64, modified: Date?, accessed: Date?, isDeletable: Bool, snapshot: FileSnapshot? = nil) {
        self.url = url
        self.size = size
        self.modified = modified
        self.accessed = accessed
        self.isDeletable = isDeletable
        self.snapshot = snapshot ?? FileSnapshot(at: url)
    }

    public var name: String { url.lastPathComponent }
    public var path: String { url.path }
    public var formattedSize: String {
        Fmt.bytes(Int64(size))
    }

    /// Best-known "last used" date: the most recent of access / modification.
    public var lastUsed: Date? {
        switch (accessed, modified) {
        case let (a?, m?): return max(a, m)
        case let (a?, nil): return a
        case let (nil, m?): return m
        default: return nil
        }
    }
}

@MainActor
public final class LargeFilesViewModel: ObservableObject {
    public enum SearchScope: String, Codable, CaseIterable, Sendable {
        case home
        case entireDisk
    }

    /// How big a file has to be to be worth listing.
    ///
    /// Stored in **decimal** bytes, the same unit `Fmt` prints. A threshold of
    /// 100 multiplied by 1024² (100 MiB) would come back through `Fmt` in the
    /// clean state, which repeats the threshold, as "104.9 MB". The stored number
    /// and the printed number are the same number, so the ladder in the header,
    /// the bytes `find` filters on and the text in the empty state all agree.
    public enum MinSize: String, Codable, CaseIterable, Identifiable, Sendable {
        case mb100, mb500, gb1, gb5

        public var id: String { rawValue }

        public var bytes: UInt64 {
            switch self {
            case .mb100: return 100_000_000
            case .mb500: return 500_000_000
            case .gb1:   return 1_000_000_000
            case .gb5:   return 5_000_000_000
            }
        }

        public var titleKey: String {
            switch self {
            case .mb100: return "scan.min.100mb"
            case .mb500: return "scan.min.500mb"
            case .gb1:   return "scan.min.1gb"
            case .gb5:   return "scan.min.5gb"
            }
        }
    }

    public enum AgeFilter: String, Codable, CaseIterable, Identifiable {
        case all, m3, m6, y1
        public var id: String { rawValue }

        /// Files last used before this cutoff pass the filter (nil = no cutoff).
        var cutoff: Date? {
            let now = Date()
            switch self {
            case .all: return nil
            case .m3: return Calendar.current.date(byAdding: .month, value: -3, to: now)
            case .m6: return Calendar.current.date(byAdding: .month, value: -6, to: now)
            case .y1: return Calendar.current.date(byAdding: .year, value: -1, to: now)
            }
        }
    }

    @Published public var files: [LargeFile] = []
    @Published public var isScanning = false
    @Published public var minSize: MinSize = .mb100
    @Published public var searchScope: SearchScope = .home
    @Published private(set) var customSearchFolder: URL?

    var searchRoot: URL {
        customSearchFolder ?? (searchScope == .home
            ? FileManager.default.homeDirectoryForCurrentUser : URL(fileURLWithPath: "/"))
    }
    @Published public var ageFilter: AgeFilter = .all
    @Published public var currentScanPath = ""
    /// Whether the user has run a scan yet (drives the idle vs. empty state).
    @Published public var hasScanned = false

    // Collector (DaisyDisk-style batch selection)
    @Published public var selected: Set<UUID> = []
    @Published public var isDeleting = false

    public var minSizeText: String {
        Fmt.bytes(minSize.bytes)
    }

    // MARK: - Scan parameters
    //
    // The threshold and the reach of the search are inputs, not filters over the
    // results: `find` never returns what they excluded, so a list produced under
    // one pair of them says nothing about the other. Changing either therefore
    // discards the finding instead of relabelling it — the subtitle names the
    // scope ("searching the home folder") and the clean state names the threshold,
    // and both would otherwise describe a scan that never ran.

    public func setMinSize(_ new: MinSize) {
        guard !isDeleting else { return }
        guard new != minSize else { return }
        minSize = new
        invalidateResults()
    }

    public func setSearchScope(_ new: SearchScope) {
        guard !isDeleting else { return }
        guard new != searchScope || customSearchFolder != nil else { return }
        searchScope = new
        customSearchFolder = nil
        invalidateResults()
    }

    func setCustomSearchFolder(_ url: URL) {
        guard !isDeleting, url.isFileURL else { return }
        customSearchFolder = url.standardizedFileURL.resolvingSymlinksInPath()
        invalidateResults()
    }

    /// Throws away the last scan, including one still running. No file is
    /// touched — only the finding, and the selection built on top of it.
    public func invalidateResults() {
        guard !isDeleting else { return }
        cancelScan()
        files = []
        selected = []
        hasScanned = false
        filterCache = nil
    }

    /// Memoised filter+sort.
    ///
    /// `body` reads this three times per render; uncached, it runs a full
    /// O(n log n) pass on every frame while the threshold is dragged on a
    /// slider. The cache key is the only state the result depends on.
    private var filterCache: (key: FilterKey, value: [LargeFile])?

    private struct FilterKey: Equatable {
        let fileCount: Int
        let firstID: UUID?
        let minSize: MinSize
        let ageFilter: AgeFilter
    }

    public var filteredFiles: [LargeFile] {
        let key = FilterKey(
            fileCount: files.count,
            firstID: files.first?.id,
            minSize: minSize,
            ageFilter: ageFilter
        )
        if let cache = filterCache, cache.key == key { return cache.value }

        let minBytes = minSize.bytes
        let cutoff = ageFilter.cutoff
        let result = files
            .filter { $0.size >= minBytes }
            .filter { file in
                guard let cutoff else { return true }
                guard let used = file.lastUsed else { return false }
                return used < cutoff
            }
            .sorted { $0.size > $1.size }
        filterCache = (key, result)
        return result
    }

    // MARK: - Collector

    typealias TrashValidation = @Sendable (URL) -> Bool
    private let trashOperation: @Sendable ([URL], @escaping TrashValidation) async -> TrashService.Result
    private let history: CleanupHistory

    public convenience init() {
        self.init(trash: { urls, validation in
            await TrashService.trashEscalating(urls, validationObstacle: .changedSinceScan, validation: validation)
        }, history: .shared)
    }

    init(trash: @escaping @Sendable ([URL], @escaping TrashValidation) async -> TrashService.Result, history: CleanupHistory) {
        trashOperation = trash
        self.history = history
    }

    public var selectedCount: Int { selected.count }

    public var selectedSize: UInt64 {
        files.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    public var formattedSelectedSize: String {
        Fmt.bytes(Int64(selectedSize))
    }

    public func toggle(_ file: LargeFile) {
        guard !isDeleting else { return }
        if selected.contains(file.id) { selected.remove(file.id) }
        else { selected.insert(file.id) }
    }

    public func clearSelection() { selected.removeAll() }

    public func deleteSelected() async {
        guard !isDeleting, !isScanning else { return }
        let toDelete = files.filter { selected.contains($0.id) }
        guard !toDelete.isEmpty else { return }
        isDeleting = true
        defer { isDeleting = false }

        // The displayed name may now refer to an unrelated file or directory.
        // Check the scanned file again before either move, including the Finder handoff.
        let snapshots = Dictionary(toDelete.compactMap { file in file.snapshot.map { (file.url, $0) } },
                                   uniquingKeysWith: { first, _ in first })
        let result = await trashOperation(toDelete.map(\.url)) { url in
            guard let snapshot = snapshots[url], snapshot.isRegularFile else { return false }
            return snapshot.matches(url)
        }

        // Remove the trashed files from the list (keep them for undo).
        let trashedPaths = Set(result.trashed.map { $0.original.path } + result.alreadyGone.map(\.path))
        files.removeAll { trashedPaths.contains($0.url.path) }
        selected.removeAll()

        await StorageManager.shared.invalidate(deleted: result.trashed.map { $0.original })

        let record = history.log(.largeFiles, items: result.count, trashedBytes: result.freedBytes)
        let history = self.history
        let scope = searchScope
        let generation = scanGeneration
        let threshold = minSize
        TrashService.presentToast(result) { [weak self] in
            let restored = TrashService.restoreItems(result.trashed, recordingUndoOf: record, history: history)
            // Only the rows whose files actually came back.
            if !restored.isEmpty, let self, self.searchScope == scope, self.minSize == threshold,
               self.scanGeneration == generation, !self.isScanning {
                let restoredURLs = Set(restored.map(\.original))
                let existing = Set(self.files.map(\.url))
                self.files.append(contentsOf: toDelete.compactMap { file in
                    guard restoredURLs.contains(file.url), !existing.contains(file.url),
                          let snapshot = FileSnapshot(at: file.url), let scanned = file.snapshot,
                          snapshot.device == scanned.device, snapshot.inode == scanned.inode,
                          snapshot.mode == scanned.mode, snapshot.size == scanned.size,
                          snapshot.modifiedSeconds == scanned.modifiedSeconds,
                          snapshot.modifiedNanoseconds == scanned.modifiedNanoseconds else { return nil }
                    // Moving the original file updates its change time.
                    return LargeFile(url: file.url, size: file.size, modified: file.modified, accessed: file.accessed,
                                     isDeletable: file.isDeletable, snapshot: snapshot)
                })
            }
            TrashService.presentRestore(restored.count)
        }
    }

    private var scanGeneration = UUID()
    private var scanTask: Task<Void, Never>?
    private var findTask: Task<(files: [LargeFile], partial: Bool), Never>?

    public func startScan() {
        guard !isDeleting else { return }
        // Both tasks: the detached `find` is not a child of `scanTask`, so
        // cancelling the parent alone leaves it running.
        findTask?.cancel()
        scanTask?.cancel()
        scanGeneration = UUID()
        let generation = scanGeneration
        isScanning = true
        hasScanned = true
        files = []
        selected = []
        currentScanPath = ""

        let root = searchRoot
        let minBytes = minSize.bytes

        // `find` blocks on a pipe read; run it off the main actor or the whole
        // UI freezes for as long as the scan takes (up to the 60 s watchdog
        // when scanning the entire disk). The detached task is held onto
        // explicitly: it is *not* a child of `scanTask`, so cancelling the
        // parent alone would never reach it.
        let work = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.scanForLargeFiles(root: root, minBytes: minBytes) { [weak self] path in
                Task { @MainActor in
                    guard let self, self.scanGeneration == generation, self.isScanning else { return }
                    self.currentScanPath = path
                }
            }
        }
        findTask = work

        scanTask = Task {
            let found = await work.value
            guard !Task.isCancelled, !work.isCancelled else { return }
            self.files = found.files
            self.isScanning = false
            self.findTask = nil
            // A cut-short search ranks only what it reached; presenting that
            // as "the largest files" — or an empty list as a clean disk —
            // would claim more than was looked at.
            if found.partial {
                let loc = Localizer.shared
                ToastCenter.shared.show(Toast(style: .warning,
                                              title: loc.s("large.partialTitle"),
                                              message: loc.s("large.partialHint"),
                                              duration: 10))
            }
        }
    }

    /// Stops an in-flight scan. Without this the only way out of a whole-disk
    /// scan was to quit the app, and leaving the tab left it running orphaned.
    public func cancelScan() {
        scanGeneration = UUID()
        findTask?.cancel()
        findTask = nil
        scanTask?.cancel()
        scanTask = nil
        // A cancelled scan produced no finding: `startScan` already dropped the
        // previous list, so leaving `hasScanned` raised would present the empty
        // `files` as a clean disk once the view's own "cancelled" flag dies
        // with the tab switch. Back to idle — the state that actually happened.
        if isScanning { hasScanned = false }
        isScanning = false
        currentScanPath = ""
    }

    private nonisolated static func scanForLargeFiles(
        root: URL,
        minBytes: UInt64,
        progress: (@Sendable (String) -> Void)?
    ) async -> (files: [LargeFile], partial: Bool) {
        let path = root.path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        process.arguments = [
            path,
            // Stay on the volume we were pointed at. Without this, scanning "/"
            // walks every mounted external disk, Time Machine target and network
            // share, and offers their contents up for deletion in one click.
            "-xdev",
            "-type", "f",
            // Filter in exact bytes (`c` suffix). Using `…M` integer-divides the
            // threshold to whole megabytes, so any sub-1 MB minimum collapses to
            // "+0M" — which matches essentially every non-empty file on disk — and
            // it disagrees at the boundary with the byte-exact `fileSize` filter
            // applied to the results.
            "-size", "+\(minBytes)c",
            "-not", "-path", "*/.Trash/*",
            "-not", "-path", "*/.Spotlight*",
            "-not", "-path", "*/.fseventsd/*",
            "-not", "-path", "*/.DocumentRevisions*",
            // iCloud Drive and the other cloud providers: deleting here
            // propagates to every device the user owns, and a local Undo does
            // not put the file back in the cloud.
            "-not", "-path", "*/Library/Mobile Documents/*",
            "-not", "-path", "*/Library/CloudStorage/*",
            "-not", "-path", "*/Backups.backupdb/*",
            "-not", "-path", "*/.MobileBackups/*",
            "-print0"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let timedOut = WatchdogFlag()
            let watchdog = DispatchWorkItem {
                if process.isRunning { timedOut.set(); process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)

            // Task cancellation cannot interrupt the blocking read, and until
            // the watchdog fired (60 s) a cancelled scan left `find` traversing
            // the whole volume at full I/O. Terminating the process closes the
            // pipe's write end, so the read returns promptly. `onCancel` also
            // fires immediately when the task is already cancelled at entry.
            let data = await withTaskCancellationHandler {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return d
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
            watchdog.cancel()
            if Task.isCancelled { return ([], false) }

            // Lossy decode: one path that isn't valid UTF-8 shouldn't discard
            // the entire scan.
            let output = String(decoding: data, as: UTF8.self)
            let paths = output.split(separator: "\0").map(String.init)
            var files: [LargeFile] = []

            // Stat everything `find` matched, then sort, then cap. Capping the
            // *input* meant taking the first 500 paths in filesystem-traversal
            // order and calling them "the largest files" — the actual largest
            // file could easily be number 501 and never appear.
            files.reserveCapacity(min(paths.count, largeFileStatLimit))
            // The path line is read by a person, so ten updates a second is
            // all it can use. Reported per file, it would take up to 20,000
            // main-actor hops and redraws within a few seconds.
            var lastProgress: UInt64 = 0
            for filePath in paths.prefix(largeFileStatLimit) {
                if Task.isCancelled { return ([], false) }
                let url = URL(fileURLWithPath: filePath)
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastProgress >= 100_000_000 {
                    lastProgress = now
                    progress?(filePath)
                }
                // Offer only what the delete path accepts. PathGuard refuses
                // repository objects, VM disks, media-library internals and
                // installed software; listing them invites a delete that fails.
                guard PathGuard.reject(url) == nil,
                      let snapshot = FileSnapshot(at: url), snapshot.isRegularFile else { continue }
                // Allocated size, the space deleting the file gives back: a
                // sparse disk image (`Docker.raw`) is tens of gigabytes by
                // length and a fraction of that on disk.
                if let v = try? url.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
                              .contentModificationDateKey, .contentAccessDateKey]
                ),
                   let size = v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize,
                   UInt64(size) >= minBytes {
                    files.append(LargeFile(
                        url: url,
                        size: UInt64(size),
                        modified: v.contentModificationDate,
                        accessed: v.contentAccessDate,
                        // Only the rows that will be listed are worth the
                        // extra access check, hence the second pass below.
                        isDeletable: true,
                        snapshot: snapshot
                    ))
                }
            }
            let fm = FileManager.default
            let ranked = files.sorted { $0.size > $1.size }.prefix(largeFileResultLimit).compactMap { file -> LargeFile? in
                guard let snapshot = file.snapshot, snapshot.matches(file.url) else { return nil }
                return LargeFile(url: file.url, size: file.size,
                                 modified: file.modified, accessed: file.accessed,
                                 isDeletable: fm.isDeletableFile(atPath: file.path), snapshot: snapshot)
            }
            return (ranked, timedOut.isSet || process.terminationStatus != 0 || paths.count > largeFileStatLimit)
        } catch {
            return ([], true)
        }
    }

    /// Set by the watchdog when it stops `find`; read after the pipe closes.
    private final class WatchdogFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

}
