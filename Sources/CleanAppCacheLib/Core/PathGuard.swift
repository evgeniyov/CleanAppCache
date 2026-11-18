import Foundation
import Darwin

/// Last line of defence in front of every delete in the app.
///
/// User data is deleted in exactly two places — `DeletionService` (permanent)
/// and `TrashService` (move to the Trash) — and both consult the guard before
/// touching a path. `AppManager` consults it before removing an app bundle,
/// with or without administrator rights. The only other deletions are the
/// app's own housekeeping files (logs, size and scan caches, a corrupt history
/// copy). `DeletionRoutingTests` scans the sources for the destructive
/// filesystem calls it knows and fails when one appears anywhere else.
///
/// The guard does not know *why* a caller wants to delete something; it only
/// refuses the categories of path where a bug upstream would be unrecoverable:
/// the filesystem root, SIP-protected system directories and installed
/// package-manager trees, the user's home and its top-level folders, other
/// users' data, packages that behave like a single document (media libraries,
/// virtual machines), version-control metadata, iCloud and Time Machine data,
/// and volume metadata.
///
/// Design notes:
/// - Deny-list, not allow-list. "Large files" and "Duplicates" legitimately
///   scan the whole disk, so an allow-list would break real features.
/// - Explicit targets are checked both as written and with symlinks resolved.
///   A link cannot hide a protected entry or destination. Recursive checks use
///   physical directory handles and treat descendant links as leaves: removing
///   their containing directory unlinks them without removing their targets.
/// - Comparisons are case-insensitive, because the default APFS volume is:
///   `/system/library` and `/System/Library` name the same directory. On a
///   case-sensitive volume this can only refuse more, never less.
/// - Comparisons respect path-component boundaries: `/Users/a` never matches
///   `/Users/abc`. Swift string comparison is canonical, so composed and
///   decomposed spellings of the same name get the same verdict.
/// - Synchronous and side-effect free: it reads symlinks but never writes, so
///   it is cheap enough to run on every URL.
public enum PathGuard {

    // MARK: - Outcome

    public enum Rejection: String, Sendable, CustomStringConvertible {
        case emptyPath
        case notAFileURL
        case relativeComponent
        case filesystemRoot
        case topLevelDirectory
        case systemPath
        case protectedUserDirectory
        case otherUsersData
        case sensitiveUserData
        case mediaLibrary
        case virtualMachine
        case versionControl
        case cloudStorage
        case backupData
        case volumeMetadata
        case unverifiedContents
        case managedCache

        public var description: String {
            switch self {
            case .emptyPath:               return "empty path"
            case .notAFileURL:             return "not a file URL"
            case .relativeComponent:       return "path contains '..'"
            case .filesystemRoot:          return "filesystem root"
            case .topLevelDirectory:       return "top-level directory"
            case .systemPath:              return "system-protected path"
            case .protectedUserDirectory:  return "protected user directory"
            case .otherUsersData:          return "another user's data"
            case .sensitiveUserData:       return "sensitive user data"
            case .mediaLibrary:            return "media library package"
            case .virtualMachine:          return "virtual machine bundle"
            case .versionControl:          return "version-control metadata"
            case .cloudStorage:            return "cloud-synced storage"
            case .backupData:              return "backup data"
            case .volumeMetadata:          return "volume metadata"
            case .unverifiedContents:      return "directory contents could not be verified"
            case .managedCache:            return "cache requires its owning tool cleanup"
            }
        }
    }

    public struct Verdict: Sendable {
        public let allowed: [URL]
        public let blocked: [(url: URL, reason: Rejection)]

        public var hasBlocked: Bool { !blocked.isEmpty }
    }

    // MARK: - Public API

    /// A narrow permission a caller grants for one delete. The deny-list stays
    /// in force for everything else.
    public enum Allowance: Sendable, Hashable {
        /// A launchd job definition directly inside `/Library/LaunchAgents` or
        /// `/Library/LaunchDaemons`, or a helper directly inside
        /// `/Library/PrivilegedHelperTools`. Those folders stay refused as a
        /// whole, because removing a live job breaks the software that installed
        /// it; the Startup and Orphans screens grant this for entries they have
        /// identified one by one.
        case launchdJob
    }

