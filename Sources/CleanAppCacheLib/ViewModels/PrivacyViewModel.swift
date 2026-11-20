import AppKit
import Foundation
import SwiftUI

@MainActor
public final class PrivacyViewModel: ObservableObject {
    @Published public var browsers: [BrowserEntry] = []
    @Published public var isScanning = false
    @Published public var hasScanned = false
    @Published public private(set) var isClearing = false

    private let manager = PrivacyManager.shared
    private let scanBrowsers: @Sendable () async -> [BrowserEntry]
    private let invalidateStorage: @Sendable ([URL]) async -> Void
    private let isRunning: (String) -> Bool
    private let requestQuit: (String) -> Void

    public convenience init() {
        self.init(scan: { await PrivacyManager.shared.scan() },
                  invalidateStorage: { await StorageManager.shared.invalidate(deleted: $0) },
                  isRunning: { PrivacyManager.blockingProcess(for: $0) != nil },
                  requestQuit: { bundleID in
                      NSWorkspace.shared.runningApplications.first {
                          $0.bundleIdentifier == bundleID && !$0.isTerminated
                      }?.terminate()
                  })
    }

    init(scan: @escaping @Sendable () async -> [BrowserEntry],
         invalidateStorage: @escaping @Sendable ([URL]) async -> Void,
         isRunning: @escaping (String) -> Bool,
         requestQuit: @escaping (String) -> Void) {
        self.scanBrowsers = scan
        self.invalidateStorage = invalidateStorage
        self.isRunning = isRunning
        self.requestQuit = requestQuit
    }

    public func scan() {
        guard !isScanning, !isClearing else { return }
        isScanning = true
        Task { await refreshBrowsers() }
    }

    private func refreshBrowsers() async {
        browsers = await scanBrowsers()
        hasScanned = true
        isScanning = false
    }

    @discardableResult
    func clearHistory(for entries: [BrowserEntry], authorizedToQuit: Set<String>) async -> Bool {
        guard !entries.isEmpty, !isScanning, !isClearing else { return false }
        isClearing = true
        defer { isClearing = false }

        let loc = Localizer.shared
        var changed: [URL] = []
        for entry in entries {
            if isRunning(entry.id) {
                guard authorizedToQuit.contains(entry.id) else {
                    ToastCenter.shared.error(loc.f("privacy.startedFmt", entry.name))
                    continue
                }
                // A quit request gives the browser a chance to save or refuse.
                requestQuit(entry.id)
                guard await waitForExit(of: entry.id) else {
                    ToastCenter.shared.error(loc.f("privacy.quitFailedFmt", entry.name))
                    continue
                }
            }

            var ready = entry
            ready.isRunning = false
            let (freed, failed, cleared) = await manager.clearHistory(for: ready)
            if cleared > 0 { changed += entry.allFiles }

            let size = freed > 0 ? loc.f("privacy.freedFmt", Fmt.bytes(freed)) : nil
            if cleared > 0 && failed > 0 {
                ToastCenter.shared.show(Toast(style: .warning, title: loc.f("privacy.partialFmt", entry.name),
                                              message: size))
            } else if cleared > 0 {
                ToastCenter.shared.success(loc.f("privacy.clearedFmt", entry.name), size)
            } else if failed > 0 {
                ToastCenter.shared.error(loc.f("privacy.failedFmt", entry.name))
            } else {
                ToastCenter.shared.show(Toast(style: .info, title: loc.f("privacy.alreadyClearFmt", entry.name)))
            }
        }
        if !changed.isEmpty { await invalidateStorage(changed) }
        isScanning = true
        await refreshBrowsers()
        return true
    }

    /// Helper processes can continue holding the profile after the main app quits.
    private func waitForExit(of bundleID: String) async -> Bool {
        for _ in 0..<40 {
            if !isRunning(bundleID) { return true }
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return false }
        }
        return !isRunning(bundleID)
    }

    var skipped: ScanSkipSummary {
        var summary = ScanSkipSummary()
        for browser in browsers {
            for url in browser.unreadableHistoryDatabases { summary.record(url, reason: .unreadable) }
        }
        return summary
    }

    public var totalHistorySize: UInt64 {
        browsers.reduce(0) { $0 + $1.totalSize }
    }

    public var formattedTotalSize: String {
        Fmt.bytes(Int64(totalHistorySize))
    }
}
