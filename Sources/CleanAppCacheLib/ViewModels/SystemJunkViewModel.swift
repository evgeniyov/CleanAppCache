import Foundation
import SwiftUI

@MainActor
public final class SystemJunkViewModel: ObservableObject {
    @Published public var entries:    [SystemJunkEntry] = []
    @Published public var selected:   Set<UUID>         = []
    @Published public var isScanning  = false
    @Published public var isCleaning  = false
    @Published public var hasScanned  = false
    @Published public var currentScan = ""
    @Published public var skipped = ScanSkipSummary()

    private let manager = SystemJunkManager.shared

    /// Moves one entry to the Trash.
    typealias EntryCleaner = (SystemJunkEntry) async -> TrashService.Result
    /// Hands the items this account may not move to Finder, which asks for a password.
    typealias Escalator = ([URL], @escaping @Sendable (URL) -> Bool) async -> TrashService.Result

    private let cleanEntry: EntryCleaner
    private let escalate: Escalator

    public init() {
        cleanEntry = { await SystemJunkManager.shared.clean($0) }
        escalate = { urls, validation in await TrashService.trashEscalating(urls, validation: validation) }
    }

    /// Tests replace both, so no item reaches the real Trash or a password dialog.
    init(cleanEntry: @escaping EntryCleaner, escalate: @escaping Escalator) {
        self.cleanEntry = cleanEntry
        self.escalate = escalate
    }

    // MARK: - Computed

    public var selectedEntries: [SystemJunkEntry] {
        entries.filter { selected.contains($0.id) }
    }

    public var selectedSize: UInt64 {
        selectedEntries.reduce(0) { $0 + $1.totalSize }
    }

    public var formattedSelectedSize: String {
        Fmt.bytes(Int64(selectedSize))
    }

    public var totalSize: UInt64 {
        entries.reduce(0) { $0 + $1.totalSize }
    }

    public var formattedTotalSize: String {
        Fmt.bytes(Int64(totalSize))
    }

    // MARK: - Actions

    public func scan() {
        guard !isCleaning else { return }
        guard !isScanning else { return }
        isScanning  = true
        hasScanned  = true
        entries     = []
        selected    = []
        currentScan = ""
        skipped = ScanSkipSummary()

        Task {
            let found = await manager.scanWithReport()
            self.entries = found.entries
            self.skipped = found.skipped
            self.selectSafe()
            self.isScanning = false
        }
    }

    public func toggle(_ entry: SystemJunkEntry) {
        if selected.contains(entry.id) { selected.remove(entry.id) }
        else                           { selected.insert(entry.id) }
    }

    public func selectSafe() {
        selected = Set(entries.filter { $0.category.isSafe }.map(\.id))
    }

    public func deselectAll() { selected.removeAll() }

    public func clean() async {
        guard !isCleaning, !isScanning else { return }
        let toClean = selectedEntries
        guard !toClean.isEmpty else { return }

        isCleaning = true
        var totalTrashed: UInt64 = 0
        var cleanedIDs: [UUID] = []
        var trashedURLs: [URL] = []
        var trashed: [TrashService.Trashed] = []
        var failed: [URL] = []
        var blocked: [URL] = []
        var obstacles: [URL: RemovalObstacle] = [:]
        var protectedEntries: [URL: [SystemJunkEntry]] = [:]
        var escalation: EscalationOutcome?

        for entry in toClean {
            currentScan = entry.category.rawValue
            let result = await cleanEntry(entry)
            let gone = result.trashed.map(\.original) + result.alreadyGone
            totalTrashed += result.freedBytes
            trashedURLs += gone
            trashed += result.trashed
            failed += result.failed
            blocked += result.blocked
            for url in result.failed {
                obstacles[url] = result.obstacles[url]
                if result.obstacles[url] == .needsAdmin { protectedEntries[url, default: []].append(entry) }
            }
            let entryFailed = result.failed.count + result.blocked.count
            if entryFailed == 0 {
                cleanedIDs.append(entry.id)
            } else if !gone.isEmpty,
                      let idx = entries.firstIndex(where: { $0.id == entry.id }) {
                // Partial: some URLs went, some stayed. Treating `freed > 0` as
                // cleaned would put the whole entry into `cleanedIDs`, so the
                // row would vanish, the history would count it as cleaned, and
                // the survivors (a multi-gigabyte iOS backup, say) would stay
                // invisible until a rescan. Keep the row with its survivors instead — it stays
                // selected, so the retry is one click (the invariant the view
                // documents).
                let goneSet = Set(gone.map(\.path))
                entries[idx] = entry.keeping(
                    urls: entry.urls.filter { !goneSet.contains($0.path) },
                    totalSize: entry.totalSize >= result.freedBytes ? entry.totalSize - result.freedBytes : 0
                )
            }
        }

        // Everything that needs an administrator, in one Finder request.
        let protected = failed.filter { obstacles[$0] == .needsAdmin }
        if !protected.isEmpty {
            let selectedEntries = protectedEntries
            let retry = await escalate(protected) { url in
                guard let matching = selectedEntries[url] else { return false }
                return matching.allSatisfy {
                    $0.matches(url) && SystemJunkManager.canMoveToTrash(url, category: $0.category) && $0.matches(url)
                }
            }
            let r = SystemJunkManager.classifyChanges(retry, entries: toClean)
            let moved = Set(r.trashed.map(\.original) + r.alreadyGone)
            trashed += r.trashed
            totalTrashed += r.freedBytes
            trashedURLs += Array(moved)
            let retried = Set(protected)
            failed.removeAll { retried.contains($0) }
            failed += r.failed
            blocked += r.blocked
            for url in protected { obstacles[url] = nil }
            for (url, obstacle) in r.obstacles { obstacles[url] = obstacle }
            escalation = r.escalation
            for index in entries.indices {
                let left = entries[index].urls.filter { !moved.contains($0) }
                if left.isEmpty { cleanedIDs.append(entries[index].id) }
                else if left.count < entries[index].urls.count {
                    let originalURLs = Set(entries[index].urls)
                    let movedBytes = r.trashed.filter { originalURLs.contains($0.original) }
                        .reduce(UInt64(0)) { $0 + $1.movedBytes }
                    let remainingSize = entries[index].totalSize > movedBytes
                        ? entries[index].totalSize - movedBytes : 0
                    entries[index] = entries[index].keeping(urls: left, totalSize: remainingSize)
                }
            }
        }

        let cleanedSet = Set(cleanedIDs)
        entries.removeAll   { cleanedSet.contains($0.id) }
        selected.subtract(cleanedSet)
        isCleaning  = false
        currentScan = ""

        // Only what actually left the disk — invalidating a survivor's cached
        // size would be wrong in the other direction.
        await StorageManager.shared.invalidate(deleted: trashedURLs)

        // Every entry goes to the Trash, so none of this space is free yet.
        let movedPaths = Set(trashed.map(\.original))
        let touchedCount = toClean.filter { entry in entry.urls.contains { movedPaths.contains($0) } }.count
        let record = CleanupHistory.shared.log(.systemJunk, items: touchedCount, trashedBytes: totalTrashed)

        let summary = TrashService.Result(trashed: trashed, failed: failed, blocked: blocked,
                                          obstacles: obstacles, escalation: escalation,
                                          freedBytes: totalTrashed)
        TrashService.presentToast(summary) { [weak self] in
            let n = TrashService.restore(trashed, recordingUndoOf: record)
            TrashService.presentRestore(n)
            if n > 0 { self?.scan() }
        }
    }
}
