import XCTest
@testable import CleanAppCacheLib

final class FileKindTests: XCTestCase {

    func testClassificationByLastExtensionOnly() {
        let cases: [(String, FileKind)] = [
            ("Holiday.MOV", .video), ("clip.mkv", .video), ("a.webm", .video),
            ("backup.tar.gz", .archive), ("Xcode.xip", .archive), ("tool.pkg", .archive), ("x.tgz", .archive),
            ("Installer.dmg", .diskImage), ("win.iso", .diskImage),
            ("TM.sparsebundle", .diskImage), ("vm.qcow2", .diskImage),
            ("song.FLAC", .audio), ("voice.m4a", .audio),
            ("App.xcodeproj", .project), ("Mock.sketch", .project),
            ("shot.psd", .project), ("Song.logicx", .project),
            ("notes.txt", .data), ("README", .data), (".zshrc", .data), ("photo.heic", .data),
            ("archive.zip.part", .data),                 // only the last extension counts
            ("/Users/x/Downloads/Movie.mp4", .video),    // a full path is fine
            ("weird.", .data), ("", .data),
        ]
        for (name, kind) in cases {
            XCTAssertEqual(FileKind.of(name), kind, name)
        }
    }

    /// The palette is indexed by `allCases` position; a reordered enum would
    /// silently recolour every kind.
    func testPaletteHasOneColourPerKind() {
        XCTAssertEqual(FileKind.lightPalette.count, FileKind.allCases.count)
    }
}
