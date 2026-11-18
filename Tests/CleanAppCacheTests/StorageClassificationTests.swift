import XCTest
@testable import CleanAppCacheLib

@MainActor
final class StorageClassificationTests: XCTestCase {
    private var scratch: URL!
    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("classification-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: scratch) }
    private func target(_ name: String) throws -> StorageClassification.Target {
        let url = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return .init(name: name, icon: "folder", url: url)
    }

    func testFoldersAreDisjointAndResidualHasNoRoot() throws {
        let apps = try target("Applications"), docs = try target("Documents")
        let nested = StorageClassification.Target(name: "Nested apps", icon: "folder", url: docs.url.appendingPathComponent("Example.app"))
        let roots = StorageClassification.disjoint([apps, docs, nested, docs])
        XCTAssertEqual(roots.count, 2)
        let measured = StorageClassification.Measurement(bytes: [apps.url.path: 200, docs.url.path: 300])
        let rows = StorageClassification.breakdown(targets: [apps, docs, nested], measurement: measured, total: 1000, used: 800)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.bytes }, 800)
        XCTAssertEqual(rows.first { $0.name == "Other" }?.bytes, 300)
        XCTAssertEqual(rows.first { $0.isResidual }?.path, "")
        XCTAssertFalse(rows.contains { $0.name == "Nested apps" })
    }

    func testUnknownAndPartialNeverBecomeMeasuredZero() throws {
        let docs = try target("Documents")
        let rows = StorageClassification.breakdown(targets: [docs], measurement: .init(partial: true), total: 1000, used: 800)
        let row = try XCTUnwrap(rows.first { !$0.isResidual })
        XCTAssertFalse(row.sizeKnown)
        XCTAssertTrue(row.isPartial)
        XCTAssertEqual(row.formattedSize, Fmt.none)
        XCTAssertEqual(rows.first { $0.isResidual }?.bytes, 800)
    }

    func testOverallocatedFoldersDoNotInventAZeroResidualMeasurement() throws {
        let docs = try target("Documents")
        let rows = StorageClassification.breakdown(targets: [docs], measurement: .init(bytes: [docs.url.path: 900]), total: 1000, used: 800)
        XCTAssertTrue(rows.allSatisfy { !$0.reconciled })
        XCTAssertFalse(try XCTUnwrap(rows.first { $0.isResidual }).sizeKnown)
        XCTAssertEqual(rows.first { !$0.isResidual }?.bytes, 900, "do not silently scale folder sizes")
    }

    func testOneTraversalCountsCrossCategoryHardLinksOnceAndDoesNotFollowSymlinks() async throws {
        let apps = try target("Applications"), docs = try target("Documents"), outside = try target("outside")
        let file = apps.url.appendingPathComponent("shared")
        try Data(repeating: 65, count: 65536).write(to: file)
        try FileManager.default.linkItem(at: file, to: docs.url.appendingPathComponent("hard-link"))
        try Data(repeating: 66, count: 131072).write(to: outside.url.appendingPathComponent("outside-file"))
        try FileManager.default.createSymbolicLink(at: docs.url.appendingPathComponent("external-link"), withDestinationURL: outside.url)
        let sizes = await StorageClassification.measure([apps, docs], volume: scratch)
        XCTAssertFalse(sizes.partial)
        let total = sizes.bytes.values.reduce(0, +)
        let data = await DirectorySizeProbe.capture(executable: URL(fileURLWithPath: "/usr/bin/du"), arguments: ["-skx", apps.url.path, docs.url.path], timeout: 5)
        let expected = StorageClassification.parse(try XCTUnwrap(data), roots: [apps.url, docs.url]).values.reduce(0, +)
        XCTAssertEqual(total, expected)
        XCTAssertGreaterThanOrEqual(total, 65536)
        XCTAssertLessThan(total, 131072, "hard link and external symlink must not add file allocation twice")
        let linkedRoot = scratch.appendingPathComponent("symlink-category")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside.url)
        let skipped = await StorageClassification.measure([.init(name: "linked", icon: "folder", url: linkedRoot)], volume: scratch)
        XCTAssertTrue(skipped.partial)
        XCTAssertNil(skipped.bytes[linkedRoot.path])
    }

    func testAbsentFolderIsKnownEmptyAndMalformedOutputCannotForgeTargets() async throws {
        let missing = scratch.appendingPathComponent("missing")
        let result = await StorageClassification.measure([.init(name: "missing", icon: "folder", url: missing)], volume: scratch)
        XCTAssertEqual(result.bytes[missing.path], 0)
        let text = "bad\t\(missing.path)\n18446744073709551615\t\(missing.path)\n99\t/forged\n0\t\(missing.path)\n"
        XCTAssertEqual(StorageClassification.parse(Data(text.utf8), roots: [missing]), [missing.path: 0])
    }

    func testFailedProbeKeepsPartialOutputWithoutPretendingSuccess() async throws {
        let response = await DirectorySizeProbe.captureResponse(executable: URL(fileURLWithPath: "/bin/sh"),
                                                                arguments: ["-c", "printf '12\\t/synthetic\\n'; exit 1"], timeout: 3)
        let captured = try XCTUnwrap(response)
        XCTAssertFalse(captured.succeeded)
        XCTAssertEqual(StorageClassification.parse(captured.data, roots: [URL(fileURLWithPath: "/synthetic")]), ["/synthetic": 12288])
    }

    func testSelectingResidualCancelsPriorDetailsWithoutScanningRoot() async throws {
        let docs = try target("Documents")
        let manager = StorageManager(diskCache: DiskCacheManager(directory: scratch.appendingPathComponent("cache")),
                                     measure: { _, _ in try? await Task.sleep(nanoseconds: 200_000_000); return [:] })
        let model = StorageViewModel(manager: manager)
        model.loadDetail(for: .init(name: "Documents", icon: "folder", bytes: 0, path: docs.url.path, percentOfTotal: 0))
        model.loadDetail(for: .init(name: "Other", icon: "folder", bytes: 800, path: "", percentOfTotal: 0.8, isResidual: true))
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(model.detailItems.isEmpty)
        XCTAssertFalse(model.isLoadingDetail)
        XCTAssertFalse(model.isSizingDetail)
        XCTAssertEqual(model.currentDetailPath, "")
    }
}
