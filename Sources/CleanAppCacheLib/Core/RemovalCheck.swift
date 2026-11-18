import Foundation
import Darwin

/// What stands between the app and removing a file, named by what the user can
/// do about it. A bare "could not delete" hides four different situations, and
/// each needs a different answer: a password, a privacy setting, nothing at
/// all, or quitting another app.
public enum RemovalObstacle: String, Codable, Sendable, CaseIterable {
    /// POSIX permissions: this account may not change the folder that holds
    /// the item (root-owned app bundles, `/Library/Caches`, `/var/log`). An
    /// administrator password gets through.
    case needsAdmin
    /// macOS privacy protection refused an operation the POSIX permissions
    /// allow: Full Disk Access for other apps' data, App Management for other
    /// apps' bundles. A password changes nothing; a grant in System Settings
    /// does.
    case privacyProtected
    /// System Integrity Protection or a read-only volume. Nothing the user can
    /// grant removes it.
    case systemProtected
    /// The item, or something inside it, is locked (Finder's "Locked").
    case locked
    /// A running process holds it.
    case inUse
    /// The selected object or its eligibility changed after scanning.
    case changedSinceScan
    case other
}

/// Answers "can this account remove that path?" before trying, and "why not?"
/// after a failed try.
///
/// The preflight reads only `lstat` and `access`: it catches POSIX refusals and
/// file flags, which is what decides whether a password will be asked for.
/// Privacy protection (TCC) cannot be probed without attempting the operation,
/// so it surfaces only through `classify`.
public enum RemovalCheck {

    /// The obstacle to moving `url` to the Trash, or nil when nothing POSIX
    /// stands in the way. A missing item has no obstacle; callers report it as
    /// already gone.
    ///
    /// A move to the Trash is a rename: it needs write access to the parent,
    /// ownership under a sticky parent (`/tmp`, `/Library/Caches`), and — for a
    /// directory, whose `..` entry changes — write access to the directory
    /// itself.
    public static func trashObstacle(at url: URL) -> RemovalObstacle? {
        guard let item = status(url.path) else { return nil }
        let parentPath = url.deletingLastPathComponent().path
        guard let parent = followedStatus(parentPath) else { return .other }
        if let flagged = flagObstacle(item.st_flags) ?? parentFlagObstacle(parent.st_flags) {
            return flagged
        }
        if isSystemProtected(url) { return .systemProtected }
        if let denied = unlinkObstacle(item: item, parent: parent, parentPath: parentPath) {
            return denied
        }
        if isDirectory(item), access(url.path, W_OK) != 0 {
            return errno == EROFS ? .systemProtected : .needsAdmin
        }
        return nil
    }

    /// The obstacle to deleting `url` permanently, or nil when nothing POSIX
    /// stands in the way.
    ///
    /// A permanent delete unlinks every entry, so every directory in the tree
    /// must be writable, locked entries anywhere stop it, and a sticky
    /// directory inside refuses entries this account does not own. The walk
    /// stops at the first obstacle and gives up (reporting none) after
    /// `entryLimit` entries: the delete itself still reports what the
    /// preflight could not afford to see.
    public static func deleteObstacle(at url: URL, entryLimit: Int = 200_000) -> RemovalObstacle? {
        guard let item = status(url.path) else { return nil }
        let parentPath = url.deletingLastPathComponent().path
        guard let parent = followedStatus(parentPath) else { return .other }
        if let flagged = parentFlagObstacle(parent.st_flags) { return flagged }
        if let denied = unlinkObstacle(item: item, parent: parent, parentPath: parentPath) {
            return denied
        }
        if let flagged = flagObstacle(item.st_flags) { return flagged }
        if isSystemProtected(url) { return .systemProtected }
        guard isDirectory(item) else { return nil }

        return treeObstacle(root: url.path, rootStatus: item, entryLimit: entryLimit)
    }

    /// Why a removal that just failed was refused.
    ///
    /// Foundation reports EACCES and EPERM alike as "no permission", so the
    /// error alone cannot tell a root-owned folder from a privacy refusal. The
    /// item is examined again: a POSIX or flag obstacle found there explains
    /// the failure; when the permissions allow the operation and the kernel
    /// refused anyway, privacy protection is the remaining cause.
    public static func classify(_ error: Error, at url: URL, permanent: Bool) -> RemovalObstacle {
        let code = posixCode(of: error)
        switch code {
        case EROFS: return .systemProtected
        case EBUSY, ETXTBSY: return .inUse
        default: break
        }
        if let found = permanent ? deleteObstacle(at: url) : trashObstacle(at: url) {
            return found
        }
        // The permissions allow it and the kernel said "not permitted":
        // privacy protection. EACCES is a POSIX denial the probe did not
        // explain, and a Full Disk Access hint would not help with it.
        if code == EPERM || (code == nil && isCocoaPermissionError(error)) {
            return .privacyProtected
        }
        return .other
    }

