import Foundation
import CryptoKit
import Darwin

/// Scan-time object and parent identities survive sizing, confirmation and authentication.
/// Bundle metadata is also checked because an updater can reuse the bundle directory.
struct RemovalIdentity: Equatable, Sendable {
    let object: FileSnapshot
    let parent: URL
    let parentObject: FileSnapshot
    let checksBundleInfo: Bool
    let bundleInfoDigest: String?

    init?(at url: URL, bundle: Bool = false) {
        guard let object = FileSnapshot(at: url),
              let physical = Self.physicalParent(of: url),
              let parentObject = FileSnapshot(at: physical) else { return nil }
        if bundle && object.mode & S_IFMT != S_IFDIR { return nil }
        self.object = object
        parent = physical
        self.parentObject = parentObject
        checksBundleInfo = bundle
        let info = url.appendingPathComponent("Contents/Info.plist")
        if bundle && !RemovalCheck.isMissing(info) {
            guard let digest = Self.digest(info) else { return nil }
            bundleInfoDigest = digest
        } else {
            bundleInfoDigest = nil
        }
    }

    func matches(_ url: URL) -> Bool {
        guard Self.physicalParent(of: url) == parent,
              parentObject.isSameObject(at: parent), object.isSameObject(at: url) else { return false }
        guard checksBundleInfo else { return true }
        let info = url.appendingPathComponent("Contents/Info.plist")
        if let expected = bundleInfoDigest { return Self.digest(info) == expected }
        return RemovalCheck.isMissing(info)
    }

    /// Capture the batch before sizing or validating any item can delay the rest.
    static func capture(_ urls: [URL]) -> [URL: RemovalIdentity] {
        var identities: [URL: RemovalIdentity] = [:]
        for url in urls where identities[url] == nil { identities[url] = RemovalIdentity(at: url) }
        return identities
    }

