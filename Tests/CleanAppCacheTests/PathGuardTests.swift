import XCTest
@testable import CleanAppCacheLib

/// `PathGuard` is the last thing standing between a bug anywhere upstream and
/// an unrecoverable delete, so it gets the most explicit test coverage in the
/// project. Every case here describes a path that a caller could plausibly
/// hand it by mistake.
final class PathGuardTests: XCTestCase {

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private func assertBlocked(
        _ path: String,
        _ expected: PathGuard.Rejection? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reason = PathGuard.reject(URL(fileURLWithPath: path))
        XCTAssertNotNil(reason, "expected \(path) to be refused", file: file, line: line)
        if let expected, let reason {
            XCTAssertEqual(reason, expected, "wrong reason for \(path)", file: file, line: line)
        }
    }

    private func assertAllowed(
        _ path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(
            PathGuard.reject(URL(fileURLWithPath: path)),
            "expected \(path) to be allowed",
            file: file, line: line
        )
    }

    // MARK: - Structural refusals

    func testRefusesFilesystemRootAndTopLevelDirectories() {
        assertBlocked("/", .filesystemRoot)
        assertBlocked("/Applications", .topLevelDirectory)
        assertBlocked("/Users", .topLevelDirectory)
        assertBlocked("/Volumes", .topLevelDirectory)
    }

    func testRefusesEmptyAndNonFileURLs() {
        XCTAssertEqual(PathGuard.reject(URL(string: "https://example.com")!), .notAFileURL)
    }

    func testRefusesRelativeComponents() {
        // Compared as a raw path, "/Applications/../.." satisfies a
        // `hasPrefix("/Applications/")` check and would reach `rm -rf`.
        assertBlocked("/Applications/../../System/Library/Foo.app", .relativeComponent)
        assertBlocked("/Users/someone/../../etc/passwd", .relativeComponent)
    }

    // MARK: - System paths

    func testRefusesSystemDirectories() {
        assertBlocked("/System/Library/CoreServices/Finder.app")
        assertBlocked("/usr/bin/du")
        assertBlocked("/bin/sh")
        assertBlocked("/etc/hosts")
        assertBlocked("/var/db/something")
        assertBlocked("/Library/LaunchDaemons/com.example.plist")
        assertBlocked("/Library/Keychains/System.keychain")
    }

    func testAllowsTheSystemCachesThatAreActuallyCleanable() {
        // The cache root itself stays; its contents are fair game.
        assertBlocked("/Library/Caches", .topLevelDirectory)
        assertAllowed("/Library/Caches/com.example.thing")
        // SIP-restricted caches of the running system are not.
        assertBlocked("/System/Library/Caches", .topLevelDirectory)
        assertBlocked("/System/Library/Caches/com.apple.kernelcaches", .systemPath)
    }

    func testLaunchdAllowanceCoversSingleJobFilesOnly() {
        let job = URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.helper.plist")
        XCTAssertEqual(PathGuard.reject(job), .systemPath)
        XCTAssertNil(PathGuard.reject(job, allowing: [.launchdJob]))
        XCTAssertNil(PathGuard.reject(URL(fileURLWithPath: "/Library/LaunchAgents/com.example.agent.plist"),
                                      allowing: [.launchdJob]))
        XCTAssertNil(PathGuard.reject(URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.example.helper"),
                                      allowing: [.launchdJob]))
        // The folders themselves, other file types and anything deeper stay refused.
        for path in ["/Library/LaunchDaemons", "/Library/LaunchDaemons/notes.txt",
                     "/Library/LaunchAgents/sub/com.example.plist",
                     "/Library/Extensions/com.example.plist", "/System/Library/LaunchDaemons/x.plist"] {
            XCTAssertNotNil(PathGuard.reject(URL(fileURLWithPath: path), allowing: [.launchdJob]), path)
        }
    }

    // MARK: - Shared containers

