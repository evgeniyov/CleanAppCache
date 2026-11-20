import XCTest
@testable import CleanAppCacheLib

@MainActor
final class DuplicateUndoTests: XCTestCase {
    func testUndoVerifiesTheRestoredCopyAndAllowsMovingItAgain() async throws {
        try await checkUndo(editedWhileTrashed: false)
    }

    func testUndoDoesNotReinstateAChangedCopyInTheDuplicateGroup() async throws {
        try await checkUndo(editedWhileTrashed: true)
    }

    private func checkUndo(editedWhileTrashed: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("duplicate-undo-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("trash")
        let fixtures = root.appendingPathComponent("fixtures")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: fixtures, withIntermediateDirectories: true)
        for name in ["keep", "extra"] {
            try Data("same bytes".utf8).write(to: fixtures.appendingPathComponent(name))
        }
        let scan = await DuplicateFinder.shared.findDuplicates(in: fixtures, minSize: 1) { _, _ in }
        let group = try XCTUnwrap(scan.groups.first)
        let copy = try XCTUnwrap(group.files.first { $0.name == "extra" })
        let vm = DuplicatesViewModel(preflight: { DuplicateFinder.isUnchanged($0) }, mover: { source in
            let destination = bin.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: destination)
            return destination
        }, history: CleanupHistory(directory: root), invalidateStorage: { _ in })
        vm.groups = [group]
        vm.selectedForDeletion = [copy.id]

        let previousToasts = Set(ToastCenter.shared.toasts.map(\.id))
        await vm.deleteSelected()
        XCTAssertFalse(fm.fileExists(atPath: copy.path))
        if editedWhileTrashed {
            let file = try FileHandle(forWritingTo: bin.appendingPathComponent(copy.name))
            try file.write(contentsOf: Data("new bytes!".utf8))
            try file.close()
        }
        let undo = try XCTUnwrap(ToastCenter.shared.toasts.first {
            !previousToasts.contains($0.id) && $0.action != nil
        })
        ToastCenter.shared.runAction(undo)
        for _ in 0..<200 where vm.isDeleting { try await Task.sleep(nanoseconds: 5_000_000) }

        XCTAssertFalse(vm.isDeleting)
        XCTAssertTrue(fm.fileExists(atPath: copy.path))
        if editedWhileTrashed {
            XCTAssertTrue(vm.groups.isEmpty)
            XCTAssertEqual(try Data(contentsOf: copy.url), Data("new bytes!".utf8))
        } else {
            let refreshed = try XCTUnwrap(vm.groups.first?.files.first { $0.url == copy.url })
            XCTAssertTrue(DuplicateFinder.isUnchanged(refreshed))
            vm.selectedForDeletion = [refreshed.id]
            await vm.deleteSelected()
            XCTAssertFalse(fm.fileExists(atPath: copy.path))
        }
    }
}
