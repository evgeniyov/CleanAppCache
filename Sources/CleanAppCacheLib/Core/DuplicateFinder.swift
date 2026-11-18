import Foundation
import CryptoKit
import Darwin

public struct DuplicateFile: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let url: URL
    public let size: UInt64
    public let modified: Date?

    let snapshot: FileSnapshot?
    var digest: Data?

    public init(url: URL, size: UInt64, modified: Date?) {
        self.url = url; self.size = size; self.modified = modified
        snapshot = FileSnapshot(at: url)
    }

    public var name: String { url.lastPathComponent }
    public var path: String { url.path }
    public var formattedSize: String {
        Fmt.bytes(Int64(size))
    }

    public static func == (lhs: DuplicateFile, rhs: DuplicateFile) -> Bool {
        lhs.url == rhs.url
    }
}

public struct DuplicateGroup: Identifiable, Sendable {
    public let id = UUID()
    /// Size of a single copy (all files in the group are identical).
    public let size: UInt64
    public let files: [DuplicateFile]

    public var count: Int { files.count }

    /// Bytes that could be reclaimed by keeping a single copy.
    public var wastedBytes: UInt64 { size * UInt64(max(0, files.count - 1)) }

    public var formattedSize: String {
        Fmt.bytes(Int64(size))
    }
    public var formattedWasted: String {
        Fmt.bytes(Int64(wastedBytes))
    }
}

public struct DuplicateScanResult: Sendable {
    public let groups: [DuplicateGroup]
    public let duration: TimeInterval
    public var skipped = ScanSkipSummary()

    public var totalReclaimable: UInt64 {
        groups.reduce(0) { $0 + $1.wastedBytes }
    }
    public var formattedReclaimable: String {
        Fmt.bytes(Int64(totalReclaimable))
    }
}

