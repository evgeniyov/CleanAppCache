import Foundation
import SwiftUI

@MainActor
public final class PrivacyViewModel: ObservableObject {
    @Published public var browsers: [BrowserEntry] = []
    @Published public var isScanning = false
    @Published public var hasScanned = false
    @Published public var clearingID: String?

    private let manager = PrivacyManager.shared

    public init() {}

    public func scan() {
        guard clearingID == nil else { return }
        guard !isScanning else { return }
        isScanning = true
        Task {
            let result = await manager.scan()
            self.browsers = result
            self.isScanning = false
            self.hasScanned = true
        }
    }

    public func clearHistory(for entry: BrowserEntry) async {
        guard !isScanning, clearingID == nil else { return }
        guard !entry.isRunning else { return }
        clearingID = entry.id
        let (freed, failed, cleared) = await manager.clearHistory(for: entry)
        clearingID = nil

        // Browser profiles live under ~/Library — expire the cached sizes for
        // the folders that just shrank so the Storage tab doesn't keep showing
        // pre-cleanup numbers (same site pattern as every other delete path).
        if cleared > 0 {
            await StorageManager.shared.invalidate(deleted: entry.allFiles)
        }

        // Gated on what was cleared, not on bytes: Firefox history cleared
        // inside its database frees next to nothing and still happened. The
        // volume line appears only when there is a volume to report.
        let loc = Localizer.shared
        if cleared > 0 {
            ToastCenter.shared.success(
                loc.f("privacy.clearedFmt", entry.name),
                freed > 0 ? loc.f("privacy.freedFmt", Fmt.bytes(Int64(freed))) : nil
            )
        }
        if failed > 0 {
            ToastCenter.shared.error(loc.f("privacy.failedFmt", entry.name))
        }

        // Refresh to reflect cleared state
        scan()
    }

    public var totalHistorySize: UInt64 {
        browsers.reduce(0) { $0 + $1.totalSize }
    }

    public var formattedTotalSize: String {
        Fmt.bytes(Int64(totalHistorySize))
    }
}
