import XCTest
@testable import CleanAppCacheLib

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[URL]] = []
    func record(_ urls: [URL]) { lock.lock(); stored.append(urls); lock.unlock() }
    var calls: [[URL]] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// `SystemJunkViewModel.clean()` against a scratch Trash: which rows leave,
/// which stay with their survivors, and what is handed to the password retry.
@MainActor
final class SystemJunkViewModelTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var bin: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("junk-vm-\(UUID().uuidString)")
        bin = root.appendingPathComponent("Trash")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: url.appendingPathComponent("file"))
        return url
    }

    private func entry(_ urls: [URL]) -> SystemJunkEntry {
        SystemJunkEntry(category: .quickLookCache, urls: urls, totalSize: UInt64(urls.count) * 4096)
    }

    /// The move into the scratch Trash, optionally refusing some URLs.
    private func mover(refusing refused: Set<URL> = []) -> (URL) throws -> URL {
        { [bin] url in
            if refused.contains(url) { throw CocoaError(.fileWriteUnknown) }
            let dest = bin!.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
    }

    private func viewModel(entries: [SystemJunkEntry], mover move: @escaping (URL) throws -> URL,
                           escalate: @escaping SystemJunkViewModel.Escalator = { urls, _ in
                               XCTFail("No password retry expected: \(urls)")
                               return .init(trashed: [], failed: [], freedBytes: 0)
                           }) -> SystemJunkViewModel {
        let vm = SystemJunkViewModel(
            cleanEntry: { await SystemJunkManager.shared.clean($0, mover: move) },
            escalate: escalate)
        vm.entries = entries
        vm.selected = Set(entries.map(\.id))
        return vm
    }

    func testCleanedRowsLeaveAndAreLoggedAsMovedNotFreed() async throws {
        let a = try folder("a"), b = try folder("b")
        let vm = viewModel(entries: [entry([a]), entry([b])], mover: mover())
        let before = CleanupHistory.shared.totalTrashedBytes
        let freedBefore = CleanupHistory.shared.totalFreedBytes

        await vm.clean()

        XCTAssertTrue(vm.entries.isEmpty)
        XCTAssertTrue(vm.selected.isEmpty)
        XCTAssertFalse(vm.isCleaning)
        XCTAssertEqual(vm.currentScan, "")
        XCTAssertFalse(fm.fileExists(atPath: a.path))
        XCTAssertFalse(fm.fileExists(atPath: b.path))
        XCTAssertGreaterThan(CleanupHistory.shared.totalTrashedBytes, before)
        XCTAssertEqual(CleanupHistory.shared.totalFreedBytes, freedBefore, "the Trash still holds the bytes")
        XCTAssertEqual(CleanupHistory.shared.records.first?.source, .systemJunk)
    }

    func testPartiallyFailedRowStaysSelectedWithOnlyItsSurvivors() async throws {
        let moved = try folder("moved"), stuck = try folder("stuck"), other = try folder("other")
        let partial = entry([moved, stuck])
        let whole = entry([other])
        let vm = viewModel(entries: [partial, whole], mover: mover(refusing: [stuck]))

        await vm.clean()

        XCTAssertEqual(vm.entries.map(\.id), [partial.id], "the fully cleaned row is gone")
        XCTAssertEqual(vm.entries.first?.urls, [stuck])
        XCTAssertEqual(vm.entries.first?.totalSize, 4096, "the size drops by what moved")
        XCTAssertEqual(vm.selected, [partial.id], "a retry is one click")
        XCTAssertTrue(fm.fileExists(atPath: stuck.path))
        XCTAssertFalse(fm.fileExists(atPath: moved.path))
        XCTAssertFalse(fm.fileExists(atPath: other.path))
    }

    func testPartiallyMovedGroupStillCountsTheSurvivingHardLink() async throws {
        let moved = try folder("moved")
        let stuck = try folder("stuck")
        let survivingLink = stuck.appendingPathComponent("link")
        try fm.linkItem(at: moved.appendingPathComponent("file"), to: survivingLink)
        let urls = [moved, stuck]
        let identities = RemovalIdentity.capture(urls)
        let group = SystemJunkManager.measureGroup(urls, identities: identities)
        let partial = SystemJunkEntry(category: .quickLookCache, urls: urls, totalSize: group.bytes,
                                      removalIdentities: identities, hasSharedAllocation: group.hasSharedAllocation)
        let vm = viewModel(entries: [partial], mover: mover(refusing: [stuck]))

        await vm.clean()

        let remaining = await DirectorySizeProbe.measureRoot(stuck, timeout: 5)
        XCTAssertTrue(remaining.complete)
        XCTAssertEqual(vm.entries.first?.urls, [stuck])
        XCTAssertEqual(vm.entries.first?.totalSize, remaining.bytes)
        XCTAssertTrue(fm.fileExists(atPath: survivingLink.path))
    }

    func testNothingMovedKeepsEveryRowSelectedAndOnDisk() async throws {
        let stuck = try folder("stuck")
        let only = entry([stuck])
        let vm = viewModel(entries: [only], mover: mover(refusing: [stuck]))

        await vm.clean()

        XCTAssertEqual(vm.entries.map(\.id), [only.id])
        XCTAssertEqual(vm.entries.first?.urls, [stuck])
        XCTAssertEqual(vm.selected, [only.id])
        XCTAssertTrue(fm.fileExists(atPath: stuck.path))
    }

    func testRefusedForRightsGoToOneFinderRequestAndLeaveOnceMoved() async throws {
        let a = try folder("a"), b = try folder("b")
        let first = entry([a]), second = entry([b])
        let requests = Counter()
        let realMover = mover()
        let vm = SystemJunkViewModel(
            cleanEntry: { entry in
                .init(trashed: [], failed: entry.urls,
                      obstacles: Dictionary(uniqueKeysWithValues: entry.urls.map { ($0, RemovalObstacle.needsAdmin) }),
                      freedBytes: 0)
            },
            escalate: { urls, validation in
                requests.record(urls)
                return TrashService.trash(urls, validation: validation, mover: realMover)
            })
        vm.entries = [first, second]
        vm.selected = [first.id, second.id]

        await vm.clean()

        XCTAssertEqual(requests.calls.count, 1, "one password covers the batch")
        XCTAssertEqual(Set(requests.calls[0]), [a, b])
        XCTAssertTrue(vm.entries.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: a.path))
        XCTAssertFalse(fm.fileExists(atPath: b.path))
    }

    func testItemReplacedBeforeTheFinderRetryIsRefusedAndKept() async throws {
        let replaced = try folder("replaced")
        let junk = entry([replaced])
        let realMover = mover()
        let vm = SystemJunkViewModel(
            cleanEntry: { entry in
                let url = entry.urls[0]
                try? FileManager.default.moveItem(at: url, to: url.appendingPathExtension("held"))
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try? Data("user data".utf8).write(to: url.appendingPathComponent("file"))
                return .init(trashed: [], failed: [url], obstacles: [url: .needsAdmin], freedBytes: 0)
            },
            escalate: { urls, validation in
                TrashService.trash(urls, validation: validation, mover: realMover)
            })
        vm.entries = [junk]
        vm.selected = [junk.id]

        await vm.clean()

        XCTAssertEqual(try String(contentsOf: replaced.appendingPathComponent("file")), "user data")
        XCTAssertEqual(vm.entries.map(\.id), [junk.id], "the refused row stays listed")
        XCTAssertEqual(vm.entries.first?.urls, [replaced])
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: bin.path).isEmpty)
    }

    func testBusyOrEmptySelectionStartsNothing() async throws {
        let a = try folder("a")
        let cleaned = Counter()
        let vm = SystemJunkViewModel(
            cleanEntry: { entry in
                cleaned.record(entry.urls)
                return .init(trashed: [], failed: [], freedBytes: 0)
            },
            escalate: { _, _ in .init(trashed: [], failed: [], freedBytes: 0) })
        let junk = entry([a])
        vm.entries = [junk]

        await vm.clean()
        XCTAssertTrue(cleaned.calls.isEmpty, "an empty selection cleans nothing")

        vm.selected = [junk.id]
        for busy in [\SystemJunkViewModel.isScanning, \.isCleaning] {
            vm[keyPath: busy] = true
            await vm.clean()
            vm[keyPath: busy] = false
        }
        XCTAssertTrue(cleaned.calls.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: a.path))
        XCTAssertEqual(vm.entries.count, 1)
    }
}
