import Foundation

/// One directory per process: a slow sibling never holds completed results in
/// a batch. The owner cancels only its own process, including a launch race.
enum DirectorySizeProbe {
    static func measure(_ urls: [URL], timeout: TimeInterval) async -> [String: UInt64] {
        var sizes: [String: UInt64] = [:]
        for url in urls {
            guard !Task.isCancelled else { break }
            guard let data = await capture(executable: URL(fileURLWithPath: "/usr/bin/du"),
                                          arguments: ["-skx", url.path], timeout: timeout) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            // One literal path, so newlines in its name cannot forge a map key.
            guard let tab = text.firstIndex(of: "\t"),
                  let kb = UInt64(text[..<tab].trimmingCharacters(in: .whitespacesAndNewlines)),
                  kb <= UInt64.max / 1024 else { continue }
            sizes[url.path] = kb * 1024
        }
        return sizes
    }

    static func capture(executable: URL, arguments: [String], timeout: TimeInterval) async -> Data? {
        guard let response = await captureResponse(executable: executable, arguments: arguments, timeout: timeout),
              response.succeeded else { return nil }
        return response.data
    }

    struct Response: Sendable {
        let data: Data
        let succeeded: Bool
        let diagnostics: Data
        let timedOut: Bool
    }

    /// A failed traversal can still return lower bounds for readable roots.
    static func captureResponse(executable: URL, arguments: [String], timeout: TimeInterval) async -> Response? {
        let owner = ProcessOwner()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                let errorPipe = Pipe()
                process.standardError = errorPipe
                let diagnostics = DiagnosticCapture(handle: errorPipe.fileHandleForReading)
                let drained = DispatchGroup()
                do { guard try owner.start(process) else { return nil } }
                catch { return nil }
                drained.enter()
                DispatchQueue.global(qos: .utility).async {
                    diagnostics.drain()
                    drained.leave()
                }
                let watchdog = DispatchWorkItem { owner.cancel(timedOut: true) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                // Drain before waiting, even when a caller captures large output.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                await withCheckedContinuation { continuation in
                    drained.notify(queue: .global(qos: .utility)) { continuation.resume(returning: ()) }
                }
                owner.finish()
                guard !owner.isCancelled || owner.timedOut else { return nil }
                return Response(data: data, succeeded: !owner.timedOut && process.terminationStatus == 0,
                                diagnostics: diagnostics.data, timedOut: owner.timedOut)
            }.value
        } onCancel: {
            owner.cancel()
        }
    }

    /// Drain the second pipe concurrently to avoid a full stderr pipe blocking
    /// stdout. Keep diagnostics bounded without ever mixing them into sizes.
    private final class DiagnosticCapture: @unchecked Sendable {
        let handle: FileHandle
        private(set) var data = Data()
        init(handle: FileHandle) { self.handle = handle }
        func drain() {
            while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
                if data.count < 65_536 { data.append(chunk.prefix(65_536 - data.count)) }
            }
        }
    }

    private final class ProcessOwner: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var timeoutReached = false
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return timeoutReached }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        func start(_ process: Process) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            self.process = process
            try process.run()
            return true
        }
        func finish() { lock.lock(); process = nil; lock.unlock() }
        func cancel(timedOut: Bool = false) {
            lock.lock(); cancelled = true; timeoutReached = timeoutReached || timedOut; let running = process; lock.unlock()
            if let running, running.isRunning { running.terminate() }
        }
    }
}
