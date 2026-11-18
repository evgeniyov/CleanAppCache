import XCTest
@testable import CleanAppCacheLib

final class TrashIdentityTests: XCTestCase {
    private let fm = FileManager.default

    private func scratch() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("trash-identity-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func move(_ original: URL, to destination: URL) -> TrashService.Result {
        TrashService.trash([original], mover: { source in
            try self.fm.moveItem(at: source, to: destination)
            return destination
        })
    }

    func testUnchangedTrashedObjectCanBeRestored() throws {
        let root = try scratch()
        let original = root.appendingPathComponent("original")
        let destination = root.appendingPathComponent("scratch-trash")
        try Data("selected".utf8).write(to: original)
        let result = move(original, to: destination)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(TrashService.restore(result.trashed), 1)
        XCTAssertEqual(try String(contentsOf: original), "selected")
        XCTAssertTrue(RemovalCheck.isMissing(destination))
    }

    func testUndoRefusesReplacementAtTrashedPath() throws {
        let root = try scratch()
        let original = root.appendingPathComponent("original")
        let destination = root.appendingPathComponent("scratch-trash")
        let held = root.appendingPathComponent("held")
        try Data("selected".utf8).write(to: original)
        let result = move(original, to: destination)
        try fm.moveItem(at: destination, to: held)
        try Data("replacement".utf8).write(to: destination)

        XCTAssertEqual(TrashService.restore(result.trashed), 0)
        XCTAssertTrue(RemovalCheck.isMissing(original))
        XCTAssertEqual(try String(contentsOf: destination), "replacement")
        XCTAssertEqual(try String(contentsOf: held), "selected")
    }

    func testUndoPinsObjectBeforeMoverReturns() throws {
        let root = try scratch()
        let original = root.appendingPathComponent("original")
        let destination = root.appendingPathComponent("scratch-trash")
        let held = root.appendingPathComponent("held")
        try Data("selected".utf8).write(to: original)
        let result = TrashService.trash([original], mover: { source in
            try self.fm.moveItem(at: source, to: destination)
            try self.fm.moveItem(at: destination, to: held)
            try Data("replacement".utf8).write(to: destination)
            return destination
        })

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(TrashService.restore(result.trashed), 0)
        XCTAssertTrue(RemovalCheck.isMissing(original))
        XCTAssertEqual(try String(contentsOf: destination), "replacement")
        XCTAssertEqual(try String(contentsOf: held), "selected")
    }

    func testUndoAllowsChangesInsideTheSameTrashedDirectory() throws {
        let root = try scratch()
        let original = root.appendingPathComponent("original")
        let destination = root.appendingPathComponent("scratch-trash")
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        try Data("selected".utf8).write(to: original.appendingPathComponent("document"))
        let result = move(original, to: destination)
        try Data("edited".utf8).write(to: destination.appendingPathComponent("document"))

        XCTAssertEqual(TrashService.restore(result.trashed), 1)
        XCTAssertEqual(try String(contentsOf: original.appendingPathComponent("document")), "edited")
    }

    func testPublicInitializerPinsTrashedObjectAndFinderMovesStayExcluded() throws {
        let root = try scratch()
        let original = root.appendingPathComponent("original")
        let destination = root.appendingPathComponent("scratch-trash")
        try Data("selected".utf8).write(to: destination)
        let finderMove = TrashService.Trashed(original: original, trashed: destination, viaFinder: true)
        XCTAssertEqual(TrashService.restore([finderMove]), 0)
        XCTAssertTrue(RemovalCheck.isMissing(original))

        let ordinaryMove = TrashService.Trashed(original: original, trashed: destination)
        XCTAssertEqual(TrashService.restore([ordinaryMove]), 1)
        XCTAssertEqual(try String(contentsOf: original), "selected")
    }

    func testPublicInitializerRefusesLaterReplacement() throws {
        let root = try scratch()
        let original = root.appendingPathComponent("original")
        let destination = root.appendingPathComponent("scratch-trash")
        try Data("selected".utf8).write(to: destination)
        let item = TrashService.Trashed(original: original, trashed: destination)
        try fm.moveItem(at: destination, to: root.appendingPathComponent("held"))
        try Data("replacement".utf8).write(to: destination)

        XCTAssertEqual(TrashService.restore([item]), 0)
        XCTAssertTrue(RemovalCheck.isMissing(original))
        XCTAssertEqual(try String(contentsOf: destination), "replacement")
    }
}
