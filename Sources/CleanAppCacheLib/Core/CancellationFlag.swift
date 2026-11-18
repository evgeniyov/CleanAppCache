import Foundation

/// A thread-safe boolean that can be flipped from anywhere and read from a
/// `nonisolated` context.
///
/// Actor-isolated `var isCancelled` looks like cancellation support but isn't:
/// the worker that should observe it usually runs `nonisolated`, and the
/// `cancel()` message cannot even be delivered while the actor is busy running
/// the scan the caller is trying to stop.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        value = false
        lock.unlock()
    }
}
