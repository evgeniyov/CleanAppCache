import Foundation

/// One directory per process: a slow sibling never holds completed results in
/// a batch. The owner cancels only its own process, including a launch race.
enum DirectorySizeProbe {
    struct Measurement: Sendable {
        let bytes: UInt64?
        let complete: Bool
    }

    static func measure(_ urls: [URL], timeout: TimeInterval) async -> [String: UInt64] {
        var sizes: [String: UInt64] = [:]
        for url in urls {
            guard !Task.isCancelled else { break }
            let measured = await measureRoot(url, timeout: timeout)
            if measured.complete { sizes[url.path] = measured.bytes }
        }
        return sizes
    }

    static func measureRoot(_ url: URL, timeout: TimeInterval) async -> Measurement {
        guard let response = await captureResponse(executable: URL(fileURLWithPath: "/usr/bin/du"),
            arguments: ["-skx", url.path], timeout: timeout) else {
            return Measurement(bytes: nil, complete: false)
        }
        let output = String(decoding: response.data, as: UTF8.self)
        // Match the entire operand, including any literal line breaks.
        guard let tab = output.firstIndex(of: "\t"),
              output[output.index(after: tab)...] == url.path + "\n",
              let kb = UInt64(output[..<tab].trimmingCharacters(in: .whitespaces)),
              kb <= UInt64(Int64.max) / 1024 else {
            return Measurement(bytes: nil, complete: false)
        }
        return Measurement(bytes: kb * 1024, complete: response.succeeded)
    }

    static func measureConcurrently<T: Sendable>(
        _ urls: [URL], deadline: DispatchTime, parallelism: Int,
        measure: @escaping @Sendable (URL, TimeInterval) async -> T?
    ) async -> [String: T] {
        await withTaskGroup(of: (String, T?).self) { group in
            var pending = urls.makeIterator()
            var results: [String: T] = [:]
            func launchNext() {
                guard !Task.isCancelled, DispatchTime.now() < deadline, let url = pending.next() else { return }
                group.addTask {
                    let now = DispatchTime.now().uptimeNanoseconds
                    guard !Task.isCancelled, now < deadline.uptimeNanoseconds else { return (url.path, nil) }
                    let timeout = Double(deadline.uptimeNanoseconds - now) / 1_000_000_000
                    return (url.path, await measure(url, timeout))
                }
            }
            for _ in 0..<min(parallelism, urls.count) { launchNext() }
            while let (path, result) = await group.next() {
                if Task.isCancelled { group.cancelAll(); return [:] }
                results[path] = result
                launchNext()
            }
            return results
        }
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
        let exited: Bool
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
                                diagnostics: diagnostics.data, timedOut: owner.timedOut,
                                exited: process.terminationReason == .exit)
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
