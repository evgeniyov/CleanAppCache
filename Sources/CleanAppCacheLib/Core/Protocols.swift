import Foundation

// MARK: - DI Protocols
//
// Lightweight protocol layer so ViewModels can be injected with mock
// implementations in tests without changing singleton call sites.

// MARK: ScannerProtocol

/// Anything that can run a full disk scan and report progress.
/// Used by DashboardViewModel so the scanner is swappable in tests.
public protocol ScannerProtocol: Sendable {
    func performFullScan(
        progressHandler: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResult

    /// Signal an in-progress scan to stop early.
    func cancel() async
}

// Scanner (actor) satisfies ScannerProtocol automatically:
// - actor methods are implicitly async when called from outside
// - actors are Sendable by default
extension Scanner: ScannerProtocol {}
