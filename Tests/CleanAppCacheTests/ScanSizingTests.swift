import XCTest
@testable import CleanAppCacheLib

final class ScanSizingTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("scan-sizing-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: root)
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func payload(in directory: URL, name: String = "file") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 42, count: 8192).write(to: url)
        return url
    }

    private func executable(_ name: String, body: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    func testDeveloperProbeKeepsCompletedArtifactsWithinOneBudget() async throws {
        for number in 1...6 {
            let project = try folder("project-\(number)")
            try fm.createDirectory(at: project.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
        }
        let probe = ProjectFixtureProbe()
        let cache = DiskCacheManager(directory: try folder("size-state"))
        let storage = StorageManager(diskCache: cache, measure: { urls, timeout in
            await probe.measure(urls, timeout: timeout)
        })
        let manager = DevCleanManager()
        let started = DispatchTime.now()
        let result = await manager.scanProjectsWithReport(home: root, storage: storage, timeLimit: 1.5)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000_000

        let completed = await probe.quickProject
        XCTAssertEqual(result.artifacts.map(\.projectName), [try XCTUnwrap(completed)])
        XCTAssertEqual(result.skipped.totalCount, 5)
        let peak = await probe.peak
        XCTAssertEqual(peak, 4)
        // Five slow measurements wait out their remaining budgets. Giving
        // each one a fresh 1.5-second timeout would take several seconds.
        XCTAssertLessThan(elapsed, 3)
    }

    @MainActor
    func testSystemDataShowsReadableSubtotalAsPartial() async throws {
        let readable = try folder("cache")
        let partlyReadable = try folder("system")
        let blocked = try folder("system/blocked")
        try payload(in: readable)
        try payload(in: partlyReadable)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }

        let good = await DirectorySizeProbe.measureRoot(readable, timeout: 5)
        let partial = await DirectorySizeProbe.measureRoot(partlyReadable, timeout: 5)
        XCTAssertTrue(good.complete)
        XCTAssertFalse(partial.complete)
        let subtotal = try XCTUnwrap(partial.bytes)
        XCTAssertGreaterThanOrEqual(subtotal, 8192)
        let component = SystemDataManager.measuredComponent(.systemCaches, paths: [readable.path, partlyReadable.path],
            measured: [readable.path: good, partlyReadable.path: partial])
        XCTAssertTrue(component.isPartial)
        XCTAssertEqual(component.bytes, (good.bytes ?? 0) + subtotal)
        XCTAssertTrue(try XCTUnwrap(component.formattedSize).hasPrefix("≥"))
    }

    func testSystemJunkCountsOneAllocationAcrossRoots() async throws {
        let first = try folder("first")
        let second = try folder("second")
        let file = try payload(in: first)
        try fm.linkItem(at: file, to: second.appendingPathComponent("link"))
        let urls = [first, second]
        let identities = RemovalIdentity.capture(urls)

        let independent = await DirectorySizeProbe.measure(urls, timeout: 5)
        XCTAssertEqual(independent.count, 2)
        let grouped = SystemJunkManager.measureGroup(urls, identities: identities)
        let allocation = try XCTUnwrap(StorageManager.allocatedLeafSize(at: file))
        XCTAssertGreaterThanOrEqual(allocation, 8192)
        XCTAssertEqual(grouped.measured, Set(urls))
        XCTAssertTrue(grouped.hasSharedAllocation)
        XCTAssertEqual(grouped.bytes, independent.values.reduce(0, +) - allocation)
    }

    func testSystemJunkFailedRootDoesNotConsumeAReadablePeersAllocation() async throws {
        let incomplete = try folder("incomplete")
        let file = try payload(in: incomplete)
        let blocked = try folder("incomplete/blocked")
        let readable = try folder("readable")
        try fm.linkItem(at: file, to: readable.appendingPathComponent("link"))
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let urls = [incomplete, readable]

        let grouped = SystemJunkManager.measureGroup(urls, identities: RemovalIdentity.capture(urls))
        let measured = await DirectorySizeProbe.measureRoot(readable, timeout: 5)
        XCTAssertEqual(grouped.measured, [readable])
        XCTAssertTrue(measured.complete)
        XCTAssertEqual(grouped.bytes, measured.bytes)
    }

    func testFailedSmartCleanupBatchRetriesOnlyItsUnreadableRoot() async throws {
        let unreadable = try folder("unreadable")
        try payload(in: unreadable)
        let blocked = try folder("unreadable/child")
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let readable = try (1...8).map { number in
            let url = try folder("readable-\(number)")
            try payload(in: url)
            return url
        }
        let command = try executable("measuring-du", body: """
            base="${0%/*}"
            printf '%s\\n' "$#" >> "$base/calls"
            /bin/chmod 000 "$base/unreadable/child"
            exec /usr/bin/du "$@"
            """)
        let scanner = CleanAppCacheLib.Scanner(duExecutable: command)
        let result = await scanner.scanCategory(category: .installers,
            source: .directories(([unreadable] + readable).map(\.path)), inUse: { _ in false })

        XCTAssertEqual(Set(result.items.map(\.url.path)), Set(readable.map(\.path)))
        XCTAssertTrue(result.items.allSatisfy { $0.size >= 8192 })
        XCTAssertEqual(result.skipped.counts[.unreadable], 1)
        let calls = try String(contentsOf: root.appendingPathComponent("calls"), encoding: .utf8)
        // One batch of nine, then one retry. Full fallback needs ten calls.
        XCTAssertEqual(calls.split(separator: "\n"), ["10", "2"])
    }

    func testFailedSmartCleanupBatchRetriesZeroSizedHardLinkPeer() async throws {
        let unreadable = try folder("unreadable")
        let file = try payload(in: unreadable)
        let blocked = try folder("unreadable/child")
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        let readable = try folder("readable")
        try fm.linkItem(at: file, to: readable.appendingPathComponent("link"))
        let standalone = await DirectorySizeProbe.measureRoot(readable, timeout: 5)
        let size = try XCTUnwrap(standalone.bytes)
        XCTAssertTrue(standalone.complete)
        XCTAssertGreaterThanOrEqual(size, 8192)

        let command = try executable("measuring-du", body: """
            /bin/chmod 000 "${0%/*}/unreadable/child"
            exec /usr/bin/du "$@"
            """)
        let scanner = CleanAppCacheLib.Scanner(duExecutable: command)
        let result = await scanner.scanCategory(category: .installers,
            source: .directories([unreadable.path, readable.path]), inUse: { _ in false })

        XCTAssertEqual(result.items.map(\.url.path), [readable.path])
        XCTAssertEqual(result.items.map(\.size), [size])
        XCTAssertEqual(result.skipped.counts[.unreadable], 1)
    }

    func testLargeFilesStopsProducerAtBudgetAndPreservesNULFraming() async throws {
        let file = try payload(in: root, name: "with\na newline")
        let command = try executable("busy-find", body: """
            i=0
            while [ "$i" -lt 50000 ]; do
                printf '%s\\000' "$1/with
            a newline"
                i=$((i+1))
            done
            : > "$1/producer-finished"
            """)

        let marker = root.appendingPathComponent("producer-finished")
        let buffered = await DirectorySizeProbe.capture(executable: command, arguments: [root.path], timeout: 10)
        XCTAssertEqual(try XCTUnwrap(buffered).filter { $0 == 0 }.count, 50_000)
        try fm.removeItem(at: marker)

        let result = await LargeFilesViewModel.scanForLargeFiles(root: root, minBytes: 1,
            findExecutable: command, statLimit: 3)

        XCTAssertEqual(result.outcome, .limited)
        XCTAssertEqual(result.files.map(\.url), [file, file, file])
        XCTAssertFalse(fm.fileExists(atPath: marker.path))
    }

    func testLargeFilesPrunesUnreadableCloudFolder() async throws {
        let visible = try payload(in: root)
        let excluded = try folder("Library/CloudStorage/provider")
        try payload(in: excluded)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: excluded.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: excluded.path) }

        let result = await LargeFilesViewModel.scanForLargeFiles(root: root, minBytes: 1)

        XCTAssertEqual(result.outcome, .complete)
        XCTAssertEqual(result.files.map(\.url), [visible])
    }

    @MainActor
    func testLargeFilesPersistsEmptyPartialOutcomeAcrossViewDisappearance() async throws {
        let blocked = try folder("blocked")
        let vm = LargeFilesViewModel(trash: { _, _ in .init(trashed: [], failed: [], freedBytes: 0) },
                                     history: CleanupHistory(directory: try folder("history")))
        vm.setCustomSearchFolder(root)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path) }
        vm.startScan()
        for _ in 0..<300 {
            if !vm.isScanning { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(vm.isScanning)
        XCTAssertTrue(vm.files.isEmpty)
        XCTAssertEqual(vm.scanOutcome, .unreadable)
        vm.cancelScan() // The view invokes this on disappearance.
        XCTAssertEqual(vm.scanOutcome, .unreadable)
        XCTAssertNotNil(vm.lastScanDate)
        vm.invalidateResults()
        XCTAssertNil(vm.scanOutcome)
    }

    func testLargeFilesTimeoutWithNoMatchesIsPartial() async throws {
        let command = try executable("waiting-find", body: "exec /bin/sleep 30")
        let result = await LargeFilesViewModel.scanForLargeFiles(root: root, minBytes: 1,
            findExecutable: command, timeout: 0.1)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.outcome, .limited)
    }

    func testLargeFilesCancellationStopsWaitingProducer() async throws {
        let command = try executable("waiting-find", body: """
            : > "$1/started"
            exec /bin/sleep 10
            """)
        let folder = try XCTUnwrap(root)
        let work = Task {
            await LargeFilesViewModel.scanForLargeFiles(root: folder, minBytes: 1, findExecutable: command)
        }
        defer { work.cancel() }
        let marker = folder.appendingPathComponent("started")
        for _ in 0..<300 {
            if fm.fileExists(atPath: marker.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(fm.fileExists(atPath: marker.path))
        let started = DispatchTime.now()
        work.cancel()
        let result = await work.value
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds, 3_000_000_000)
        XCTAssertTrue(result.files.isEmpty)
    }
}

private actor ProjectFixtureProbe {
    private var active = 0
    private(set) var peak = 0
    private(set) var quickProject: String?

    func measure(_ urls: [URL], timeout: TimeInterval) async -> [String: UInt64] {
        guard let url = urls.first else { return [:] }
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        // Directory traversal order is unspecified. Give the first started
        // probe a short delay so the fixture always completes one measurement.
        let quick = quickProject == nil
        if quick { quickProject = url.deletingLastPathComponent().lastPathComponent }
        try? await Task.sleep(nanoseconds: quick ? 100_000_000 : UInt64(timeout * 1_000_000_000))
        return quick ? [url.path: 8192] : [:]
    }
}