    /// `nil` when the URL is safe to delete, otherwise the reason it was refused.
    public static func reject(_ url: URL, allowing: Set<Allowance> = []) -> Rejection? {
        guard url.isFileURL else { return .notAFileURL }
        guard !url.path.isEmpty else { return .emptyPath }

        // Reject before normalising: a caller handing us ".." anywhere is a bug,
        // and silently normalising it would hide that bug.
        if url.pathComponents.contains("..") { return .relativeComponent }

        let standardized = url.standardizedFileURL
        let physical = standardized.resolvingSymlinksInPath().path
        if let rejection = rejectResolvedPath(physical, allowing: allowing) { return rejection }
        guard standardized.path != physical else { return nil }

        // Unlinking a symlink removes its named entry, even if the destination
        // is elsewhere. Map the registered home spelling onto the same policy
        // as its physical spelling, preserving the unresolved relative path.
        let lexical = standardized.path.lowercased()
        let path = !homePath.isEmpty && lexicalHomePath != homePath && isUnder(lexical, lexicalHomePath)
            ? homePath + lexical.dropFirst(lexicalHomePath.count) : lexical
        return rejectResolvedPath(path, allowing: allowing)
    }

    /// Check a standardized spelling. Never resolve descendant links here.
    private static func rejectResolvedPath(_ path: String, allowing: Set<Allowance>,
                                           allowingVersionControl: Bool = false) -> Rejection? {
        let lower = path.lowercased()

        guard path != "/" else { return .filesystemRoot }

        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return .topLevelDirectory }

        // Shared containers whose *contents* are cleanable but which must never
        // be removed themselves (`/tmp`, `/var/log`, the per-user temp dir …).
        if protectedContainers.contains(lower) { return .topLevelDirectory }

        // The root of any mounted volume. `/Volumes/Backup` is two components
        // deep, so the count check above lets it through — and that is exactly
        // the path an external or Time Machine disk is mounted at.
        if components.count == 2, lower.hasPrefix("/volumes/") { return .topLevelDirectory }

        if matches(lower, systemPrefixes),
           !(allowing.contains(.launchdJob) && isLaunchdJob(lower)) {
            return .systemPath
        }

        if volumeMetadataNames.contains(where: { lower.hasSuffix("/\($0)") || lower.contains("/\($0)/") }) {
            return .volumeMetadata
        }

        if matches(lower, backupPrefixes) { return .backupData }
        if lower.hasSuffix(".sparsebundle") || lower.contains(".sparsebundle/") { return .backupData }
        if lower.contains("/backups.backupdb") { return .backupData }

        // Photos, Final Cut, iMovie, Logic and friends store their entire
        // library inside one package directory. Deleting an "unusually large"
        // file from inside one corrupts the library in a way the Trash cannot
        // undo, because restoring the file does not restore the database entry.
        if isInsidePackage(lower, withExtensionIn: mediaLibraryExtensions) { return .mediaLibrary }

        // A virtual machine's disk image is the largest file inside its bundle,
        // and removing it destroys the machine; putting it back from the Trash
        // does not repair a VM that was running or snapshotted meanwhile.
        if containsVirtualMachineBundle(lower) { return .virtualMachine }

        // Object packs are the biggest files in a repository. Deleting one, or
        // the `.git` directory itself, loses history that no build regenerates.
        if !allowingVersionControl && lower.split(separator: "/").contains(".git") { return .versionControl }

        let home = homePath
        if !home.isEmpty {
            if lower == home { return .protectedUserDirectory }
            if isUnder(lower, home) {
                if protectedHomePaths.contains(lower) { return .protectedUserDirectory }
                if matches(lower, cloudPrefixes) { return .cloudStorage }
                if matches(lower, sensitivePrefixes), !isPermittedException(lower) {
                    return .sensitiveUserData
                }
            } else if lower.hasPrefix("/users/") {
                // Another account's home, or /Users/Shared, where accounts on
                // this Mac leave files for each other.
                return .otherUsersData
            }
        }