    func testRefusesTempRootsButAllowsTheirContents() {
        assertBlocked("/tmp", .topLevelDirectory)
        assertBlocked("/private/tmp", .topLevelDirectory)
        assertBlocked("/var/log", .topLevelDirectory)
        assertAllowed("/tmp/some-stale-file")
        assertAllowed("/var/log/old.log.gz")
    }

    // MARK: - User data

    func testRefusesHomeAndItsTopLevelFolders() {
        assertBlocked(home.path, .protectedUserDirectory)
        for name in ["Documents", "Desktop", "Downloads", "Pictures", "Music",
                     "Movies", "Library", ".Trash"] {
            assertBlocked(home.appendingPathComponent(name).path, .protectedUserDirectory)
        }
        for name in ["Library/Caches", "Library/Containers", "Library/Preferences",
                     "Library/Application Support", "Library/Logs"] {
            assertBlocked(home.appendingPathComponent(name).path, .protectedUserDirectory)
        }
    }

    func testAllowsOrdinaryUserContent() {
        assertAllowed(home.appendingPathComponent("Library/Caches/com.example.app").path)
        assertAllowed(home.appendingPathComponent("Downloads/installer.dmg").path)
        assertAllowed(home.appendingPathComponent(".Trash/old-thing").path)
    }

    func testRefusesCloudSyncedStorage() {
        // Trashing here propagates the delete to every device the user owns and
        // a local Undo does not put it back in the cloud.
        assertBlocked(home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/x").path,
                      .cloudStorage)
        assertBlocked(home.appendingPathComponent("Library/CloudStorage/Dropbox/x").path,
                      .cloudStorage)
    }

    func testRefusesSensitiveUserData() {
        assertBlocked(home.appendingPathComponent("Library/Keychains/login.keychain-db").path,
                      .sensitiveUserData)
        assertBlocked(home.appendingPathComponent("Library/Mail/V10/x").path, .sensitiveUserData)
        assertBlocked(home.appendingPathComponent("Library/Messages/chat.db").path, .sensitiveUserData)
        assertBlocked(home.appendingPathComponent(".ssh/id_ed25519").path)
    }

    func testRefusesStandardGoogleCloudCredentialDirectory() {
        for suffix in ["", "/credentials.db", "/application_default_credentials.json", "/configurations/config_default"] {
            assertBlocked(home.appendingPathComponent(".config/gcloud" + suffix).path, .sensitiveUserData)
        }
        assertAllowed(home.appendingPathComponent(".config/gcloud-old.log").path)
        assertAllowed(home.appendingPathComponent(".config/example-app/settings.json").path)
    }

    func testRefusesBackupsAndVolumeMetadata() {
        assertBlocked("/Volumes/Backup/Backups.backupdb/Mac/2026-08-01", .backupData)
        assertBlocked("/Volumes/Backup/MyMac.sparsebundle", .backupData)
        assertBlocked("/Volumes/Data/.Spotlight-V100/Store", .volumeMetadata)
        assertBlocked("/Volumes/Data/.fseventsd", .volumeMetadata)
        assertBlocked("/Volumes/Data/.Trashes/501", .volumeMetadata)
    }

    func testRefusesVolumeRootsAndOtherUsersData() {
        // `/Volumes/Backup` is only two components deep, so the depth check
        // alone let the entire mount point through — and that is exactly where
        // an external or Time Machine disk lives.
        assertBlocked("/Volumes/Backup", .topLevelDirectory)
        assertBlocked("/Volumes/External SSD", .topLevelDirectory)
        assertAllowed("/Volumes/External SSD/some-file.bin")

        assertBlocked("/Users/someone-else/Documents/report.pdf", .otherUsersData)
        assertBlocked("/Users/Shared/thing", .otherUsersData)
    }

