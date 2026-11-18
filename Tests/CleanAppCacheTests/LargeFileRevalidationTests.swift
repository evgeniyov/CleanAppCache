import XCTest
@testable import CleanAppCacheLib

@MainActor
final class LargeFileRevalidationTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("large-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    private func scannedFile(_ name: String, in root: URL) throws -> LargeFile {
        let url = root.appendingPathComponent(name)
        try Data("scanned contents".utf8).write(to: url)
        return LargeFile(url: url, size: 4096, modified: nil, accessed: nil, isDeletable: true)
    }

    func testCleanupLeavesReplacementDirectoryAndMovesOnlyTheUnchangedFile() async throws {
        let root = try scratch()
        let replaced = try scannedFile("replaced", in: root)
        let unchanged = try scannedFile("unchanged", in: root)
        let gone = try scannedFile("gone", in: root)
        let held = root.appendingPathComponent("held")
        let bin = root.appendingPathComponent("scratch-trash")
        let history = CleanupHistory(directory: root)
        let fm = FileManager.default
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.moveItem(at: replaced.url, to: held)
        try fm.createDirectory(at: replaced.url, withIntermediateDirectories: false)
        let document = replaced.url.appendingPathComponent("document")
        try Data("new document".utf8).write(to: document)
        try fm.removeItem(at: gone.url)

        let vm = LargeFilesViewModel(trash: { urls, validation in
            TrashService.trash(urls, validationObstacle: .changedSinceScan, validation: validation, mover: { source in
                let dest = bin.appendingPathComponent(source.lastPathComponent)
                try FileManager.default.moveItem(at: source, to: dest)
                return dest
            })
        }, history: history)
        vm.files = [replaced, unchanged, gone]
        vm.selected = Set(vm.files.map(\.id))
        await vm.deleteSelected()

        XCTAssertEqual(try String(contentsOf: document), "new document")
        XCTAssertEqual(try String(contentsOf: held), "scanned contents")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: bin.path), ["unchanged"])
        XCTAssertEqual(vm.files.map(\.id), [replaced.id])
        XCTAssertEqual(history.records.first?.itemCount, 1)
    }

    func testFinderHandoffRefusesFileChangedAfterInitialAttempt() async throws {
        let root = try scratch()
        let file = try scannedFile("selected", in: root)
        let held = root.appendingPathComponent("held")
        let history = CleanupHistory(directory: root)
        let vm = LargeFilesViewModel(trash: { urls, validation in
            XCTAssertTrue(validation(file.url))
            do {
                try FileManager.default.moveItem(at: file.url, to: held)
                try Data("replacement".utf8).write(to: file.url)
            } catch {
                XCTFail("Could not replace fixture: \(error)")
            }
            let initial = TrashService.Result(trashed: [], failed: urls, obstacles: [file.url: .needsAdmin], freedBytes: 0)
            let result = TrashService.escalate(initial, knownSizes: [:], allowing: [],
                validationObstacle: .changedSinceScan, validation: validation, dispatch: { _ in
                    XCTFail("Finder must receive no request for a replacement")
                    return .init(status: 1, stdout: "", stderr: "", timedOut: false)
                })
            XCTAssertEqual(result.validationRejected, [file.url])
            XCTAssertEqual(result.obstacles[file.url], .changedSinceScan)
            return result
        }, history: history)
        vm.files = [file]
        vm.selected = [file.id]
        await vm.deleteSelected()

        XCTAssertEqual(try String(contentsOf: file.url), "replacement")
        XCTAssertEqual(try String(contentsOf: held), "scanned contents")
        XCTAssertTrue(history.records.isEmpty)
    }
}
