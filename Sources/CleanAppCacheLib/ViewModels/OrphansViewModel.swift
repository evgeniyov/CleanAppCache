import Foundation
import AppKit

@MainActor
public final class OrphansViewModel: ObservableObject {
    @Published public var items: [OrphanItem] = []
    @Published public var isScanning = false
    @Published public private(set) var isDeleting = false
    @Published public var hasScanned = false

    private let scanner = OrphanScanner.shared

    private var scanGeneration = UUID()

    public init() {}

    public func scan() {
        guard !isScanning, !isDeleting else { return }
        scanGeneration = UUID()
        isScanning = true
        hasScanned = true
        Task {
            let found = await scanner.scan()
            self.items = found
            self.isScanning = false
        }
    }

    /// Moves the orphans to the Trash in one batch. Items under `/Library`
    /// go through Finder, which asks for an administrator password; the
    /// confirmation says so beforehand. launchd keeps a removed job loaded
    /// until the next restart or logout, which is when it stops launching.
    public func remove(_ chosen: [OrphanItem]) {
        guard !isDeleting, !isScanning else { return }
        guard !chosen.isEmpty else { return }
        let sizes = Dictionary(chosen.map { ($0.url, $0.size) }, uniquingKeysWith: { a, _ in a })
        let generation = scanGeneration
        isDeleting = true
        Task { [self] in
            defer { isDeleting = false }
            let validation = await scanner.removalValidator(for: chosen)
            let urls = Array(Set(chosen.map(\.url)))
            let result = await TrashService.trashEscalating(urls, knownSizes: sizes,
                                                           allowing: [.launchdJob],
                                                           validationObstacle: .changedSinceScan, validation: validation)
            let gone = Set(result.trashed.map(\.original) + result.alreadyGone)
            let before = self.items
            self.items.removeAll { gone.contains($0.url) }
            let record = CleanupHistory.shared.log(.orphans, items: result.count, trashedBytes: result.freedBytes)
            TrashService.presentToast(result) { [weak self] in
                let n = TrashService.restore(result.trashed, recordingUndoOf: record)
                if n > 0, let self, self.scanGeneration == generation, !self.isScanning, !self.isDeleting {
                    let existing = Set(self.items.map(\.url))
                    self.items.append(contentsOf: before.filter { !existing.contains($0.url) && !RemovalCheck.isMissing($0.url) })
                }
                TrashService.presentRestore(n)
            }
        }
    }

    public func revealInFinder(_ item: OrphanItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    public var userCount: Int { items.filter { !$0.needsAdmin }.count }
}