    func testRefusesMediaLibraryPackages() {
        // Deleting one "unusually large" original out of a Photos library
        // corrupts it in a way the Trash cannot undo: restoring the file does
        // not restore the database entry that referenced it.
        assertBlocked(home.appendingPathComponent("Pictures/Photos Library.photoslibrary/originals/1/x.heic").path,
                      .mediaLibrary)
        assertBlocked(home.appendingPathComponent("Movies/Project.fcpbundle/render").path, .mediaLibrary)
        assertBlocked(home.appendingPathComponent("Movies/My.imovielibrary").path, .mediaLibrary)
    }

    func testMatchingIsCaseInsensitive() {
        // The default APFS volume is case-insensitive: /system/library and
        // /System/Library are the same directory.
        assertBlocked("/system/library/coreservices/Finder.app")
        assertBlocked("/USR/bin/du")
    }

    // MARK: - Installed software and document-like packages

    func testRefusesHomebrewTree() {
        // Installed software: removing any of it breaks the tools that link
        // against it, and /opt/homebrew/var holds live database files.
        assertBlocked("/opt", .topLevelDirectory)
        assertBlocked("/opt/homebrew", .systemPath)
        assertBlocked("/opt/homebrew/var/postgresql@16/base/1/1259", .systemPath)
        assertBlocked("/opt/homebrew/Cellar/llvm/19.1.0/lib/libLLVM.dylib", .systemPath)
        assertBlocked("/opt/local/lib/libfoo.dylib", .systemPath)
    }

    func testRefusesVirtualMachineBundles() {
        assertBlocked(home.appendingPathComponent("VMs/Windows 11.pvm").path, .virtualMachine)
        assertBlocked(home.appendingPathComponent("VMs/Windows 11.pvm/harddisk.hdd").path, .virtualMachine)
        assertBlocked(home.appendingPathComponent("VMs/Ubuntu.utm/Data/disk.qcow2").path, .virtualMachine)
        assertBlocked("/Volumes/External SSD/Fusion/Debian.vmwarevm", .virtualMachine)
        assertAllowed(home.appendingPathComponent("Downloads/utm-installer.dmg").path)
        // The VM apps' own caches and containers share the extension but are
        // ordinary folders; a real bundle inside one is still refused.
        assertAllowed(home.appendingPathComponent("Library/Caches/com.utmapp.UTM/x.cache").path)
        assertBlocked(home.appendingPathComponent(
            "Library/Containers/com.utmapp.UTM/Data/Documents/Linux.utm/Data/disk.qcow2").path, .virtualMachine)
    }

    func testRefusesVersionControlMetadata() {
        let repo = home.appendingPathComponent("Projects/app")
        assertBlocked(repo.appendingPathComponent(".git").path, .versionControl)
        assertBlocked(repo.appendingPathComponent(".git/objects/pack/pack-1a2b.pack").path, .versionControl)
        assertAllowed(repo.appendingPathComponent("build/output.bin").path)
        assertAllowed(repo.appendingPathComponent(".gitignore").path)
        assertAllowed(repo.appendingPathComponent(".github/workflows/ci.yml").path)
    }

    // MARK: - Symlinks and Unicode

    func testSymlinkIsJudgedByItsTarget() throws {
        // A cleanable folder cannot make a link to a protected destination safe.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("pathguard-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let plain = dir.appendingPathComponent("plain.bin")
        try Data("x".utf8).write(to: plain)
        XCTAssertNil(PathGuard.reject(plain), "an ordinary scratch file must be allowed")

        let toLibrary = dir.appendingPathComponent("library-link")
        try fm.createSymbolicLink(at: toLibrary, withDestinationURL: home.appendingPathComponent("Library"))
        XCTAssertEqual(PathGuard.reject(toLibrary), .protectedUserDirectory)

        let toSystem = dir.appendingPathComponent("system-link")
        try fm.createSymbolicLink(at: toSystem, withDestinationURL: URL(fileURLWithPath: "/System/Library"))
        XCTAssertEqual(PathGuard.reject(toSystem), .systemPath)
    }

