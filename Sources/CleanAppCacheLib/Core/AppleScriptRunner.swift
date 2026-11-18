import Foundation

/// Runs AppleScript in an `osascript` child process.
///
/// A child process rather than `NSAppleScript`: the scripts here wait on
/// dialogs the user answers at their own pace (an administrator password,
/// Finder's authentication), and `NSAppleScript` blocks the thread it runs on
/// — the main thread, where it is meant to run — for that whole time. Paths
/// travel as `argv`, never spliced into the script source, so no quoting bug
/// can turn a file name into code.
enum AppleScriptRunner {

    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool

        var succeeded: Bool { status == 0 && !timedOut }

        /// The AppleScript error number osascript prints at the end of its
        /// error line ("… execution error: … (-128)"), if any.
        var errorNumber: Int? {
            guard let open = stderr.lastIndex(of: "("),
                  let close = stderr.lastIndex(of: ")"), open < close else { return nil }
            return Int(stderr[stderr.index(after: open)..<close])
        }

        /// The user dismissed a password or authentication dialog.
        var userCancelled: Bool { errorNumber == -128 }

        /// macOS refused to let this app send Apple Events to the target
        /// (Privacy & Security → Automation).
        var automationDenied: Bool { errorNumber == -1743 }
    }

    /// Long enough for a user to read a password dialog, fetch the password
    /// and type it; short enough that a wedged Finder does not hold a cleanup
    /// forever.
    static let interactiveTimeout: TimeInterval = 600

    /// Runs `source` with `arguments` as the `argv` of its `on run` handler.
    /// Blocks the calling thread until the script ends; never call it on the
    /// main thread.
    static func run(_ source: String, arguments: [String], timeout: TimeInterval = interactiveTimeout) -> Output {
        guard !AppPaths.isTesting else {
            return Output(status: -1, stdout: "", stderr: "AppleScript is disabled in XCTest", timedOut: false)
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        var args: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            args += ["-e", String(line)]
        }
        task.arguments = args + arguments
        let out = Pipe()
        let err = Pipe()
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch {
            return Output(status: -1, stdout: "", stderr: error.localizedDescription, timedOut: false)
        }

        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            if task.isRunning { timedOut.set(); task.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // stderr is drained on its own thread: reading the two pipes one after
        // the other deadlocks once the unread one fills its buffer.
        let errData = ErrorBuffer()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        task.waitUntilExit()
        watchdog.cancel()

        return Output(
            status: task.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: String(decoding: errData.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            timedOut: timedOut.isSet
        )
    }

    /// Runs a shell command as root. macOS shows its own administrator
    /// dialog with `prompt` as the explanation; nothing runs unless the user
    /// authenticates there.
    ///
    /// This is the app's only way to act as root. Callers build `command` from
    /// validated paths quoted with `shellQuoted`, and state in their
    /// confirmation that a password will be asked for.
    static func runPrivileged(_ command: String, prompt: String) -> Output {
        // An hour: the dialog's wait plus a root `rm` of a large bundle. The
        // watchdog ending osascript would not end a shell it started, and the
        // result would call "failed" what is then deleted anyway.
        run("""
        on run argv
            with timeout of 3600 seconds
                do shell script (item 2 of argv) with prompt (item 1 of argv) with administrator privileges
            end timeout
        end run
        """, arguments: [prompt, command], timeout: 3600)
    }

    /// `value` as a single shell word: wrapped in single quotes, with every
    /// embedded quote closed, escaped and reopened.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Cross-thread boxes

    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Written once by the draining thread before `group.leave()`, read after
    /// `group.wait()`; the group orders the two accesses.
    private final class ErrorBuffer: @unchecked Sendable {
        var data = Data()
    }
}
