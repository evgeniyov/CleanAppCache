import XCTest
@testable import CleanAppCacheLib

/// Architectural guard, same shape as `DeletionRoutingTests`.
///
/// Two promises the design system makes are verbal: the palette is closed
/// (every colour is a `DesignTokens` member in `Theme.swift`) and `Fmt` is the
/// only size formatter (`ByteCountFormatter` follows the system locale, not the
/// in-app language switch — it printed "57,91 GB" into a Russian interface).
/// CI greps for both; this is the same check for a local `swift test`.
final class DesignInvariantsTests: XCTestCase {

    private var sourcesDirectory: URL {
        // …/Tests/CleanAppCacheTests/DesignInvariantsTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// Non-comment lines in `Sources/**/*.swift` containing `needle`, as
    /// "File.swift:line — text", skipping files named in `except`.
    private func offenders(containing needle: String, except: Set<String> = []) throws -> [String] {
        let fm = FileManager.default
        let enumerator = try XCTUnwrap(fm.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil),
                                       "could not enumerate \(sourcesDirectory.path)")
        var found: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            guard !except.contains(name) else { continue }
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                if trimmed.contains(needle) {
                    found.append("\(name):\(index + 1) — \(trimmed)")
                }
            }
        }
        return found
    }

    func testOnlyThemeSpellsAColour() throws {
        let hits = try offenders(containing: "Color(hex", except: ["Theme.swift"])
        XCTAssertTrue(hits.isEmpty, """
            Colours are declared once, in Design/Theme.swift, and read through `Palette`:
            \(hits.joined(separator: "\n"))
            """)
    }

    func testOnlyFmtFormatsSizes() throws {
        let hits = try offenders(containing: "ByteCountFormatter")
        XCTAssertTrue(hits.isEmpty, """
            Sizes and speeds go through `Fmt` (Design/Format.swift):
            \(hits.joined(separator: "\n"))
            """)
    }
}
