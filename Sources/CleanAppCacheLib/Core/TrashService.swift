import Foundation
import CoreServices
import Darwin

/// Moves files to the Trash (recoverable) and can restore them. This is the
/// safety net for user-facing cleanups: nothing is destroyed outright, and
/// every delete can be undone until the user empties the Trash.
public enum TrashService {

    public struct Trashed: Sendable {
        public let original: URL
        public let trashed: URL
        /// Moved by Finder after an administrator password. Putting it back
        /// needs the same rights, so Undo leaves it to Finder's "Put Back".
        public let viaFinder: Bool
        /// Fresh allocated bytes moved, used to account for partial Undo.
        public let movedBytes: UInt64
        let parentURL: URL
        let parentIdentity: FileSnapshot?
        let trashedIdentity: FileSnapshot?

        public init(original: URL, trashed: URL, viaFinder: Bool = false, movedBytes: UInt64 = 0) {
            self.movedBytes = movedBytes
            self.original = original
            self.trashed = trashed
            self.viaFinder = viaFinder
            parentURL = original.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            parentIdentity = FileSnapshot(at: parentURL)
            trashedIdentity = FileSnapshot(at: trashed)
        }

        init(original: URL, trashed: URL, parentURL: URL, parentIdentity: FileSnapshot?,
             trashedIdentity: FileSnapshot?, movedBytes: UInt64) {
            self.movedBytes = movedBytes
            self.original = original; self.trashed = trashed; viaFinder = false
            self.parentURL = parentURL; self.parentIdentity = parentIdentity
            self.trashedIdentity = trashedIdentity
        }
    }

    public struct Result: Sendable {
        public let trashed: [Trashed]
        public let failed: [URL]
        /// Refused by `PathGuard` before any filesystem call was made.
        public let blocked: [URL]
        /// Gone before the move was attempted — removed by its owner since the
        /// scan. Neither moved nor failed: what the user asked for is true.
        public let alreadyGone: [URL]
        /// Why each URL in `failed` was refused.
        public let obstacles: [URL: RemovalObstacle]
        public let validationRejected: [URL]
        /// How the hand-off of protected items to Finder ended, when there
        /// was one.
        public let escalation: EscalationOutcome?
        public var freedBytes: UInt64

        public var count: Int { trashed.count }
        public var formattedFreed: String {
            Fmt.bytes(Int64(freedBytes))
        }

        public init(trashed: [Trashed], failed: [URL], blocked: [URL] = [],
                    alreadyGone: [URL] = [], obstacles: [URL: RemovalObstacle] = [:],
                    validationRejected: [URL] = [],
                    escalation: EscalationOutcome? = nil, freedBytes: UInt64) {
            self.trashed = trashed
            self.failed = failed
            self.blocked = blocked
            self.alreadyGone = alreadyGone
            self.obstacles = obstacles
            self.validationRejected = validationRejected
            self.escalation = escalation
            self.freedBytes = freedBytes
        }
    }

    /// Move the given URLs to the Trash. Returns what succeeded (with the
    /// in-Trash location, for undo), what failed and why, and the bytes moved.
    ///
    /// Screened by `PathGuard` for the same reason `DeletionService` is: the
    /// Trash is recoverable, but moving `~/Library/Mobile Documents` into it
    /// still propagates a deletion to every device the user owns.
    ///
    /// Scan-time `knownSizes` is only a compatibility hint. Accounting always
    /// measures the current object, because the scan may be hours old.
    public static func trash(_ urls: [URL], knownSizes: [URL: UInt64] = [:],
                             allowing: Set<PathGuard.Allowance> = [],
                             validationObstacle: RemovalObstacle = .inUse,
                             validation: (URL) -> Bool = { _ in true }) -> Result {
        trash(urls, allowing: allowing, validationObstacle: validationObstacle,
              validation: validation, mover: moveToTrash)
    }