        return nil
    }

    /// A recursive delete also reaches children the caller did not list individually.
    /// Fail closed on protected descendants, unreadable trees and an exhausted walk budget.
    public static func rejectTree(_ url: URL, allowing: Set<Allowance> = [],
                                  limit: Int = 200_000) -> Rejection? {
        rejectTree(url, allowing: allowing, limit: limit, beforeInspect: { _ in })
    }

    /// The visit hook lets scratch tests replace entries at the metadata/open
    /// boundary without timing-dependent races or global mutable state.
    static func rejectTree(_ url: URL, allowing: Set<Allowance> = [],
                           limit: Int = 200_000, beforeInspect: (URL) -> Void,
                           isCancelled: () -> Bool = { false }) -> Rejection? {
        rejectTree(url, allowing: allowing, limit: limit, beforeInspect: beforeInspect,
                   allowingUvCacheRoot: false, isCancelled: isCancelled)
    }

    /// The native uv primitive owns one tagged cache root and its Git metadata.
    /// Every other protected descendant and any nested managed cache stay blocked.
    static func rejectUvCacheTree(_ url: URL, limit: Int = 200_000,
                                  beforeInspect: (URL) -> Void = { _ in }) -> Rejection? {
        rejectTree(url, allowing: [], limit: limit, beforeInspect: beforeInspect,
                   allowingUvCacheRoot: true)
    }

    private static func rejectTree(_ url: URL, allowing: Set<Allowance>, limit: Int,
                                   beforeInspect: (URL) -> Void, allowingUvCacheRoot: Bool,
                                   isCancelled: () -> Bool = { false }) -> Rejection? {
        guard !isCancelled() else { return .unverifiedContents }
        if let reason = reject(url, allowing: allowing) { return reason }
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            return errno == ENOENT && !allowingUvCacheRoot ? nil : .unverifiedContents
        }
        beforeInspect(url)
        if info.st_mode & S_IFMT != S_IFDIR {
            guard !allowingUvCacheRoot else { return .unverifiedContents }
            guard let parent = physicalTreePath(url.deletingLastPathComponent()) else { return .unverifiedContents }
            let parentURL = URL(fileURLWithPath: parent, isDirectory: true)
            let entryPath = parentURL.appendingPathComponent(url.lastPathComponent).path
            if let reason = rejectResolvedPath(entryPath, allowing: allowing) { return reason }
            var parentRejection: Rejection?
            let parentDescriptor = openTreeRoot(parentURL, rejection: &parentRejection)
            guard parentDescriptor >= 0 else { return parentRejection ?? .unverifiedContents }
            close(parentDescriptor)
            var after = stat()
            guard lstat(url.path, &after) == 0, unchangedTreeEntry(info, after) else {
                return .unverifiedContents
            }
            return reject(url, allowing: allowing)
        }

        guard let physicalPath = physicalTreePath(url) else { return .unverifiedContents }
        let physical = URL(fileURLWithPath: physicalPath, isDirectory: true)
        if let reason = rejectResolvedPath(physical.path, allowing: allowing) { return reason }
        var rootRejection: Rejection?
        let descriptor = openTreeRoot(physical, rejection: &rootRejection,
                                      allowingManagedCacheRoot: allowingUvCacheRoot)
        guard descriptor >= 0 else { return rootRejection ?? .unverifiedContents }
        defer { close(descriptor) }
        var count = 0
        if let reason = inspectTreeDirectory(descriptor, at: physical, expected: info,
                                             allowing: allowing, limit: limit, count: &count,
                                             depth: 0, beforeInspect: beforeInspect,
                                             allowingUvCacheRoot: allowingUvCacheRoot, isCancelled: isCancelled) {
            return reason
        }
        var after = stat()
        guard lstat(url.path, &after) == 0, unchangedTreeEntry(info, after),
              physicalTreePath(url) == physicalPath else {
            return .unverifiedContents
        }
        return reject(url, allowing: allowing)
    }

    private static func physicalTreePath(_ url: URL) -> String? {
        // Foundation can abbreviate /private/var back to /var even after
        // resolving links. The no-follow walk needs the actual physical path.
        guard let resolved = realpath(url.path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingUTF8: resolved)
    }

    /// Open every resolved component without following links, including the
    /// ancestors. O_NOFOLLOW on only the final component leaves parent swaps open.
    private static func openTreeRoot(_ url: URL, rejection: inout Rejection?,
                                     allowingManagedCacheRoot: Bool = false) -> Int32 {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return -1 }
        for component in url.pathComponents.dropFirst() {
            if let reason = managedCacheRejection(descriptor) {
                rejection = reason; close(descriptor); return -1
            }
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(descriptor)
            guard next >= 0 else { return -1 }
            descriptor = next
        }
        // Only the selected root can belong to the native uv primitive; an
        // enclosing managed cache still owns every descendant path beneath it.
        if let reason = managedCacheRejection(descriptor),
           !(allowingManagedCacheRoot && reason == .managedCache) {
            rejection = reason; close(descriptor); return -1
        }
        return descriptor
    }

    /// Locked, tagged caches must be changed by their owning tool. Check
    /// ancestors too: selecting one bucket/file must not bypass the cache lock.
    private static func managedCacheRejection(_ descriptor: Int32) -> Rejection? {
        var lockInfo = stat()
        guard fstatat(descriptor, ".lock", &lockInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? nil : .unverifiedContents
        }
        var tagInfo = stat()
        guard fstatat(descriptor, "CACHEDIR.TAG", &tagInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? nil : .unverifiedContents
        }
        guard tagInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_mode & S_IFMT == S_IFREG else {
            return .unverifiedContents
        }
        let file = openat(descriptor, "CACHEDIR.TAG", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { return .unverifiedContents }
        defer { close(file) }
        var opened = stat()
        guard fstat(file, &opened) == 0, unchangedTreeEntry(tagInfo, opened) else { return .unverifiedContents }
        let signature = Array("Signature: 8a477f597d28d172789f06886806bc55".utf8)
        var bytes = [UInt8](repeating: 0, count: signature.count)
        let count = bytes.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
        guard count >= 0 else { return .unverifiedContents }
        return count == signature.count && bytes == signature ? .managedCache : nil
    }

    /// Descriptors pin each directory while its names are read. Metadata is
    /// checked before and after traversal so replacements and observed changes
    /// fail closed. This is a preflight, not an atomic lock spanning deletion.
    private static func inspectTreeDirectory(_ descriptor: Int32, at url: URL, expected: stat,
                                             allowing: Set<Allowance>, limit: Int, count: inout Int,
                                             depth: Int, beforeInspect: (URL) -> Void,
                                             allowingUvCacheRoot: Bool, isCancelled: () -> Bool) -> Rejection? {
        // Bound both stack and open-descriptor use even for adversarial trees.
        guard depth < 256, !isCancelled() else { return .unverifiedContents }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, unchangedTreeEntry(expected, initial) else {
            return .unverifiedContents
        }
        let managedReason = managedCacheRejection(descriptor)
        if allowingUvCacheRoot && depth == 0 {
            guard managedReason == .managedCache else { return managedReason ?? .unverifiedContents }
        } else if let reason = managedReason { return reason }
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else { return .unverifiedContents }
        guard let directory = fdopendir(duplicate) else {
            close(duplicate)
            return .unverifiedContents
        }
        defer { closedir(directory) }
        while true {
            guard !isCancelled() else { return .unverifiedContents }
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { return .unverifiedContents }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else { return .unverifiedContents }
            if name == "." || name == ".." { continue }
            guard count < limit else { return .unverifiedContents }
            count += 1
            var childInfo = stat()
            guard fstatat(descriptor, name, &childInfo, AT_SYMLINK_NOFOLLOW) == 0 else {
                return .unverifiedContents
            }
            let child = url.appendingPathComponent(name, isDirectory: childInfo.st_mode & S_IFMT == S_IFDIR)
            beforeInspect(child)
            // Git metadata belongs to uv only inside its verified cache. Keep
            // walking it so a protected package beneath .git cannot be hidden.
            if let reason = rejectResolvedPath(child.path, allowing: allowing,
                                               allowingVersionControl: allowingUvCacheRoot) { return reason }
            if childInfo.st_mode & S_IFMT == S_IFDIR {
                let childDescriptor = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childDescriptor >= 0 else { return .unverifiedContents }
                let reason = inspectTreeDirectory(childDescriptor, at: child, expected: childInfo,
                                                   allowing: allowing, limit: limit, count: &count,
                                                   depth: depth + 1, beforeInspect: beforeInspect,
                                                   allowingUvCacheRoot: allowingUvCacheRoot, isCancelled: isCancelled)
                close(childDescriptor)
                if let reason { return reason }
            }
            // Links (including dangling links) are leaves, but swapping a link
            // for a directory must not bypass checking that directory's contents.
            var after = stat()
            guard fstatat(descriptor, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                  unchangedTreeEntry(childInfo, after) else { return .unverifiedContents }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, unchangedTreeEntry(initial, after) else {
            return .unverifiedContents
        }
        return nil
    }

    private static func unchangedTreeEntry(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    /// Split a batch into what may be deleted and what was refused.
    public static func filter(_ urls: [URL], allowing: Set<Allowance> = []) -> Verdict {
        var allowed: [URL] = []
        var blocked: [(url: URL, reason: Rejection)] = []
        for url in urls {
            if let reason = reject(url, allowing: allowing) {
                blocked.append((url, reason))
            } else {
                allowed.append(url)
            }
        }
        return Verdict(allowed: allowed, blocked: blocked)
    }

    // MARK: - Deny lists (all lowercase; comparisons are case-insensitive)

    private static let homeURL = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    private static let lexicalHomePath = homeURL.path.lowercased()
    private static let homePath: String = {
        let path = homeURL.resolvingSymlinksInPath().path.lowercased()
        // A home of "/" would make `isUnder` true for everything while
        // `protectedHomePaths` matched nothing — silently disabling the whole
        // home section. Treat it as "unknown" instead.
        return path.count > 1 ? path : ""
    }()

    /// Roots that must never be touched. `/Library` is deliberately absent —
    /// `/Library/Caches` is a supported cleaning target — so the individual
    /// sensitive subtrees are listed instead. `/System/Library/Caches` is
    /// covered by `/system`: its contents are SIP-restricted and serve the
    /// running system, so no delete there can succeed or help.
    ///
    /// `/opt/homebrew` and `/opt/local` are installed package-manager trees,
    /// the equivalent of `/usr/local` (covered by `/usr`): removing anything in
    /// them breaks installed tools, and `/opt/homebrew/var` holds live database
    /// files that a move to the Trash corrupts.
    private static let systemPrefixes: [String] = [
        "/system",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/private/etc",
        "/dev",
        "/cores",
        "/network",
        "/volumes/preboot",
        "/var/db",
        "/private/var/db",
        "/var/root",
        "/private/var/root",
        "/var/vm",
        "/private/var/vm",
        "/var/audit",
        "/private/var/audit",
        "/library/apple",
        "/library/security",
        "/library/keychains",
        "/library/launchdaemons",
        "/library/launchagents",
        "/library/extensions",
        "/library/stagedextensions",
        "/library/systemextensions",
        "/library/frameworks",
        "/library/privilegedhelpertools",
        "/opt/homebrew",
        "/opt/local"
    ]

    /// Directories that survive even though their contents may be cleaned.
    private static let protectedContainers: Set<String> = {
        var set: Set<String> = [
            "/tmp", "/private/tmp",
            "/var/log", "/private/var/log",
            "/var/tmp", "/private/var/tmp",
            "/library", "/applications", "/users", "/volumes", "/opt",
            "/library/caches", "/system/library/caches",
            "/var/folders", "/private/var/folders"
        ]
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        set.insert(temp.hasSuffix("/") ? String(temp.dropLast()) : temp)
        return set
    }()

    private static let backupPrefixes: [String] = [
        "/volumes/com.apple.timemachine",
        "/.mobilebackups",
        "/private/var/db/com.apple.backupd"
    ]

    private static let volumeMetadataNames: [String] = [
        ".spotlight-v100",
        ".fseventsd",
        ".documentrevisions-v100",
        ".temporaryitems",
        ".trashes",
        ".hfs+ private directory data"
    ]

    /// Media package directories that behave like a single document.
    private static let mediaLibraryExtensions: [String] = [
        "photoslibrary", "aplibrary", "migratedaperturelibrary",
        "fcpbundle", "imovielibrary", "theater",
        "logicx", "musiclibrary", "tvlibrary"
    ]

    /// Virtual machine bundles: UTM, Parallels Desktop, VMware Fusion.
    private static let virtualMachineExtensions: [String] = [
        "utm", "pvm", "vmwarevm"
    ]

    /// Directories inside `~` that exist for the user, not for us. Their
    /// *contents* may be deletable; the directories themselves never are.
    private static let protectedHomePaths: Set<String> = {
        let home = homePath
        guard !home.isEmpty else { return [] }
        let names = [
            "Library", "Documents", "Desktop", "Downloads", "Pictures", "Music",
            "Movies", "Public", "Applications", "Sites", ".Trash", ".ssh", ".gnupg",
            "Library/Caches", "Library/Containers", "Library/Application Support",
            "Library/Preferences", "Library/Logs", "Library/Group Containers",
            "Library/Developer", "Library/Saved Application State", "Library/HTTPStorages",
            "Library/WebKit", "Library/Cookies", "Library/Services", "Library/Fonts"
        ]
        return Set(names.map { (home + "/" + $0).lowercased() })
    }()

    private static let cloudPrefixes: [String] = {
        let home = homePath
        guard !home.isEmpty else { return [] }
        return [
            "/library/mobile documents",
            "/library/cloudstorage",
            "/library/application support/clouddocs",
            "/library/application support/fileprovider"
        ].map { home + $0 }
    }()

    /// Narrow carve-outs inside otherwise-protected trees. The Mail container
    /// and MobileSync are off limits as a whole — the mailbox and the iPhone
    /// backups live there — but the two subdirectories below are exactly what
    /// the System Junk screen exists to clean, and blanket-blocking them would
    /// leave the app offering gigabytes it could never actually free.
    private static let permittedExceptions: [String] = {
        let home = homePath
        guard !home.isEmpty else { return [] }
        return [
            "/library/containers/com.apple.mail/data/library/mail downloads",
            "/library/application support/mobilesync/backup"
        ].map { home + $0 }
    }()

    private static let sensitivePrefixes: [String] = {
        let home = homePath
        guard !home.isEmpty else { return [] }
        return [
            "/library/keychains",
            "/library/mail",
            "/library/messages",
            "/library/photos",
            "/library/calendars",
            "/library/reminders",
            "/library/containers/com.apple.mail",
            "/library/group containers/group.com.apple.notes",
            "/library/safari/bookmarks.plist",
            "/library/application support/addressbook",
            "/library/application support/mobilesync",
            "/library/application support/com.apple.sharedfilelist",
            "/.ssh",
            "/.gnupg",
            "/.aws",
            "/.kube",
            "/.gcloud",
            "/.config/gcloud",
            "/.azure",
            "/.terraform.d",
            "/.netrc",
            "/.npmrc",
            "/.pypirc",
            "/.gitconfig",
            "/.config/gh",
            "/.docker/config.json"
        ].map { home + $0 }
    }()

    // MARK: - Matching helpers

    /// True when `path` is the same as `base` or lives inside it. Compares on
    /// component boundaries so `/Users/a` does not match `/Users/abc`.
    /// Both arguments must already be lowercased.
    static func isUnder(_ path: String, _ base: String) -> Bool {
        if path == base { return true }
        let normalizedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        return path.hasPrefix(normalizedBase + "/")
    }

    private static func matches(_ path: String, _ prefixes: [String]) -> Bool {
        prefixes.contains { isUnder(path, $0) }
    }

    /// True for a package with one of `extensions`, or anything inside one.
    private static func isInsidePackage(_ path: String, withExtensionIn extensions: [String]) -> Bool {
        extensions.contains { path.contains(".\($0)/") || path.hasSuffix(".\($0)") }
    }

    /// True when a path component is a virtual machine bundle (`ubuntu.utm`,
    /// `windows 11.pvm`). Reverse-DNS names such as `com.utmapp.utm` — the
    /// caches and containers of the VM apps themselves — end in the same
    /// extension but are ordinary, cleanable folders only in their known,
    /// directly app-owned Library locations. Punctuation alone proves nothing.
    private static func containsVirtualMachineBundle(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return parts.indices.contains { index in
            let component = parts[index]
            guard virtualMachineExtensions.contains(where: { component.hasSuffix(".\($0)") }) else {
                return false
            }
            let parent = "/" + parts[..<index].joined(separator: "/")
            let appFolders = ["/library/caches", "/library/containers", "/library/group containers",
                              "/library/application support", "/library/logs", "/library/preferences"]
            let knownIDs: Set<String> = ["com.utmapp.utm", "com.parallels.desktop.console", "com.vmware.fusion"]
            let knownAppEntry = knownIDs.contains(component)
                && appFolders.contains(where: { parent == homePath + $0 })
            return !knownAppEntry
        }
    }

    /// True for a path inside a carve-out, but not the carve-out root itself.
    private static func isPermittedException(_ path: String) -> Bool {
        permittedExceptions.contains { isUnder(path, $0) && path != $0 }
    }

    /// A plist directly inside a launchd job folder, or an entry directly
    /// inside the privileged helper folder. `path` must be lowercased.
    private static func isLaunchdJob(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "library" else { return false }
        switch parts[1] {
        case "launchagents", "launchdaemons": return parts[2].hasSuffix(".plist")
        case "privilegedhelpertools": return true
        default: return false
        }
    }
}
