import XCTest
import CryptoKit
@testable import CleanAppCacheLib

final class DuplicateCancellationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("duplicate-cancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func file(_ name: String, data: Data) throws -> DuplicateFile {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return DuplicateFile(url: url, size: UInt64(data.count), modified: nil)
    }

    func testFullAndPartialHashesMatchSHA256WithoutCancellation() throws {
        let bytes = Data(repeating: 42, count: 1_048_576 + 37)
        let candidate = try file("candidate", data: bytes)

        XCTAssertEqual(DuplicateFinder.hash(candidate), Data(SHA256.hash(data: bytes)))
        XCTAssertEqual(DuplicateFinder.hash(candidate, limit: 65_536),
                       Data(SHA256.hash(data: bytes.prefix(65_536))))
    }

    func testScanFlagCancelsBetweenReadsWithoutHashingTheRestOfTheFile() throws {
        let candidate = try file("candidate", data: Data(repeating: 42, count: 1_048_576 + 37))
        let flag = CancellationFlag()
        var reads = 0

        let digest = DuplicateFinder.hash(candidate, flag: flag) { handle, amount in
            let chunk = try handle.read(upToCount: amount)
            reads += 1
            flag.cancel()
            return chunk
        }

        XCTAssertNil(digest, "an interrupted hash cannot confirm a duplicate")
        XCTAssertEqual(reads, 1, "cancellation must stop before the next chunk")
    }

    func testTaskCancellationDuringAReadStopsBeforeTheNextChunk() async throws {
        let candidate = try file("candidate", data: Data(repeating: 42, count: 1_048_576 + 37))

        let outcome = await Task.detached {
            var reads = 0
            let digest = DuplicateFinder.hash(candidate) { handle, amount in
                let chunk = try handle.read(upToCount: amount)
                reads += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return chunk
            }
            return (digest, reads, Task.isCancelled)
        }.value

        XCTAssertTrue(outcome.2)
        XCTAssertNil(outcome.0)
        XCTAssertEqual(outcome.1, 1)
    }

    func testAlreadyCancelledFlagDoesNotReadAnyContent() throws {
        let candidate = try file("candidate", data: Data("fixture".utf8))
        let flag = CancellationFlag()
        flag.cancel()

        let digest = DuplicateFinder.hash(candidate, flag: flag) { _, _ in
            XCTFail("a cancelled scan must not start another read")
            return nil
        }

        XCTAssertNil(digest)
    }

    func testCancellingOneScanDoesNotCancelTheNextScan() async throws {
        let bytes = Data("identical fixture content".utf8)
        _ = try file("a", data: bytes)
        _ = try file("b", data: bytes)
        let flag = CancellationFlag()
        flag.cancel()
        let finder = DuplicateFinder.shared

        let cancelled = await finder.findDuplicates(in: root, minSize: 1, flag: flag) { _, _ in }
        let next = await finder.findDuplicates(in: root, minSize: 1) { _, _ in }

        XCTAssertTrue(cancelled.groups.isEmpty)
        XCTAssertEqual(next.groups.count, 1)
        XCTAssertEqual(next.groups.first?.files.count, 2)
        for candidate in try XCTUnwrap(next.groups.first).files {
            XCTAssertTrue(DuplicateFinder.isUnchanged(candidate))
        }
    }
}