    private static func moveToTrash(_ url: URL) throws -> URL {
        guard !AppPaths.isTesting else {
            throw NSError(domain: "CleanAppCache.Tests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Tests must inject a scratch Trash"])
        }
        var dest: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &dest)
        return (dest as URL?) ?? url
    }

    /// Tests use the same validation and accounting with a move inside their scratch directory.
    static func trash(_ urls: [URL], allowing: Set<PathGuard.Allowance> = [],
                      validationObstacle: RemovalObstacle = .inUse,
                      validation: (URL) -> Bool = { _ in true },
                      identities suppliedIdentities: [URL: RemovalIdentity]? = nil,
                      mover: (URL) throws -> URL) -> Result {
        let fm = FileManager.default
        let verdict = PathGuard.filter(urls, allowing: allowing)
        let identities = suppliedIdentities ?? RemovalIdentity.capture(verdict.allowed)
        var ok: [Trashed] = []
        var failed: [URL] = []
        var gone: [URL] = []
        var rejected: [URL] = []
        var obstacles: [URL: RemovalObstacle] = [:]
        var freed: UInt64 = 0
        var blocked = verdict.blocked.map(\.url)

        for (url, reason) in verdict.blocked {
            Log.error("PathGuard refused trashing \(url.path): \(reason)")
        }

        for url in verdict.allowed {
            if RemovalCheck.isMissing(url) {
                gone.append(url)
                continue
            }
            guard let identity = identities[url], identity.matches(url) else {
                rejected.append(url)
                failed.append(url)
                obstacles[url] = .changedSinceScan
                continue
            }
            let size = (try? fm.allocatedSize(of: URL(fileURLWithPath: url.path))) ?? 0
            if PathGuard.rejectTree(url, allowing: allowing) != nil {
                blocked.append(url)
                continue
            }
            guard validation(url) else {
                rejected.append(url)
                failed.append(url)
                obstacles[url] = validationObstacle
                continue
            }
            guard identity.matches(url) else {
                rejected.append(url)
                failed.append(url)
                obstacles[url] = .changedSinceScan
                continue
            }
            // Pin the selected object before moving: the returned Trash path
            // may already hold a replacement when the mover finishes.
            do {
                let dest = try mover(url)
                ok.append(Trashed(original: url, trashed: dest,
                                  parentURL: identity.parent.standardizedFileURL.resolvingSymlinksInPath(),
                                  parentIdentity: identity.parentObject, trashedIdentity: identity.object, movedBytes: size))
                freed += size
            } catch {
                let obstacle = RemovalCheck.classify(error, at: url, permanent: false)
                Log.error("Trash failed for \(url.path) [\(obstacle.rawValue)]: \(error.localizedDescription)")
                failed.append(url)
                obstacles[url] = obstacle
            }
        }
        return Result(
            trashed: ok,
            failed: failed,
            blocked: blocked,
            alreadyGone: gone,
            obstacles: obstacles,
            validationRejected: rejected,
            freedBytes: freed
        )
    }

    /// `trash`, then the items this account may not move are handed to
    /// Finder, which asks for an administrator password and moves them itself.
    ///
    /// Finder rather than a root `mv`: it puts each item where "Put Back"
    /// finds it, and its authentication dialog is the one macOS users already
    /// know for this. Only POSIX refusals are escalated — a privacy refusal or
    /// SIP would refuse Finder too. Runs off the main thread; the dialog can
    /// stay up for as long as the user needs.
    public static func trashEscalating(_ urls: [URL], knownSizes: [URL: UInt64] = [:],
                                       allowing: Set<PathGuard.Allowance> = [],
                                       validationObstacle: RemovalObstacle = .inUse,
                                       validation: @escaping @Sendable (URL) -> Bool = { _ in true }) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let identities = RemovalIdentity.capture(urls)
            let first = trash(urls, allowing: allowing, validationObstacle: validationObstacle,
                              validation: validation, identities: identities, mover: moveToTrash)
            return escalate(first, knownSizes: knownSizes, allowing: allowing,
                            validationObstacle: validationObstacle, validation: validation, identities: identities)
        }.value
    }

    /// The second attempt replaces the first attempt's provisional permission diagnosis.
    static func escalate(_ first: Result, knownSizes: [URL: UInt64], allowing: Set<PathGuard.Allowance>,
                         validationObstacle: RemovalObstacle = .inUse, validation: (URL) -> Bool,
                         identities: [URL: RemovalIdentity]? = nil,
                         dispatch: ([String]) -> AppleScriptRunner.Output = {
                             AppleScriptRunner.run(finderTrashScript, arguments: $0)
                         }) -> Result {
        let protected = first.failed.filter { first.obstacles[$0] == .needsAdmin }
        guard !protected.isEmpty else { return first }
        let viaFinder = trashWithFinder(protected, knownSizes: knownSizes, allowing: allowing,
                                        validationObstacle: validationObstacle, validation: validation,
                                        identities: identities, dispatch: dispatch)
        let resolved = Set(viaFinder.trashed.map(\.original) + viaFinder.blocked + viaFinder.alreadyGone)
        var obstacles = first.obstacles
        obstacles.merge(viaFinder.obstacles) { _, new in new }
        for url in resolved { obstacles[url] = nil }
        return Result(
            trashed: first.trashed + viaFinder.trashed,
            failed: first.failed.filter { !resolved.contains($0) },
            blocked: first.blocked + viaFinder.blocked,
            alreadyGone: first.alreadyGone + viaFinder.alreadyGone,
            obstacles: obstacles,
            validationRejected: first.validationRejected + viaFinder.validationRejected,
            escalation: viaFinder.escalation,
            freedBytes: first.freedBytes + viaFinder.freedBytes
        )
    }

    /// Asks Finder to move `urls` to the Trash in one command, so one
    /// password covers the batch. Blocks until Finder answers.
    static func trashWithFinder(_ urls: [URL], knownSizes: [URL: UInt64],
                                allowing: Set<PathGuard.Allowance>,
                                validationObstacle: RemovalObstacle = .inUse, validation: (URL) -> Bool,
                                identities suppliedIdentities: [URL: RemovalIdentity]? = nil,
                                dispatch: ([String]) -> AppleScriptRunner.Output = {
                                    AppleScriptRunner.run(finderTrashScript, arguments: $0)
                                }) -> Result {
        let fm = FileManager.default
        let identities = suppliedIdentities ?? RemovalIdentity.capture(urls)
        // Measure safe candidates first, then classify every input again at dispatch.
        // Excluded paths must replace the original needsAdmin diagnosis, not silently disappear.
        let candidates = PathGuard.filter(urls, allowing: allowing).allowed
            .filter { PathGuard.rejectTree($0, allowing: allowing) == nil }
            .filter { !RemovalCheck.isMissing($0) && !RemovalCheck.isSymlink($0) }
        let measured = Dictionary(candidates.map { ($0, (try? fm.allocatedSize(of: URL(fileURLWithPath: $0.path))) ?? 0) },
                                  uniquingKeysWith: { first, _ in first })
        // Finder cannot re-run this predicate while its password dialog is open.
        var rejected: [URL] = []
        var blocked: [URL] = []
        var gone: [URL] = []
        var targets: [URL] = []
        var obstacles: [URL: RemovalObstacle] = [:]
        for url in urls {
            if RemovalCheck.isMissing(url) {
                gone.append(url)
            } else if !validation(url) {
                rejected.append(url)
                obstacles[url] = validationObstacle
            } else if PathGuard.reject(url, allowing: allowing) != nil
                        || PathGuard.rejectTree(url, allowing: allowing) != nil {
                blocked.append(url)
            } else if RemovalCheck.isSymlink(url) {
                // Finder resolves aliases, so even an otherwise allowed link cannot be handed off.
                rejected.append(url)
                obstacles[url] = .changedSinceScan
            } else if identities[url]?.matches(url) != true {
                rejected.append(url)
                obstacles[url] = .changedSinceScan
            } else {
                targets.append(url)
            }
        }
        // A later item's validation may outlast an earlier item's identity
        // check. Recheck the whole batch at the Finder dispatch boundary.
        targets = targets.filter { url in
            guard identities[url]?.matches(url) == true else {
                rejected.append(url)
                obstacles[url] = .changedSinceScan
                return false
            }
            return true
        }
        guard !targets.isEmpty else {
            return Result(trashed: [], failed: rejected, blocked: blocked, alreadyGone: gone,
                          obstacles: obstacles, validationRejected: rejected, freedBytes: 0)
        }
        let output = dispatch(targets.map(\.path))
        let escalation: EscalationOutcome
        if output.succeeded { escalation = .completed }
        else if output.userCancelled { escalation = .cancelled }
        else if output.automationDenied { escalation = .automationDenied }
        else {
            escalation = .failed
            Log.error("Finder could not move \(targets.count) item(s) to the Trash: \(output.stderr)")
        }

        // A successful reply contains one NUL-terminated destination per item.
        // Names may contain newlines and trailing whitespace, so line splitting
        // or guessing a missing receipt cannot establish a move.
        let fields = output.stdout.split(separator: "\0", omittingEmptySubsequences: false)
        let hasReceipts = output.succeeded && fields.count == targets.count + 1
            && fields.last?.isEmpty == true && fields.dropLast().allSatisfy { $0.hasPrefix("/") }
        let locations = hasReceipts ? fields.dropLast().map { URL(fileURLWithPath: String($0)) } : []
        var trashed: [Trashed] = []
        var freed: UInt64 = 0
        var failed = rejected
        for (index, url) in targets.enumerated() {
            guard RemovalCheck.isMissing(url) else {
                failed.append(url)
                obstacles[url] = finderObstacle(output, at: url)
                continue
            }
            guard hasReceipts, let selected = identities[url]?.object else {
                gone.append(url)
                continue
            }
            let location = locations[index]
            let destination = FileSnapshot(at: location)
            let metadataError = errno
            let size: UInt64
            if let destination {
                guard selected.device == destination.device, selected.inode == destination.inode,
                      selected.mode & S_IFMT == destination.mode & S_IFMT else {
                    gone.append(url)
                    continue
                }
                size = measured[url] ?? 0
            } else if metadataError == EACCES || metadataError == EPERM {
                // Finder's receipt still establishes the move when this account
                // cannot inspect its Trash. Its bytes remain unverified.
                size = 0
            } else {
                gone.append(url)
                continue
            }
            trashed.append(Trashed(original: url, trashed: location, viaFinder: true, movedBytes: size))
            freed += size
        }
        return Result(trashed: trashed, failed: failed, blocked: blocked, alreadyGone: gone,
                      obstacles: obstacles, validationRejected: rejected, escalation: escalation, freedBytes: freed)
    }

    private static func finderObstacle(_ output: AppleScriptRunner.Output, at url: URL) -> RemovalObstacle {
        let currentObstacle = RemovalCheck.trashObstacle(at: url)
        if let currentObstacle, currentObstacle != .needsAdmin && currentObstacle != .other { return currentObstacle }
        if output.userCancelled || output.automationDenied { return .needsAdmin }
        switch output.errorNumber {
        case Int(fLckdErr): return .locked
        case Int(wPrErr), Int(vLckdErr), Int(afpVolLocked): return .systemProtected
        case Int(fBsyErr), Int(opWrErr): return .inUse
        case Int(permErr), Int(wrPermErr), Int(afpAccessDenied):
            return currentObstacle ?? .privacyProtected
        default:
            if output.stderr.localizedCaseInsensitiveContains("Operation not permitted") { return .privacyProtected }
            return .other
        }
    }

    /// `argv` holds POSIX paths. Every item is coerced to an alias first, so a
    /// path that vanished fails the script before Finder moves anything.
    private static let finderTrashScript = """
    on run argv
        set theItems to {}
        repeat with p in argv
            set end of theItems to (POSIX file (contents of p) as alias)
        end repeat
        -- AppleScript gives up on Finder after two minutes by default,
        -- which a password dialog easily outlasts.
        with timeout of 600 seconds
            tell application "Finder"
                set moved to delete theItems
            end tell
        end timeout
        if class of moved is not list then set moved to {moved}
        set out to {}
        repeat with x in moved
            set end of out to POSIX path of (x as alias)
        end repeat
        set AppleScript's text item delimiters to character id 0
        return (out as text) & character id 0
    end run
    """

    /// Move already-trashed items back to their original locations. Returns
    /// the number restored. Items Finder moved with an administrator password
    /// are skipped: moving them back needs the same rights, which Finder's
    /// "Put Back" asks for.
    @discardableResult
    public static func restore(_ items: [Trashed]) -> Int {
        restoredItems(items).count
    }

    private static func restoredItems(_ items: [Trashed]) -> [Trashed] {
        let fm = FileManager.default
        var restored: [Trashed] = []
        for item in items where !item.viaFinder {
            let parent = item.original.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            guard PathGuard.reject(item.original) == nil, parent == item.parentURL,
                  item.parentIdentity?.isSameObject(at: parent) == true,
                  item.trashedIdentity?.isSameObject(at: item.trashed) == true else { continue }
            let destination = parent.appendingPathComponent(item.original.lastPathComponent)
            if (try? fm.moveItem(at: item.trashed, to: destination)) != nil {
                restored.append(item)
            }
        }
        return restored
    }

    /// Only successful moves subtract bytes. A repeated callback cannot subtract
    /// them twice, and Finder-only items in the same record remain accounted for.
    @MainActor
    @discardableResult
    public static func restore(_ items: [Trashed], recordingUndoOf record: UUID?) -> Int {
        restore(items, recordingUndoOf: record, history: .shared)
    }

    @MainActor
    @discardableResult
    static func restore(_ items: [Trashed], recordingUndoOf record: UUID?, history: CleanupHistory) -> Int {
        restoreItems(items, recordingUndoOf: record, history: history).count
    }

    @MainActor
    static func restoreItems(_ items: [Trashed], recordingUndoOf record: UUID?, history: CleanupHistory) -> [Trashed] {
        let restored = restoredItems(items)
        let bytes = restored.reduce(UInt64(0)) { $0 &+ $1.movedBytes }
        if !restored.isEmpty { history.undoTrashMoves(record, restoredBytes: bytes) }
        return restored
    }

    // MARK: - Toast helpers

    /// "Moved to Trash" toast with an Undo button, then one toast per kind of
    /// failure.
    @MainActor
    public static func presentToast(_ result: Result, onUndo: @escaping () -> Void) {
        let loc = Localizer.shared
        if result.count > 0 {
            let viaFinder = result.trashed.filter(\.viaFinder).count
            let undoable = viaFinder < result.count
            ToastCenter.shared.show(Toast(
                style: .success,
                title: loc.f("trash.movedFmt", result.count, result.formattedFreed),
                message: viaFinder > 0
                    ? loc.f("trash.viaFinderFmt", Fmt.plural("plural.objects", viaFinder))
                    : nil,
                actionTitle: undoable ? loc.s("trash.undo") : nil,
                duration: 8,
                action: undoable ? onUndo : nil
            ))
        }
        RemovalReport.present(failed: result.failed, obstacles: result.obstacles,
                              escalation: result.escalation, permanent: false)
        // Without this a batch that PathGuard refused in full produced no toast
        // at all: the button appeared to do nothing, with no explanation.
        if !result.blocked.isEmpty {
            ToastCenter.shared.error(loc.f("guard.blockedFmt", Fmt.plural("plural.protectedPaths", result.blocked.count)))
        }
    }

    @MainActor
    public static func presentRestore(_ count: Int) {
        let loc = Localizer.shared
        if count > 0 {
            ToastCenter.shared.success(loc.f("trash.restoredFmt", count))
        } else {
            ToastCenter.shared.error(loc.s("trash.nothingRestored"))
        }
    }
}
