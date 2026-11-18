import Foundation
import SwiftUI

@MainActor
public final class LeftoversViewModel: ObservableObject {
    @Published public var groups: [LeftoverGroup] = []
    @Published public var isScanning = false
    @Published public private(set) var isDeleting = false
    @Published public var hasScanned = false

    private let manager = LeftoversManager.shared

    private var scanGeneration = UUID()

    public init() {}

    public var totalBytes: UInt64 { groups.reduce(0) { $0 + $1.totalBytes } }
    public var formattedTotal: String {
        Fmt.bytes(Int64(totalBytes))
    }

    public func scan() {
        guard !isScanning, !isDeleting else { return }
        scanGeneration = UUID()
        isScanning = true
        hasScanned = true
        Task {
            let result = await manager.scan()
            self.groups = result
            self.isScanning = false
        }
    }

    /// Moves the groups' files to the Trash in one batch — one password
    /// prompt if any need one, one toast, one History record.
    ///
    /// A group leaves the list only once all its files are gone; a group
    /// that lost some keeps the survivors, so what stayed on disk stays in
    /// view.
    public func delete(_ chosen: [LeftoverGroup]) {
        guard !isDeleting, !isScanning else { return }
        let files = chosen.flatMap(\.files)
        guard !files.isEmpty else { return }
        let sizes = Dictionary(files.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
        // Strong on purpose: once the files are in the Trash, the history entry
        // and the Undo toast must follow. Only the toast's action, which
        // ToastCenter keeps for seconds, holds the view model weakly.
        let generation = scanGeneration
        isDeleting = true
        Task { [self] in
            defer { isDeleting = false }
            let validation = await manager.removalValidator(for: chosen)
            let result = await TrashService.trashEscalating(files.map(\.url), knownSizes: sizes,
                validationObstacle: .changedSinceScan, validation: validation)
            let gone = Set(result.trashed.map(\.original) + result.alreadyGone)
            if !gone.isEmpty {
                // Leftovers live under ~/Library (Caches among them, a Storage
                // breakdown scan target) — expire the cached sizes or the
                // Storage tab keeps the pre-delete numbers for up to an hour.
                await StorageManager.shared.invalidate(deleted: Array(gone))
            }
            let before = self.groups
            self.groups = before.compactMap { group in
                guard chosen.contains(where: { $0.id == group.id }) else { return group }
                let left = group.files.filter { !gone.contains($0.url) }
                guard !left.isEmpty else { return nil }
                return LeftoverGroup(id: group.id, displayName: group.displayName, files: left,
                                     totalBytes: left.reduce(0) { $0 + $1.size },
                                     uncertain: group.uncertain)
            }
            let record = CleanupHistory.shared.log(.leftovers, items: result.count, trashedBytes: result.freedBytes)
            TrashService.presentToast(result) { [weak self] in
                let n = TrashService.restore(result.trashed, recordingUndoOf: record)
                if n > 0, let self, self.scanGeneration == generation, !self.isScanning, !self.isDeleting {
                    self.groups = before.compactMap { group in
                        let files = group.files.filter { !RemovalCheck.isMissing($0.url) }
                        guard !files.isEmpty else { return nil }
                        return LeftoverGroup(id: group.id, displayName: group.displayName, files: files,
                                             totalBytes: files.reduce(0) { $0 + $1.size }, uncertain: group.uncertain)
                    }
                }
                TrashService.presentRestore(n)
            }
        }
    }
}
