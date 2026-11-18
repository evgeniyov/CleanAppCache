import XCTest
@testable import CleanAppCacheLib

/// What the app *preselects* is as safety-critical as what it deletes: users
/// press "Clean" without unpicking every row.
@MainActor
final class SelectionSafetyTests: XCTestCase {

    private func item(
        _ path: String,
        _ category: ScanCategory,
        autoSelect: Bool? = nil
    ) -> CleanableItem {
        CleanableItem(
            url: URL(fileURLWithPath: path),
            category: category,
            size: 1024,
            itemCount: 1,
            autoSelect: autoSelect
        )
    }

    // MARK: - Per-item auto-select policy

    func testAutoSelectDefaultsToCategoryPolicy() {
        XCTAssertTrue(item("/x/a", .userCache).autoSelect)
        XCTAssertTrue(item("/x/b", .logs).autoSelect)
        XCTAssertTrue(item("/x/c", .tempFiles).autoSelect)
        XCTAssertFalse(item("/x/d", .trash).autoSelect)
        XCTAssertFalse(item("/x/e", .systemCache).autoSelect)
        XCTAssertFalse(item("/x/f", .browserJunk).autoSelect)
        XCTAssertFalse(item("/x/g", .installers).autoSelect)
    }

    func testPerItemOverrideBeatsCategoryPolicy() {
        // /var/log and /tmp share a category with ~/Library/Logs and the
        // per-user temp dir but must never be preselected: they hold the
        // system's own logging and the live sockets of running daemons.
        XCTAssertFalse(item("/var/log/system.log", .logs, autoSelect: false).autoSelect)
        XCTAssertFalse(item("/tmp/some.sock", .tempFiles, autoSelect: false).autoSelect)
    }

    func testSelectSafeHonoursPerItemPolicy() {
        let vm = DashboardViewModel(loadCache: false)
        let safe = item("/x/user-cache", .userCache)
        let risky = item("/var/log/system.log", .logs, autoSelect: false)
        vm.scanResult = ScanResult(
            items: [safe, risky],
            totalSize: 2048,
            duration: 0,
            categorySizes: [:]
        )

        vm.selectSafe()
        XCTAssertTrue(vm.selectedItems.contains(safe.id))
        XCTAssertFalse(vm.selectedItems.contains(risky.id),
                       "/var/log must not be preselected for cleaning")
    }

    func testSelectionIncludesTrashDrivesTheConfirmationWording() {
        let vm = DashboardViewModel(loadCache: false)
        let cache = item("/x/cache", .userCache)
        let trashed = item("/x/trashed", .trash)
        vm.scanResult = ScanResult(
            items: [cache, trashed], totalSize: 2048, duration: 0, categorySizes: [:]
        )

        vm.selectedItems = [cache.id]
        XCTAssertFalse(vm.selectionIncludesTrash)

        vm.selectedItems = [cache.id, trashed.id]
        XCTAssertTrue(vm.selectionIncludesTrash,
                      "Trash contents are erased, not trashed — the dialog must say so")
    }

    // MARK: - Duplicate auto-selection

    func testAutoSelectAlwaysKeepsOneCopyPerGroup() {
        let vm = DuplicatesViewModel()
        let now = Date()
        let files = (0..<4).map {
            DuplicateFile(
                url: URL(fileURLWithPath: "/x/copy\($0)"),
                size: 100,
                modified: now.addingTimeInterval(Double($0))
            )
        }
        vm.groups = [DuplicateGroup(size: 100, files: files)]

        vm.autoSelect(keep: .newest)
        XCTAssertEqual(vm.selectedForDeletion.count, files.count - 1)

        vm.autoSelect(keep: .oldest)
        XCTAssertEqual(vm.selectedForDeletion.count, files.count - 1)
    }

    func testAutoSelectIsDeterministicWhenTimestampsTie() {
        // cp -p, rsync -a and archive extraction all produce identical mtimes.
        // Swift's sort is not stable, so ordering by mtime alone would pick a
        // different "original" between runs — sometimes the file in Documents,
        // sometimes the copy in Downloads.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let deep = DuplicateFile(
            url: URL(fileURLWithPath: "/Users/x/Downloads/nested/copy.zip"),
            size: 100, modified: stamp
        )
        let shallow = DuplicateFile(
            url: URL(fileURLWithPath: "/Users/x/original.zip"),
            size: 100, modified: stamp
        )

        var results: Set<Bool> = []
        for _ in 0..<25 {
            let vm = DuplicatesViewModel()
            vm.groups = [DuplicateGroup(size: 100, files: [deep, shallow])]
            vm.autoSelect(keep: .newest)
            // The shallower path is the one kept.
            results.insert(vm.selectedForDeletion.contains(deep.id))
        }
        XCTAssertEqual(results, [true], "auto-selection must not vary between runs")
    }

    // MARK: - Duplicate deletion re-checks the disk

    /// A `DuplicateFile` recorded the way a scan would have seen the file.
    private func recorded(_ url: URL) throws -> DuplicateFile {
        let v = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = try XCTUnwrap(v.fileSize)
        return DuplicateFile(url: url, size: UInt64(size), modified: v.contentModificationDate)
    }

    /// Three identical files in a scratch directory, scanned.
    private func scannedGroup(in dir: URL) async throws -> [DuplicateFile] {
        for name in ["keep", "a", "b"] {
            let url = dir.appendingPathComponent(name)
            try "same bytes".write(to: url, atomically: true, encoding: .utf8)
        }
        let result = await DuplicateFinder.shared.findDuplicates(in: dir, minSize: 1) { _, _ in }
        return try XCTUnwrap(result.groups.first).files.sorted { $0.name < $1.name }
    }

    // Changed copies must stop before the move. Successful moves are exercised
    // separately through TrashService's injected scratch mover.

    /// «One copy in each group is kept» is a promise about the disk. If the copy
    /// meant to stay was edited after the scan, trashing the rest would leave
    /// zero intact copies — the whole group is skipped instead.
    func testStaleSurvivorSkipsTheWholeGroup() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dup_survivor_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let files = try await scannedGroup(in: dir)

        let vm = DuplicatesViewModel()
        vm.groups = [DuplicateGroup(size: files[0].size, files: files)]
        vm.selectedForDeletion = [files[1].id, files[2].id]
        // A different length, so the check cannot depend on mtime granularity.
        try "edited after the scan".write(to: files[0].url, atomically: true, encoding: .utf8)

        await vm.deleteSelected()

        XCTAssertTrue(fm.fileExists(atPath: files[1].url.path), "a marked copy was removed")
        XCTAssertTrue(fm.fileExists(atPath: files[2].url.path), "a marked copy was removed")
        XCTAssertEqual(vm.groups.count, 1, "the group stays until a rescan")
        XCTAssertFalse(vm.isDeleting)
    }

    /// A marked copy that changed since the scan is no longer the duplicate the
    /// hash verified, and is not deleted on the strength of the old hash.
    func testStaleMarkedCopiesAreLeftAlone() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dup_stale_\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let files = try await scannedGroup(in: dir)

        let vm = DuplicatesViewModel()
        vm.groups = [DuplicateGroup(size: files[0].size, files: files)]
        vm.selectedForDeletion = [files[1].id, files[2].id]
        for file in files.dropFirst() {
            try "replaced after the scan".write(to: file.url, atomically: true, encoding: .utf8)
        }

        await vm.deleteSelected()

        for file in files {
            XCTAssertTrue(fm.fileExists(atPath: file.url.path), "\(file.name) was removed")
        }
        XCTAssertEqual(vm.groups.count, 1)
        XCTAssertFalse(vm.isDeleting)
    }
}