public actor DuplicateFinder {
    public static let shared = DuplicateFinder()

    private init() {}

    /// Cancellation comes in as a caller-owned flag, never as an actor message:
    /// a `cancel()` queued behind a busy actor lands in unspecified order and
    /// could abort the *next* scan instead of the one the user stopped (the bug
    /// class Scanner.swift documents; an actor-wide `isCancelled` had exactly
    /// that hole). The caller flips its own flag synchronously instead.
    public func findDuplicates(
        in root: URL,
        minSize: UInt64 = 1_048_576,
        flag: CancellationFlag = CancellationFlag(),
        progress: @escaping @Sendable (String, Int) -> Void
    ) async -> DuplicateScanResult {
        let start = Date()
        let fm = FileManager.default
        let skipped = SkippedPaths()

        // 1) Bucket regular files by exact size. Files with a unique size can't
        //    have a duplicate, so this cheaply discards the vast majority.
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey,
                                      .contentModificationDateKey, .fileContentIdentifierKey]
        // Built once: the enumerator hands back every file under the root, and
        // hashing four keys into a fresh set for each one adds up.
        let keySet = Set(keys)
        var bySize: [UInt64: [DuplicateFile]] = [:]
        // Physical-storage identifiers we've already counted. APFS clones and
        // hardlinks share one, so deleting them frees little/no space — counting
        // them as reclaimable duplicates would overstate savings and could remove
        // a hardlink that still leaves the data on disk. Keep one per identifier.
        var seenContentIDs: Set<Int64> = []
        if let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in skipped.record(url); return true }
        ) {
            var scanned = 0
            // `nextObject()` avoids the Sequence `makeIterator`, which is
            // unavailable from async contexts under strict concurrency.
            while let object = enumerator.nextObject() {
                if flag.isCancelled || Task.isCancelled { break }
                guard let url = object as? URL else { continue }
                guard let v = try? url.resourceValues(forKeys: keySet) else {
                    skipped.record(url)
                    continue
                }
                guard v.isRegularFile == true else { continue }
                guard let s = v.fileSize, s >= 0 else { skipped.record(url); continue }
                guard UInt64(s) >= minSize else { continue }
                if let cid = v.fileContentIdentifier, !seenContentIDs.insert(cid).inserted {
                    continue   // clone/hardlink of a file already counted
                }
                bySize[UInt64(s), default: []].append(
                    DuplicateFile(url: url, size: UInt64(s), modified: v.contentModificationDate)
                )
                scanned += 1
                if scanned % 250 == 0 { progress(url.path, scanned) }
            }
        } else {
            skipped.record(root)
        }

        // 2) Confirm with hashing. A cheap partial hash (first 64 KB) narrows
        //    each size bucket, then a full streaming SHA-256 confirms true
        //    duplicates. Hashing is pure (url → digest) and I/O-bound, so each
        //    stage is ONE pass over the candidates of every bucket with a
        //    bounded number of reads in flight (≈ core count). Hashing bucket
        //    by bucket would keep two reads in flight for the typical bucket of
        //    two files, however many cores there are.
        //
        //    Buckets are keyed by size and digest together: two files of
        //    different sizes can share their first 64 KB, and a partial digest
        //    alone would pull them into one candidate set.
        let maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount)

        let sizeMatches = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        var byPartial: [Bucket: [DuplicateFile]] = [:]
        let partialHashes = await Self.hashInParallel(
            sizeMatches, maxConcurrency: maxConcurrency, flag: flag,
            using: { Self.hash($0, limit: 65_536, flag: flag) }
        )
        if !flag.isCancelled, !Task.isCancelled {
            let hashed = Set(partialHashes.map { $0.0.id })
            for file in sizeMatches where !hashed.contains(file.id) {
                skipped.record(file.url, reason: PathGuard.reject(file.url) == nil ? .unreadable : .safetyProtected)
            }
        }
        for (file, digest) in partialHashes {
            byPartial[Bucket(size: file.size, digest: digest), default: []].append(file)
        }

        let partialMatches = (flag.isCancelled || Task.isCancelled)
            ? []
            : byPartial.values.filter { $0.count > 1 }.flatMap { $0 }
        var byFull: [Bucket: [DuplicateFile]] = [:]
        let fullHashes = await Self.hashInParallel(
            partialMatches, maxConcurrency: maxConcurrency, flag: flag,
            using: { Self.hash($0, flag: flag) }
        )
        if !flag.isCancelled, !Task.isCancelled {
            let hashed = Set(fullHashes.map { $0.0.id })
            for file in partialMatches where !hashed.contains(file.id) {
                skipped.record(file.url, reason: PathGuard.reject(file.url) == nil ? .unreadable : .safetyProtected)
            }
        }
        for (file, digest) in fullHashes {
            var verified = file
            verified.digest = digest
            byFull[Bucket(size: file.size, digest: digest), default: []].append(verified)
        }

        let groups = byFull.compactMap { bucket, confirmed in
            confirmed.count > 1 ? DuplicateGroup(size: bucket.size, files: confirmed) : nil
        }

        return DuplicateScanResult(
            groups: groups.sorted { $0.wastedBytes > $1.wastedBytes },
            duration: Date().timeIntervalSince(start),
            skipped: skipped.summary
        )
    }

    /// Enumeration callbacks and failed metadata/hash probes share a bounded report.
    private final class SkippedPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ScanSkipSummary()

        func record(_ url: URL, reason: ScanSkipReason = .unreadable) {
            lock.lock(); defer { lock.unlock() }
            value.record(url, reason: reason)
        }

        var summary: ScanSkipSummary {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    // MARK: - Hashing

    /// A candidate set: files of one size whose digests agree.
    private struct Bucket: Hashable {
        let size: UInt64
        let digest: Data
    }

    /// Hashes `files` concurrently with at most `maxConcurrency` in-flight tasks
    /// (a sliding window), returning (file, digest) for every file that hashed
    /// successfully. Order is unspecified — callers bucket by digest.
    ///
    /// A cancelled scan stops feeding the window; each in-flight hasher checks
    /// that scan's flag between chunks instead of reading a large file to EOF.
    private nonisolated static func hashInParallel(
        _ files: [DuplicateFile],
        maxConcurrency: Int,
        flag: CancellationFlag,
        using hasher: @escaping @Sendable (DuplicateFile) -> Data?
    ) async -> [(DuplicateFile, Data)] {
        guard !flag.isCancelled, !Task.isCancelled else { return [] }
        if files.count <= 1 {
            if let f = files.first, let h = hasher(f) { return [(f, h)] }
            return []
        }
        return await withTaskGroup(of: (DuplicateFile, Data?).self) { group in
            var results: [(DuplicateFile, Data)] = []
            results.reserveCapacity(files.count)

            var index = 0
            let seed = min(max(1, maxConcurrency), files.count)
            while index < seed, !flag.isCancelled, !Task.isCancelled {
                let f = files[index]
                group.addTask { (f, hasher(f)) }
                index += 1
            }
            // Each completion refills one slot, keeping the window full.
            while let (file, hash) = await group.next() {
                if let hash { results.append((file, hash)) }
                if index < files.count, !flag.isCancelled, !Task.isCancelled {
                    let f = files[index]
                    group.addTask { (f, hasher(f)) }
                    index += 1
                }
            }
            return results
        }
    }

    // Digests stay raw bytes. They are only ever compared, and spelling the 32
    // bytes out through `String(format:)` costs about as much per file as
    // hashing its first 64 KB.

    /// Revalidates content and file identity, including for the copy that will stay.
    nonisolated static func isUnchanged(_ file: DuplicateFile) -> Bool {
        guard let digest = file.digest else { return false }
        return hash(file) == digest
    }

    /// The reader seam lets scratch tests cancel during an actual chunk read
    /// without large files, sleeps or changing the file's scan-time identity.
    nonisolated static func hash(
        _ file: DuplicateFile, limit: Int? = nil, flag: CancellationFlag? = nil,
        reader: (FileHandle, Int) throws -> Data? = { try $0.read(upToCount: $1) }
    ) -> Data? {
        guard !Task.isCancelled, flag?.isCancelled != true,
              PathGuard.reject(file.url) == nil,
              let snapshot = file.snapshot, snapshot.isRegularFile,
              snapshot.size >= 0, UInt64(snapshot.size) == file.size,
              snapshot.matches(file.url) else { return nil }
        let descriptor = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, FileSnapshot(before) == snapshot else { return nil }
        var hasher = SHA256()
        var readBytes = 0
        while true {
            guard !Task.isCancelled, flag?.isCancelled != true else { return nil }
            let amount = limit.map { min(1_048_576, $0 - readBytes) } ?? 1_048_576
            if amount == 0 { break }
            let chunk: Data
            do { chunk = try reader(handle, amount) ?? Data() }
            catch { return nil }
            if chunk.isEmpty { break }
            readBytes += chunk.count
            hasher.update(data: chunk)
        }
        var after = stat()
        guard !Task.isCancelled, flag?.isCancelled != true,
              fstat(descriptor, &after) == 0, FileSnapshot(after) == snapshot,
              snapshot.matches(file.url), PathGuard.reject(file.url) == nil else { return nil }
        return Data(hasher.finalize())
    }
}
