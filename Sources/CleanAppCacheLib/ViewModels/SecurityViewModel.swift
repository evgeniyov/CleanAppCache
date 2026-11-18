import Foundation
import AppKit

@MainActor
public final class SecurityViewModel: ObservableObject {
    @Published public var checks: [SecurityCheck] = []
    @Published public var isRunning = false
    @Published public var hasRun = false

    private let manager = SecurityAuditManager.shared

    public init() {}

    public func run() {
        guard !isRunning else { return }
        isRunning = true
        hasRun = true
        Task {
            let result = await manager.runAudit()
            // Sort worst-first so problems are on top.
            self.checks = result.sorted { rank($0.status) < rank($1.status) }
            self.isRunning = false
        }
    }

    private func rank(_ s: SecurityCheck.Status) -> Int {
        switch s {
        case .fail: return 0
        case .warn: return 1
        case .unknown: return 2
        case .pass: return 3
        }
    }

    // MARK: - Summary

    public var passCount: Int { checks.filter { $0.status == .pass }.count }
    public var failCount: Int { checks.filter { $0.status == .fail }.count }
    public var warnCount: Int { checks.filter { $0.status == .warn }.count }

    /// 0…100: 100 − 16 per critical finding − 6 per warning.
    ///
    /// Not the share of checks that passed, because that number moves when a
    /// check could not be *run*: on a Mac where two probes return `unknown` the
    /// denominator shrinks and every remaining pass is worth more, so the score
    /// would rise for a machine we know less about. A fixed penalty per finding
    /// only moves when a finding does.
    ///
    /// Unknowns cost nothing here — "we could not determine this" is not a
    /// finding — but they are still surfaced on the row, which is where the
    /// honest signal belongs.
    public var score: Int {
        max(0, 100 - 16 * failCount - 6 * warnCount)
    }

    public func openSettings(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