    /// True when `url` itself is a symbolic link.
    public static func isSymlink(_ url: URL) -> Bool {
        guard let st = status(url.path) else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// True when nothing exists at `url`, not even a dangling symlink.
    /// `FileManager.fileExists` follows links and would call a dangling one
    /// missing although it still takes up a directory entry.
    public static func isMissing(_ url: URL) -> Bool {
        guard status(url.path) == nil else { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    /// The obstacle the flags of `url` itself raise — SIP, system immutable,
    /// or Finder's "Locked" — or nil. Root is subject to these too.
    public static func flagObstacle(at url: URL) -> RemovalObstacle? {
        guard let st = status(url.path) else { return nil }
        return flagObstacle(st.st_flags)
    }

    // MARK: - Internals

    private static func status(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    /// The parent is judged as the directory it is, not as a link to it:
    /// `/tmp` is a SIP-flagged link to `/private/tmp`, whose own flags and
    /// mode are what decide.
    private static func followedStatus(_ path: String) -> stat? {
        var st = stat()
        return stat(path, &st) == 0 ? st : nil
    }

    private static func isDirectory(_ st: stat) -> Bool {
        (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// SIP marks its territory `restricted`, and `sunlnk` on the per-user
    /// folders of system services (`$TMPDIR/com.apple.tccd`, which this
    /// account owns and still cannot rename or remove); `schg` is the system
    /// immutable flag, which only single-user mode clears. `uchg` is Finder's
    /// "Locked".
    private static func flagObstacle(_ flags: UInt32) -> RemovalObstacle? {
        let system = UInt32(SF_RESTRICTED) | UInt32(SF_NOUNLINK) | UInt32(SF_IMMUTABLE)
        if flags & system != 0 { return .systemProtected }
        if flags & UInt32(UF_IMMUTABLE) != 0 { return .locked }
        return nil
    }

    /// What a parent's flags forbid for the entries inside it. `sunlnk`
    /// protects only the directory's own name — `$TMPDIR` carries it, and
    /// everything the user puts there can still go — so only the flags that
    /// freeze a directory's contents count here.
    private static func parentFlagObstacle(_ flags: UInt32) -> RemovalObstacle? {
        let frozen = UInt32(SF_RESTRICTED) | UInt32(SF_IMMUTABLE)
        if flags & frozen != 0 { return .systemProtected }
        if flags & UInt32(UF_IMMUTABLE) != 0 { return .locked }
        return nil
    }

    /// True when SIP guards `url` itself: a system flag, or the
    /// `com.apple.rootless` attribute SIP stamps on what it protects. Such an
    /// item cannot be moved or deleted by anyone on a running system, so it is
    /// never worth offering for cleaning.
    public static func isSystemProtected(_ url: URL) -> Bool {
        guard let st = status(url.path) else { return false }
        if flagObstacle(st.st_flags) == .systemProtected { return true }
        return getxattr(url.path, "com.apple.rootless", nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Whether this account may remove the entry `item` from `parent`.
    private static func unlinkObstacle(item: stat, parent: stat, parentPath: String) -> RemovalObstacle? {
        if access(parentPath, W_OK) != 0 {
            return errno == EROFS ? .systemProtected : .needsAdmin
        }
        let uid = getuid()
        if parent.st_mode & S_ISVTX != 0, item.st_uid != uid, parent.st_uid != uid, uid != 0 {
            return .needsAdmin
        }
        return nil
    }

    private static func treeObstacle(root: String, rootStatus: stat, entryLimit: Int) -> RemovalObstacle? {
        if access(root, W_OK) != 0, rootStatus.st_uid != getuid() {
            return errno == EROFS ? .systemProtected : .needsAdmin
        }
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return nil }
        let uid = getuid()
        var parentStatus: [String: stat] = [root: rootStatus]
        var seen = 0
        while let relative = enumerator.nextObject() as? String {
            seen += 1
            if seen > entryLimit { return nil }
            let path = root + "/" + relative
            guard let st = status(path) else { continue }
            if let flagged = flagObstacle(st.st_flags) { return flagged }
            let parentPath = (path as NSString).deletingLastPathComponent
            if let parent = parentStatus[parentPath], parent.st_mode & S_ISVTX != 0,
               st.st_uid != uid, parent.st_uid != uid, uid != 0 {
                return .needsAdmin
            }
            if isDirectory(st) {
                // A directory this account owns and cannot write or list is
                // not an obstacle: `DeletionService` restores the owner's
                // access and retries. Someone else's is.
                if access(path, W_OK | R_OK | X_OK) != 0, st.st_uid != uid {
                    return errno == EROFS ? .systemProtected : .needsAdmin
                }
                parentStatus[path] = st
            }
        }
        return nil
    }

    /// The POSIX errno behind a Foundation error, looking through
    /// `NSUnderlyingErrorKey` the way `FileManager` nests it.
    static func posixCode(of error: Error) -> Int32? {
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    private static func isCocoaPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain &&
            (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError)
    }
}

/// How a request for elevated rights ended.
public enum EscalationOutcome: Sendable, Equatable {
    /// The helper ran — Finder, or the root shell — and did what it could.
    case completed
    /// The user dismissed the password dialog.
    case cancelled
    /// macOS does not let this app control Finder (Privacy & Security →
    /// Automation).
    case automationDenied
    /// The helper ran and failed for another reason, which is logged.
    case failed
}
