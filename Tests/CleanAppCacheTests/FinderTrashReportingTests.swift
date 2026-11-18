import XCTest
import Darwin
@testable import CleanAppCacheLib

final class FinderTrashReportingTests: XCTestCase {
    private let fm = FileManager.default

    private func scratch() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("finder-reporting-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func file(in root: URL, name: String = "selected") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 65, count: 8192).write(to: url)
        return url
    }

    private func permissionFailure(_ urls: [URL]) -> TrashService.Result {
        .init(trashed: [], failed: urls, obstacles: Dictionary(uniqueKeysWithValues: urls.map { ($0, .needsAdmin) }), freedBytes: 0)
    }

    func testCancelledDispatchDoesNotClaimAnExternallyMovedFile() throws {
        let root = try scratch()
        let original = try file(in: root)
        let elsewhere = root.appendingPathComponent("elsewhere")
        let result = TrashService.escalate(permissionFailure([original]), knownSizes: [:], allowing: [],
            validation: { _ in true }, dispatch: { _ in
                try! self.fm.moveItem(at: original, to: elsewhere)
                return .init(status: 1, stdout: "", stderr: "User canceled (-128)", timedOut: false)
            })
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertEqual(result.alreadyGone, [original])
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertEqual(result.escalation, .cancelled)
        XCTAssertNil(result.obstacles[original])
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.path))
    }

    func testMissingReceiptDoesNotClaimBytesEvenAfterSuccessfulDispatch() throws {
        let root = try scratch()
        let original = try file(in: root)
        let elsewhere = root.appendingPathComponent("elsewhere")
        let result = TrashService.trashWithFinder([original], knownSizes: [:], allowing: [],
            validation: { _ in true }, dispatch: { _ in
                try! self.fm.moveItem(at: original, to: elsewhere)
                return .init(status: 0, stdout: "", stderr: "", timedOut: false)
            })
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.alreadyGone, [original])
        XCTAssertEqual(result.freedBytes, 0)
    }

    func testOnlyAReceiptForTheSelectedObjectCountsAsMoved() throws {
        let root = try scratch()
        let original = try file(in: root)
        let destination = root.appendingPathComponent("scratch-trash")
        let result = TrashService.trashWithFinder([original], knownSizes: [:], allowing: [],
            validation: { _ in true }, dispatch: { _ in
                try! self.fm.moveItem(at: original, to: destination)
                return .init(status: 0, stdout: destination.path + "\0", stderr: "", timedOut: false)
            })
        XCTAssertEqual(result.trashed.map(\.original), [original])
        XCTAssertEqual(result.trashed.map(\.trashed), [destination])
        XCTAssertTrue(result.trashed.allSatisfy(\.viaFinder))
        XCTAssertGreaterThan(result.freedBytes, 0)
        XCTAssertTrue(result.alreadyGone.isEmpty)
        XCTAssertTrue(result.failed.isEmpty)
    }

    func testReceiptForADifferentObjectCannotAuthorizeAccounting() throws {
        let root = try scratch()
        let original = try file(in: root)
        let different = try file(in: root, name: "different")
        let held = root.appendingPathComponent("held")
        let result = TrashService.trashWithFinder([original], knownSizes: [:], allowing: [],
            validation: { _ in true }, dispatch: { _ in
                try! self.fm.moveItem(at: original, to: held)
                return .init(status: 0, stdout: different.path + "\0", stderr: "", timedOut: false)
            })
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.alreadyGone, [original])
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertTrue(fm.fileExists(atPath: different.path))
    }

    func testReceiptInsideAnUnreadableTrashCountsMoveWithoutClaimingBytes() throws {
        guard geteuid() != 0 else { throw XCTSkip("root bypasses scratch POSIX permissions") }
        let root = try scratch()
        let original = try file(in: root)
        let trash = root.appendingPathComponent("private-scratch-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        defer { _ = chmod(trash.path, 0o700) }
        let destination = trash.appendingPathComponent("selected")
        let result = TrashService.trashWithFinder([original], knownSizes: [:], allowing: [],
            validation: { _ in true }, dispatch: { _ in
                try! self.fm.moveItem(at: original, to: destination)
                XCTAssertEqual(chmod(trash.path, 0), 0)
                return .init(status: 0, stdout: destination.path + "\0", stderr: "", timedOut: false)
            })
        XCTAssertEqual(result.trashed.map(\.original), [original])
        XCTAssertEqual(result.trashed.first?.movedBytes, 0)
        XCTAssertEqual(result.freedBytes, 0)
        XCTAssertTrue(result.alreadyGone.isEmpty)
    }

    func testSurvivingTargetIsReportedDespiteAReceipt() throws {
        let root = try scratch()
        let original = try file(in: root)
        let result = TrashService.trashWithFinder([original], knownSizes: [:], allowing: [],
            validation: { _ in true }, dispatch: { _ in
                .init(status: 0, stdout: original.path + "\0", stderr: "", timedOut: false)
            })
        XCTAssertTrue(result.trashed.isEmpty)
        XCTAssertEqual(result.failed, [original])
        XCTAssertEqual(result.obstacles[original], .other)
        XCTAssertEqual(result.freedBytes, 0)
    }

    func testFinderErrorReplacesTheInitialPermissionDiagnosis() throws {
        let root = try scratch()
        let original = try file(in: root)
        let examples: [(String, RemovalObstacle)] = [
            ("File is busy (-47)", .inUse),
            ("File is locked (-45)", .locked),
            ("Volume is read only (-46)", .systemProtected),
            ("Insufficient access privileges (-5000)", .privacyProtected),
            ("Operation not permitted", .privacyProtected),
            ("Unknown Finder failure (-10000)", .other)
        ]
        for (error, expected) in examples {
            let result = TrashService.escalate(permissionFailure([original]), knownSizes: [:], allowing: [],
                validation: { _ in true }, dispatch: { _ in
                    .init(status: 1, stdout: "", stderr: error, timedOut: false)
                })
            XCTAssertEqual(result.failed, [original], error)
            XCTAssertEqual(result.obstacles[original], expected, error)
            XCTAssertTrue(result.trashed.isEmpty, error)
        }
    }

    func testCancelledAndAutomationDeniedSurvivorsKeepTheirActions() throws {
        let root = try scratch()
        let original = try file(in: root)
        let examples: [(String, EscalationOutcome)] = [
            ("User canceled (-128)", .cancelled),
            ("Apple events not permitted (-1743)", .automationDenied)
        ]
        for (error, outcome) in examples {
            let result = TrashService.trashWithFinder([original], knownSizes: [:], allowing: [],
                validation: { _ in true }, dispatch: { _ in
                    .init(status: 1, stdout: "", stderr: error, timedOut: false)
                })
            XCTAssertEqual(result.failed, [original])
            XCTAssertEqual(result.obstacles[original], .needsAdmin)
            XCTAssertEqual(result.escalation, outcome)
        }
    }

    func testNulReceiptsPreserveMultilineNamesAndTrailingWhitespace() throws {
        let root = try scratch()
        let originals = [try file(in: root, name: "first\nline"), try file(in: root, name: "second \n")]
        let trash = root.appendingPathComponent("scratch-trash")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let destinations = originals.map { trash.appendingPathComponent($0.lastPathComponent) }
        let result = TrashService.trashWithFinder(originals, knownSizes: [:], allowing: [],
            validation: { _ in true }, dispatch: { _ in
                for (source, destination) in zip(originals, destinations) {
                    try! self.fm.moveItem(at: source, to: destination)
                }
                return .init(status: 0, stdout: destinations.map(\.path).joined(separator: "\0") + "\0",
                             stderr: "", timedOut: false)
            })
        XCTAssertEqual(result.trashed.map(\.original), originals)
        XCTAssertEqual(result.trashed.map(\.trashed), destinations)
        XCTAssertGreaterThan(result.freedBytes, 0)
        XCTAssertTrue(result.alreadyGone.isEmpty)
    }

    func testMalformedOrTimedOutReceiptNeverClaimsSuccess() throws {
        for timedOut in [false, true] {
            let root = try scratch()
            let original = try file(in: root)
            let destination = root.appendingPathComponent("scratch-trash")
            let result = TrashService.trashWithFinder([original], knownSizes: [:], allowing: [],
                validation: { _ in true }, dispatch: { _ in
                    try! self.fm.moveItem(at: original, to: destination)
                    return .init(status: 0, stdout: destination.path + (timedOut ? "\0" : ""),
                                 stderr: "", timedOut: timedOut)
                })
            XCTAssertTrue(result.trashed.isEmpty)
            XCTAssertEqual(result.alreadyGone, [original])
            XCTAssertEqual(result.freedBytes, 0)
        }
    }
}