    func testLinkCannotHideItsProtectedDirectoryEntry() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathguard-\(UUID().uuidString)")
        let repository = root.appendingPathComponent(".git", isDirectory: true)
        try fm.createDirectory(at: repository, withIntermediateDirectories: true)
        addTeardownBlock { try fm.removeItem(at: root) }

        let safe = root.appendingPathComponent("safe")
        try Data("data".utf8).write(to: safe)
        let protected = repository.appendingPathComponent("link")
        try fm.createSymbolicLink(at: protected, withDestinationURL: safe)
        XCTAssertEqual(PathGuard.reject(protected), .versionControl)
        XCTAssertEqual(PathGuard.rejectTree(protected), .versionControl)

        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: repository)
        XCTAssertEqual(PathGuard.rejectTree(alias.appendingPathComponent("link")), .versionControl)
        XCTAssertNil(PathGuard.rejectTree(safe))
    }

    func testComposedAndDecomposedNamesMatchTheSameWay() {
        // The file system can hand back either Unicode form. A home such as
        // with a Cyrillic short i (U+0439) or /Users/José must match in both.
        for name in ["евгений", "josé"] {
            let base = "/users/\(name)".precomposedStringWithCanonicalMapping
            let decomposedChild = (base + "/library/caches").decomposedStringWithCanonicalMapping
            XCTAssertNotEqual(Array(base.unicodeScalars),
                              Array(base.decomposedStringWithCanonicalMapping.unicodeScalars),
                              "the fixture must really differ between the two forms")
            XCTAssertTrue(PathGuard.isUnder(decomposedChild, base))
            XCTAssertTrue(PathGuard.isUnder(base.decomposedStringWithCanonicalMapping, base))
        }
    }

    // MARK: - Batch filtering

    func testFilterSplitsAllowedFromBlocked() {
        let ok = home.appendingPathComponent("Library/Caches/com.example.app")
        let bad = URL(fileURLWithPath: "/")
        let verdict = PathGuard.filter([ok, bad])
        XCTAssertEqual(verdict.allowed, [ok])
        XCTAssertEqual(verdict.blocked.count, 1)
        XCTAssertEqual(verdict.blocked.first?.reason, .filesystemRoot)
        XCTAssertTrue(verdict.hasBlocked)
    }

    // MARK: - Enforcement at the delete sites

    private func protectedFixture() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("pathguard-\(UUID().uuidString)")
        let repository = root.appendingPathComponent(".git", isDirectory: true)
        try fm.createDirectory(at: repository, withIntermediateDirectories: true)
        addTeardownBlock { try fm.removeItem(at: root) }
        let fixture = repository.appendingPathComponent("config")
        try Data("fixture".utf8).write(to: fixture)
        return fixture
    }

    func testDeletionServiceRefusesProtectedPathsWithoutTouchingDisk() throws {
        let fixture = try protectedFixture()
        let result = DeletionService.delete([fixture])
        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertTrue(result.failed.isEmpty, "blocked paths must not be reported as failures")
        XCTAssertEqual(result.blocked, [fixture])
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertEqual(try Data(contentsOf: fixture), Data("fixture".utf8))
    }

    func testTrashServiceRefusesProtectedPaths() throws {
        let fixture = try protectedFixture()
        let result = TrashService.trash([fixture])
        XCTAssertEqual(result.count, 0)
        XCTAssertEqual(result.blocked, [fixture])
        XCTAssertEqual(try Data(contentsOf: fixture), Data("fixture".utf8))
    }

    // MARK: - Component-boundary matching

    func testPrefixMatchingRespectsComponentBoundaries() {
        XCTAssertTrue(PathGuard.isUnder("/Users/a/b", "/Users/a"))
        XCTAssertTrue(PathGuard.isUnder("/Users/a", "/Users/a"))
        XCTAssertFalse(PathGuard.isUnder("/Users/abc", "/Users/a"))
        XCTAssertFalse(PathGuard.isUnder("/Users/ab", "/Users/a"))
    }
}