    private static func physicalParent(of url: URL) -> URL? {
        guard let pointer = realpath(url.deletingLastPathComponent().path, nil) else { return nil }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer))
    }

    private static func digest(_ url: URL) -> String? {
        guard FileSnapshot(at: url)?.isRegularFile == true,
              let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Permanently deletes files and folders with `removeItem`; nothing goes to
/// the Trash and nothing can be undone.
///
/// `TrashService` is the default route: Smart Cleanup categories, Large Files,
/// Duplicates, Leftovers, Orphans and System Junk move items to the Trash.
/// This service is reserved for deletions that must be permanent: items
/// already in the Trash (Smart Cleanup's Trash category), an uninstalled app's
/// bundle and associated files, browser privacy data, and regenerable
/// developer caches and project build artifacts.
///
/// It is also the app's only way to delete as root (`deleteAsAdministrator`),
/// behind a macOS password dialog and only inside the places
/// `administratorTarget(for:)` accepts.
public enum DeletionService {

    public struct Result: Sendable {
        public let deleted: [URL]
        public let failed: [URL]
        /// Refused by `PathGuard`; no `removeItem` was attempted on these URLs.
        public let blocked: [URL]
        /// Gone before the delete was attempted — removed by its owner since
        /// the scan. Neither deleted here nor failed.
        public let alreadyGone: [URL]
        /// Why each URL in `failed` was refused.
        public let obstacles: [URL: RemovalObstacle]
        /// How the administrator step ended, when there was one.
        public let escalation: EscalationOutcome?
        public var freedBytes: UInt64

        public var formattedFreed: String {
            Fmt.bytes(Int64(freedBytes))
        }

        public init(deleted: [URL], failed: [URL], blocked: [URL] = [],
                    alreadyGone: [URL] = [], obstacles: [URL: RemovalObstacle] = [:],
                    escalation: EscalationOutcome? = nil, freedBytes: UInt64) {
            self.deleted = deleted
            self.failed = failed
            self.blocked = blocked
            self.alreadyGone = alreadyGone
            self.obstacles = obstacles
            self.escalation = escalation
            self.freedBytes = freedBytes
        }
    }

    /// Permanently delete the given URLs. Returns what succeeded, what failed
    /// and why, and how many bytes were actually freed.
    ///
    /// Every URL is screened by `PathGuard` first: a caller bug can cost the
    /// user data that no Undo can bring back, so refusal happens here rather
    /// than being left to each call site.
    ///
    /// Each URL is screened again immediately before its `removeItem`: sizing
    /// earlier items can take seconds, and a path component swapped for a
    /// symlink in that window must not carry the delete somewhere protected.
    ///
    /// Scan-time `knownSizes` never determines the reported reclaimed space.
    /// It is remeasured and remains an estimate when snapshots or clones share blocks.
    public static func delete(_ urls: [URL], knownSizes: [URL: UInt64] = [:],
                              validationObstacle: RemovalObstacle = .inUse,
                              validation: (URL) -> Bool = { _ in true }) -> Result {
        let fm = FileManager.default
        let verdict = PathGuard.filter(urls)
        let identities = RemovalIdentity.capture(verdict.allowed)
        var deleted: [URL] = []
        var failed: [URL] = []
        var gone: [URL] = []
        var obstacles: [URL: RemovalObstacle] = [:]
        var blocked = verdict.blocked.map(\.url)
        var freed: UInt64 = 0

        for (url, reason) in verdict.blocked {
            Log.error("PathGuard refused permanent delete of \(url.path): \(reason)")
        }

        for url in verdict.allowed {
            if RemovalCheck.isMissing(url) {
                gone.append(url)
                continue
            }
            guard let identity = identities[url], identity.matches(url) else {
                failed.append(url)
                obstacles[url] = .changedSinceScan
                continue
            }
            let size = (try? fm.allocatedSize(of: URL(fileURLWithPath: url.path), reclaiming: true)) ?? 0
            // Validation can perform slow I/O, so inspect the tree after it returns.
            guard validation(url) else {
                failed.append(url)
                obstacles[url] = validationObstacle
                continue
            }
            if let reason = PathGuard.rejectTree(url) {
                Log.error("PathGuard refused permanent delete of \(url.path): \(reason)")
                blocked.append(url)
                continue
            }
            guard identity.matches(url) else {
                failed.append(url)
                obstacles[url] = .changedSinceScan
                continue
            }
            do {
                try fm.removeItem(at: url)
                deleted.append(url)
                freed += size
            } catch {
                // A read-only tree this account owns (the Go module cache,
                // some package-manager downloads) refuses unlinking until its
                // directories are writable again — which the owner may do.
                if identity.matches(url), validation(url), identity.matches(url), PathGuard.rejectTree(url) == nil,
                   let repaired = restoreOwnerAccess(in: url, identity: identity) {
                    if identity.matches(url), validation(url), PathGuard.rejectTree(url) == nil, identity.matches(url),
                       (try? fm.removeItem(at: url)) != nil {
                        deleted.append(url)
                        freed += size
                        continue
                    }
                    for directory in repaired { directory.restore() }
                }
                let obstacle = identity.matches(url)
                    ? RemovalCheck.classify(error, at: url, permanent: true) : .changedSinceScan
                Log.error("Permanent delete failed for \(url.path) [\(obstacle.rawValue)]: \(error.localizedDescription)")
                failed.append(url)
                obstacles[url] = obstacle
            }
        }
        return Result(
            deleted: deleted,
            failed: failed,
            blocked: blocked,
            alreadyGone: gone,
            obstacles: obstacles,
            freedBytes: freed
        )
    }

    /// `delete`, then what this account may not remove is deleted as root
    /// after one administrator password — only inside the places
    /// `administratorTarget(for:)` accepts.
    ///
    /// Items that need root from the start skip the first pass: an attempt as
    /// this account would remove what it can and leave a half-deleted tree
    /// behind if the password is then refused. Runs off the main thread; the
    /// dialog can stay up for as long as the user needs.
    public static func deleteEscalating(_ urls: [URL], knownSizes: [URL: UInt64] = [:],
                                        prompt: String) async -> Result {
        await deleteEscalating(urls, knownSizes: knownSizes, prompt: prompt, identities: nil)
    }

    static func deleteEscalating(_ urls: [URL], knownSizes: [URL: UInt64],
                                 prompt: String, identities: [URL: RemovalIdentity]?) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let identities = identities ?? RemovalIdentity.capture(urls)
            let matches: (URL) -> Bool = { url in
                identities[url]?.matches(url) == true
            }
            var direct: [URL] = []
            var asAdmin: [URL] = []
            for url in urls {
                if administratorTarget(for: url) != nil,
                   RemovalCheck.deleteObstacle(at: url) == .needsAdmin, matches(url) {
                    asAdmin.append(url)
                } else {
                    direct.append(url)
                }
            }
            let first = delete(direct, knownSizes: knownSizes,
                               validationObstacle: .changedSinceScan, validation: matches)
            let retry = first.failed.filter {
                first.obstacles[$0] == .needsAdmin && administratorTarget(for: $0) != nil
            }
            let elevated = asAdmin + retry
            guard !elevated.isEmpty else { return first }

            let fm = FileManager.default
            let sizes = Dictionary(elevated.map { ($0, (try? fm.allocatedSize(of: URL(fileURLWithPath: $0.path), reclaiming: true)) ?? 0) },
                                   uniquingKeysWith: { a, _ in a })
            let admin = deleteAsAdministrator(elevated.map { [$0] }, prompt: prompt, identities: identities)
            let attempted = Set(elevated)
            var obstacles = first.obstacles
            for url in elevated { obstacles[url] = admin.obstacles[url] }
            return Result(
                deleted: first.deleted + admin.removed,
                failed: first.failed.filter { !attempted.contains($0) } + admin.failed,
                blocked: first.blocked + admin.refused,
                alreadyGone: first.alreadyGone,
                obstacles: obstacles,
                escalation: admin.outcome,
                freedBytes: first.freedBytes + admin.removed.reduce(0) { $0 + (sizes[$1] ?? 0) }
            )
        }.value
    }

    // MARK: - Administrator deletes

    public struct AdministratorResult: Sendable {
        public let removed: [URL]
        public let failed: [URL]
        /// Outside the places a root delete may reach; never sent to the shell.
        public let refused: [URL]
        public let obstacles: [URL: RemovalObstacle]
        public let outcome: EscalationOutcome
        /// The selected object, parent or verified tree no longer matches preflight.
        public let changed: [URL]
        public let running: [URL]
    }

    /// Deletes `groups` as root after one administrator password, shown with
    /// `prompt` as its explanation. The first entry gates the rest of its
    /// group, so an app's data goes only after its bundle has.
    ///
    /// Every URL must pass `administratorTarget(for:)`; a group whose first
    /// URL does not is dropped whole. Blocks until the dialog is answered and
    /// the shell has finished — never call it on the main thread.
    public static func deleteAsAdministrator(_ groups: [[URL]], prompt: String) -> AdministratorResult {
        deleteAsAdministrator(groups, prompt: prompt, identities: nil)
    }

    /// A supplied identity map is strict: missing entries never acquire a new identity.
    /// Tests inject a scratch-only target resolver and an unprivileged shell runner.
    static func deleteAsAdministrator(
        _ groups: [[URL]], prompt: String, identities: [URL: RemovalIdentity]?,
        appBundles: Set<URL> = [],
        targetResolver: (URL) -> URL? = administratorTarget(for:),
        activityCheck: (URL) -> String = bundleActivityCheck,
        runner: (String, String) -> AppleScriptRunner.Output = { AppleScriptRunner.runPrivileged($0, prompt: $1) }
    ) -> AdministratorResult {
        // Pairs of (what the caller named, what the shell will be given): the
        // result reports the caller's URLs, whatever resolving produced.
        var refused: [URL] = []
        var accepted: [[(original: URL, target: URL)]] = []
        for group in groups {
            guard let first = group.first, let firstTarget = targetResolver(first),
                  PathGuard.rejectTree(firstTarget) == nil else {
                for url in group { Log.error("Administrator delete refused \(url.path)") }
                refused += group
                continue
            }
            var kept = [(original: first, target: firstTarget)]
            for url in group.dropFirst() {
                if let target = targetResolver(url), PathGuard.rejectTree(target) == nil {
                    kept.append((url, target))
                } else {
                    Log.error("Administrator delete refused \(url.path)")
                    refused.append(url)
                }
            }
            accepted.append(kept)
        }
        let all = accepted.flatMap { $0 }
        guard !all.isEmpty else {
            return AdministratorResult(removed: [], failed: [], refused: refused, obstacles: [:],
                                       outcome: .failed, changed: [], running: [])
        }

        // The head of a group gates the rest; the rest are independent, so
        // one refused container does not keep the Logs or WebKit data after
        // it from being tried.
        // Receipts prove this command removed an entry. Disappearance caused by
        // another process, including while authentication is cancelled, is not success.
        let receiptPrefix = "CAC_" + UUID().uuidString + "_"
        var receipts: [URL: String] = [:]
        var expected: [URL: RemovalIdentity] = [:]
        var fingerprints: [URL: String] = [:]
        for (index, pair) in all.enumerated() {
            receipts[pair.original] = receiptPrefix + String(index)
            expected[pair.original] = identities == nil ? RemovalIdentity(at: pair.target) : identities?[pair.original]
            // Freeze before the final policy check. A new protected descendant
            // arriving during that check then invalidates the frozen tree.
            if let identity = expected[pair.original], identity.matches(pair.target),
               let fingerprint = treeFingerprint(pair.target, parent: identity.parent),
               PathGuard.rejectTree(pair.target) == nil, identity.matches(pair.target) {
                fingerprints[pair.original] = fingerprint
            }
        }
        func removal(_ pair: (original: URL, target: URL)) -> String {
            guard let identity = expected[pair.original], let receipt = receipts[pair.original],
                  let fingerprint = fingerprints[pair.original] else {
                return "/usr/bin/false"
            }
            let physical = identity.parent.appendingPathComponent(pair.target.lastPathComponent)
            return pinnedRemoval(pair.target, identity: identity, fingerprint: fingerprint,
                                 receipt: receipt,
                                 activityCheck: appBundles.contains(pair.original) ? activityCheck(physical) : nil)
                + " && " + shellReceipt(receipt)
        }
        // AppleScript returns receipts on stdout only when the shell exits
        // successfully. A failed entry still stops its dependent entries.
        let command = accepted.map { group in
            let head = removal(group[0])
            let rest = group.dropFirst().map { removal($0) }
            return rest.isEmpty ? head : "\(head) && { \(rest.joined(separator: "; ")); true; }"
        }.joined(separator: "; ") + "; exit 0"
        let output = accepted.contains { fingerprints[$0[0].original] != nil }
            ? runner(command, prompt)
            : AppleScriptRunner.Output(status: 1, stdout: "", stderr: "", timedOut: false)

        let outcome: EscalationOutcome
        if output.succeeded { outcome = .completed }
        else if output.userCancelled { outcome = .cancelled }
        else {
            outcome = .failed
            Log.error("Administrator delete failed: \(output.stderr)")
        }
        // A receipt and an absent path are both required; neither alone proves completion.
        var removed: [URL] = []
        var failed: [URL] = []
        var obstacles: [URL: RemovalObstacle] = [:]
        var changed: [URL] = []
        var running: [URL] = []
        // AppleScript uses CR between output lines; plain subprocesses use LF.
        // Receipts contain no whitespace, so either line ending is a delimiter.
        let completed = Set(output.stdout.split(whereSeparator: { $0.isNewline }).map(String.init))
        for (url, target) in all {
            guard let receipt = receipts[url] else { continue }
            if completed.contains(receipt), RemovalCheck.isMissing(target) {
                removed.append(url)
                continue
            }
            failed.append(url)
            let noFingerprint = fingerprints[url] == nil
            let shellSawChange = completed.contains(receipt + "_CHANGED")
            let identityMoved = expected[url]?.matches(target) != true
            if noFingerprint || shellSawChange || identityMoved {
                Log.error("Administrator delete saw a change at \(url.path): "
                    + "noFingerprint=\(noFingerprint) shellSawChange=\(shellSawChange) identityMoved=\(identityMoved)")
                changed.append(url)
                obstacles[url] = .changedSinceScan
            } else if completed.contains(receipt + "_RUNNING") {
                running.append(url)
                obstacles[url] = .inUse
            } else if let flagged = RemovalCheck.flagObstacle(at: target) { obstacles[url] = flagged }
            else if outcome == .cancelled { obstacles[url] = .needsAdmin }
            // Root was refused: privacy protection (App Management for a
            // bundle), the one wall a password does not get through.
            else if completed.contains(receipt + "_PRIVACY") { obstacles[url] = .privacyProtected }
            else { obstacles[url] = .other }
        }
        return AdministratorResult(removed: removed, failed: failed, refused: refused,
                                   obstacles: obstacles, outcome: outcome, changed: changed, running: running)
    }

    private static func shellReceipt(_ value: String) -> String {
        "/usr/bin/printf '%s\\n' " + AppleScriptRunner.shellQuoted(value)
    }

    /// lsof reads kernel text mappings, including command-line helpers that
    /// have no NSRunningApplication. Keep paths NUL-delimited through the check.
    private static func bundleActivityCheck(_ bundle: URL) -> String {
        // lsof escapes control characters even in field output. Keep the
        // bundle if its path cannot be compared with the chosen encoding.
        guard !bundle.path.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { return "/usr/bin/false" }
        let path = AppleScriptRunner.shellQuoted(bundle.path)
        return #"""
        (set -o pipefail; export LC_ALL=C;
        /usr/sbin/lsof -nP -S 2 -d txt -F0n 2>/dev/null | CAC_BUNDLE_PATH=\#(path) /usr/bin/perl -0ne '
        BEGIN {
            $prefix = "n" . $ENV{CAC_BUNDLE_PATH} . "/";
            $prefix =~ s/\\/\\\\/g;
            $prefix =~ s/([\x80-\xff])/sprintf("\\x%02x", ord($1))/ge;
        }
        $running = 1 if index($_, $prefix) == 0;
        END { exit($running ? 42 : 0) }')
        """#
    }

    static func isBundleRunning(_ bundle: URL) -> Bool? {
        guard let identity = RemovalIdentity(at: bundle) else { return nil }
        let physical = identity.parent.appendingPathComponent(bundle.lastPathComponent)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", bundleActivityCheck(physical)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        task.waitUntilExit()
        guard task.terminationReason == .exit else { return nil }
        switch task.terminationStatus {
        case 0: return false
        case 42: return true
        default: return nil
        }
    }

    /// One item as a root shell command that cannot be redirected: the shell
    /// enters the parent with `cd -P`, checks it landed where validation
    /// resolved it, and removes the entry by its relative name without
    /// crossing onto another volume (`-x`). A folder swapped for a symlink
    /// while the password dialog was up — `~/.Trash` pointed at `/Library` —
    /// fails the check instead of carrying the delete there.
    static func pinnedRemoval(_ target: URL) -> String {
        guard let identity = RemovalIdentity(at: target) else { return "/usr/bin/false" }
        return pinnedRemoval(target, identity: identity)
    }

    static func pinnedRemoval(_ target: URL, identity: RemovalIdentity) -> String {
        guard identity.matches(target),
              let fingerprint = treeFingerprint(target, parent: identity.parent),
              PathGuard.rejectTree(target) == nil, identity.matches(target) else { return "/usr/bin/false" }
        return pinnedRemoval(target, identity: identity, fingerprint: fingerprint)
    }

    private static func pinnedRemoval(_ target: URL, identity: RemovalIdentity, fingerprint: String,
                                      receipt: String? = nil, activityCheck: String? = nil) -> String {
        let quote = AppleScriptRunner.shellQuoted
        // Refuse redirection before command construction as well as after authentication.
        guard identity.matches(target) else { return "/usr/bin/false" }
        let parent = identity.parent.path
        let name = quote("./" + target.lastPathComponent)
        let objectID = quote("\(identity.object.device):\(identity.object.inode)")
        let parentID = quote("\(identity.parentObject.device):\(identity.parentObject.inode)")
        let locationChecks = "[ \"$(pwd -P)\" = \(quote(parent)) ] && "
            + "[ \"$(/usr/bin/stat -f '%d:%i' -- . 2>/dev/null)\" = \(parentID) ] && "
            + "[ \"$(/usr/bin/stat -f '%d:%i' -- \(name) 2>/dev/null)\" = \(objectID) ]"
        var finalChecks = locationChecks
        if identity.checksBundleInfo {
            let info = quote("./" + target.lastPathComponent + "/Contents/Info.plist")
            if let digest = identity.bundleInfoDigest {
                finalChecks += " && [ ! -L \(info) ] && [ \"$(/usr/bin/shasum -a 256 < \(info) 2>/dev/null | /usr/bin/cut -d ' ' -f 1)\" = \(quote(digest)) ]"
            } else {
                finalChecks += " && [ ! -e \(info) ] && [ ! -L \(info) ]"
            }
        }
        let changed = receipt.map { shellReceipt($0 + "_CHANGED") + "; " } ?? ""
        var remove = "/bin/rm -rfx -- \(name)"
        if let receipt {
            let privacy = shellReceipt(receipt + "_PRIVACY")
            remove = "if cac_error=$(\(remove) 2>&1); then true; else "
                + "case \"$cac_error\" in *'Operation not permitted'*) \(privacy);; esac; /usr/bin/false; fi"
        }
        let fingerprintCheck = "if cac_tree_fingerprint=$(\(treeFingerprintPipeline(target, parent: identity.parent))); then "
            + "if [ \"$cac_tree_fingerprint\" = \(quote(fingerprint)) ] && \(finalChecks); then "
            + "\(remove); else \(changed)/usr/bin/false; fi; "
            + "else \(changed)/usr/bin/false; fi"
        let checkedRemoval: String
        if let activityCheck, let receipt {
            // The tree can change while lsof runs, so compare its fingerprint afterward.
            let running = shellReceipt(receipt + "_RUNNING")
            checkedRemoval = "{ \(activityCheck); case $? in 0) \(fingerprintCheck);; "
                + "42) \(running); /usr/bin/false;; *) /usr/bin/false;; esac; }"
        } else {
            checkedRemoval = fingerprintCheck
        }
        return "( set -o pipefail; export LC_ALL=C; cd -P -- \(quote(parent)) && "
            + locationChecks + " && " + checkedRemoval + " )"
    }

    /// Only directory metadata and managed-cache markers can change the tree's
    /// safety policy without a name change. Ordinary file contents stay unread.
    /// Separate NUL-delimited names keep multiline paths unambiguous.
    private static func treeFingerprintPipeline(_ target: URL, parent: URL) -> String {
        let quote = AppleScriptRunner.shellQuoted
        let format = quote("%d:%i:%p:%z:%f:%Fm:%Fc")
        let markers = "\\( -iname .lock -o -iname CACHEDIR.TAG \\)"
        let tree = "/usr/bin/find -s -P \(quote("./" + target.lastPathComponent)) -xdev"
        func section(_ search: String, predicate: String = "") -> String {
            search + predicate + " -exec /usr/bin/stat -f \(format) -- {} + || exit 1; "
                + "/usr/bin/printf '\\000' || exit 1; "
                + search + " -print0 || exit 1; /usr/bin/printf '\\000' || exit 1"
        }
        var sections = [section(tree, predicate: " \\( -type d -o -iname .lock -o -iname CACHEDIR.TAG \\)")]
        var ancestor = parent
        while true {
            // Marker state includes absence, while unrelated changes beside
            // the selected entry do not invalidate the deletion.
            let search = "/usr/bin/find -s -P \(quote(ancestor.path)) -mindepth 1 -maxdepth 1 \(markers)"
            sections.append(section(search))
            if ancestor.path == "/" { break }
            let next = ancestor.deletingLastPathComponent()
            if next.path == ancestor.path { break }
            ancestor = next
        }
        return "( " + sections.joined(separator: "; ")
            + " ) | /usr/bin/shasum -a 256 | /usr/bin/cut -d ' ' -f 1"
    }

    /// The background job owns its process group; a timeout stops find, stat
    /// and the hasher together, so a surviving child cannot hold the pipe open.
    static func treeFingerprint(_ target: URL, parent: URL, timeout: TimeInterval = 30) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        let command = "set -m; "
            + "trap 'cac_fingerprint_job=$!; if [ -n \"$cac_fingerprint_job\" ]; then "
            + "kill -KILL -- -\"$cac_fingerprint_job\" 2>/dev/null; wait \"$cac_fingerprint_job\"; fi; exit 1' TERM; "
            + "( set +m; set -o pipefail; export LC_ALL=C; "
            + "cd -P -- \(AppleScriptRunner.shellQuoted(parent.path)) || exit 1; "
            + treeFingerprintPipeline(target, parent: parent)
            + " ) & cac_fingerprint_job=$!; "
            + "wait \"$cac_fingerprint_job\""
        task.arguments = ["-c", command]
        task.standardInput = FileHandle.nullDevice
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let expired = CancellationFlag()
        let watchdog = DispatchWorkItem {
            if task.isRunning { expired.cancel(); task.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        watchdog.cancel()
        guard task.terminationStatus == 0, !expired.isCancelled else {
            Log.error("Tree fingerprint unavailable for \(target.path): status \(task.terminationStatus), timed out \(expired.isCancelled)")
            return nil
        }
        let digest = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }) else {
            Log.error("Tree fingerprint unreadable for \(target.path)")
            return nil
        }
        return digest
    }

    /// The URL a root delete may act on, or nil.
    ///
    /// This is the only validation between a row in the UI and a root
    /// `rm -rf`, so it accepts three places and nothing else, each after
    /// `PathGuard`: an app bundle in an application folder
    /// (`administratorBundleTarget`), an item inside this user's Trash, and an
    /// app's own entry directly inside one of the `~/Library` folders the
    /// uninstaller searches. Any `..` is refused outright; the parent is
    /// resolved so a symlinked folder cannot relocate the delete, while the
    /// item itself is not followed — deleting a link removes the link.
    public static func administratorTarget(for url: URL) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.resolvingSymlinksInPath()
        if url.pathExtension.lowercased() == "app",
           let bundle = administratorBundleTarget(
               for: url, allowedRoots: ["/Applications", home.appendingPathComponent("Applications").path]) {
            return bundle
        }
        guard url.isFileURL, !url.path.isEmpty, !url.pathComponents.contains("..") else { return nil }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/", name != "." else { return nil }
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let target = parent.appendingPathComponent(name)
        guard PathGuard.reject(target) == nil else { return nil }

        let trash = home.appendingPathComponent(".Trash").path
        if PathGuard.isUnder(parent.path.lowercased(), trash.lowercased()) { return target }

        let library = home.appendingPathComponent("Library")
        let appDataFolders = Self.appDataFolders.map { library.appendingPathComponent($0).path.lowercased() }
        return appDataFolders.contains(parent.path.lowercased()) ? target : nil
    }

    /// The `~/Library` folders whose direct entries belong to one app each —
    /// the uninstaller's search locations.
    static let appDataFolders = [
        "Caches", "Preferences", "Preferences/ByHost", "Containers", "Group Containers",
        "Application Support", "Logs", "Saved Application State", "HTTPStorages",
        "WebKit", "Application Scripts", "Cookies"
    ]

    /// The resolved bundle an administrator delete may act on, or nil.
    ///
    /// Refuses anything that is not unmistakably an app bundle inside an
    /// application folder: a non-file or empty URL; any `..` component,
    /// checked on the original URL because standardizing collapses it; a
    /// symlink; the filesystem root; anything without the `.app` extension;
    /// anything `PathGuard` refuses; anything outside
    /// `allowedRoots`, compared on component boundaries; and anything that is
    /// not, at the moment of the check, a directory with a `Contents` folder.
    ///
    /// `allowedRoots` must already be standardized and symlink-resolved.
    static func administratorBundleTarget(for url: URL, allowedRoots: [String]) -> URL? {
        guard url.isFileURL, !url.path.isEmpty else { return nil }
        guard !url.pathComponents.contains("..") else { return nil }

        // The bundle itself must be a real directory, not a link: resolving a
        // link would hand root the app it points to — an app the user never
        // chose — while the row showed the link's size of zero.
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let parent = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let resolved = parent.appendingPathComponent(url.lastPathComponent)
        let path = resolved.path
        guard path != "/" else { return nil }
        guard resolved.pathExtension.lowercased() == "app" else { return nil }
        guard PathGuard.reject(resolved) == nil else { return nil }
        guard allowedRoots.contains(where: { root in
            let base = root.hasSuffix("/") ? String(root.dropLast()) : root
            return !base.isEmpty && path.hasPrefix(base + "/")
        }) else { return nil }

        guard AppManager.uninstallableBundleInfo(at: resolved) != nil else { return nil }
        return resolved
    }

    // MARK: - Read-only trees

    /// Keep the modified inode open until deletion or rollback finishes. A
    /// renamed directory or a replacement link cannot redirect restoration.
    private final class DirectoryAccessRepair {
        private let descriptor: Int32
        private let originalMode: mode_t

        init?(descriptor: Int32, mode: mode_t) {
            let pinned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard pinned >= 0 else { return nil }
            guard fchmod(pinned, mode | S_IRWXU) == 0 else {
                close(pinned)
                return nil
            }
            self.descriptor = pinned
            originalMode = mode
        }

        func restore() { _ = fchmod(descriptor, originalMode) }
        deinit { close(descriptor) }
    }

    /// Repair owned directories through pinned handles only. The traversal
    /// never follows child links; exhausted descriptor or traversal budgets
    /// restore every changed directory before failing closed.
    private static func restoreOwnerAccess(in url: URL, identity: RemovalIdentity) -> [DirectoryAccessRepair]? {
        guard identity.object.mode & S_IFMT == S_IFDIR, identity.matches(url),
              access(url.deletingLastPathComponent().path, W_OK) == 0 else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var rootInfo = stat()
        guard fstat(descriptor, &rootInfo) == 0,
              rootInfo.st_dev == identity.object.device, rootInfo.st_ino == identity.object.inode else { return nil }
        let uid = getuid()
        var changed: [DirectoryAccessRepair] = []
        var count = 0

        func repairTree(_ directoryDescriptor: Int32, expected: stat, depth: Int) -> Bool {
            guard depth < 256 else { return false }
            var current = stat()
            guard fstat(directoryDescriptor, &current) == 0,
                  current.st_dev == expected.st_dev, current.st_ino == expected.st_ino,
                  current.st_mode & S_IFMT == S_IFDIR else { return false }
            if current.st_uid == uid, current.st_mode & S_IRWXU != S_IRWXU {
                guard let repair = DirectoryAccessRepair(descriptor: directoryDescriptor,
                                                         mode: current.st_mode & 0o7777) else { return false }
                changed.append(repair)
            }
            let duplicate = fcntl(directoryDescriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else { return false }
            guard let stream = fdopendir(duplicate) else { close(duplicate); return false }
            defer { closedir(stream) }
            while true {
                errno = 0
                guard let entry = readdir(stream) else { return errno == 0 }
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                        String(validatingUTF8: $0)
                    }
                }
                guard let name else { return false }
                if name == "." || name == ".." { continue }
                guard count < 200_000 else { return false }
                count += 1
                var childInfo = stat()
                guard fstatat(directoryDescriptor, name, &childInfo, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
                guard childInfo.st_mode & S_IFMT == S_IFDIR else { continue }
                let child = openat(directoryDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return false }
                let succeeded = repairTree(child, expected: childInfo, depth: depth + 1)
                close(child)
                guard succeeded else { return false }
            }
        }
        guard repairTree(descriptor, expected: rootInfo, depth: 0) else {
            for directory in changed { directory.restore() }
            return nil
        }
        return changed.isEmpty ? nil : changed
    }
}

extension FileManager {
    /// Best-effort allocated size of a file or directory in bytes.
    ///
    /// Symlinks are measured as links, not as their targets: `removeItem` only
    /// unlinks them, so charging the target's size to a delete would overstate
    /// the space actually reclaimed.
    func allocatedSize(of url: URL, reclaiming: Bool = false) throws -> UInt64 {
        let fresh = URL(fileURLWithPath: url.path)
        var seen: Set<String> = []
        func measure(_ item: URL) throws -> UInt64 {
            var info = stat()
            guard lstat(item.path, &info) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { return 0 }
            let identity = "\(info.st_dev):\(info.st_ino)"
            guard seen.insert(identity).inserted else { return 0 }
            // Other hardlinks retain the storage after this name is unlinked.
            if reclaiming && type == S_IFREG && info.st_nlink > 1 { return 0 }
            let v = try URL(fileURLWithPath: item.path).resourceValues(
                forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return UInt64(max(0, v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? Int(info.st_blocks) * 512))
        }
        let own = try measure(fresh)
        var info = stat()
        guard lstat(fresh.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return own }
        let failed = CancellationFlag()
        guard let entries = enumerator(at: fresh, includingPropertiesForKeys: nil,
            errorHandler: { _, _ in failed.cancel(); return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        var total = own
        for case let child as URL in entries { total &+= try measure(child) }
        guard !failed.isCancelled else { throw CocoaError(.fileReadNoPermission) }
        return total
    }
}
