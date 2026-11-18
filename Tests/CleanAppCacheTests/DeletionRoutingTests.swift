import XCTest
@testable import CleanAppCacheLib

/// Architectural guard.
///
/// `PathGuard` only protects the user if every delete goes through
/// `DeletionService` or `TrashService`. A comment saying "all deletes go
/// through here" does not survive the next feature; this test does, within
/// its limits. It scans for the spellings in `API.needles` — FileManager
/// remove, replace and trash calls, POSIX unlink/rmdir/removefile, NSWorkspace
/// recycle, `rm` and `find -delete` arguments, AppleScript `do shell script`,
/// AppleScript addressed to Finder —
/// and each exemption names both the file and the API families it may use, so
/// an exempt file cannot quietly pick up another one. A delete spelled some
/// other way (a wrapper around a C call, a command assembled from pieces) is
/// not detected; review still has to catch that.
final class DeletionRoutingTests: XCTestCase {

    /// Destructive APIs, grouped so an exemption can allow one family only.
    enum API: String, CaseIterable {
        case fileManagerRemove = "FileManager removeItem"
        case fileManagerTrash = "FileManager trashItem"
        case posixRemove = "unlink / rmdir / removefile"
        case workspaceRecycle = "NSWorkspace recycle"
        case shellRemove = "rm, find -delete or AppleScript do shell script"
        case finderScript = "AppleScript sent to Finder"
        case uvCacheClean = "uv cache clean"

        var needles: [String] {
            switch self {
            case .fileManagerRemove: return ["removeItem(", "replaceItemAt(", "replaceItem("]
            case .fileManagerTrash:  return ["trashItem("]
            case .posixRemove:       return ["unlink(", "unlinkat(", "rmdir(", "removefile("]
            case .workspaceRecycle:  return [".recycle("]
            case .shellRemove:       return ["/bin/rm", "\"rm\"", "\"-delete\"", "do shell script"]
            // Finder deletes whatever it is told to, with its own rights.
            case .finderScript:      return ["application \\\"Finder\\\"", "application \"Finder\""]
            case .uvCacheClean:      return ["\"cache\", \"clean\""]
            }
        }
    }

    /// File name → the API families it may call directly.
    private static let exemptions: [String: Set<API>] = [
        // The two routing points every user-data delete goes through.
        // DeletionService also builds the root `rm` for the administrator
        // delete, after `administratorTarget(for:)`; TrashService hands
        // protected items to Finder after PathGuard.
        "DeletionService.swift": [.fileManagerRemove, .shellRemove],
        "TrashService.swift": [.fileManagerTrash, .finderScript],
        // uv requires its own exclusive cache lock. This primitive validates
        // PathGuard and scan identities, pins --cache-dir, and never uses force.
        "UvCacheCleaner.swift": [.uvCacheClean],
        // Runs `do shell script … with administrator privileges` for the
        // commands the files above build; it composes none of its own.
        "AppleScriptRunner.swift": [.shellRemove],
        // Each of these deletes only the app's own housekeeping files.
        "DiskCacheManager.swift": [.fileManagerRemove],    // the size cache
        "Log.swift": [.fileManagerRemove],                 // log files
        "DashboardViewModel.swift": [.fileManagerRemove],  // the scan cache
        "CleanupHistory.swift": [.fileManagerRemove],      // a stale corrupt history copy
    ]

    private var sourcesDirectory: URL {
        // …/Tests/CleanAppCacheTests/DeletionRoutingTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    func testOnlyTheDeletionServicesTouchTheFilesystemDirectly() throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourcesDirectory, includingPropertiesForKeys: nil) else {
            return XCTFail("could not enumerate \(sourcesDirectory.path)")
        }

        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            let allowed = Self.exemptions[name] ?? []
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for (index, line) in Self.codeLines(of: source).enumerated() {
                for api in API.allCases where !allowed.contains(api) {
                    if api.needles.contains(where: { line.contains($0) }) {
                        let text = line.trimmingCharacters(in: .whitespaces)
                        offenders.append("\(name):\(index + 1) [\(api.rawValue)] — \(text)")
                    }
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            These call sites delete files without going through PathGuard.
            Route them through DeletionService.delete / TrashService.trash, or
            add the file and API family to `exemptions` with a reason:
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    func testCodeLinesDropCommentsButKeepStringLiterals() {
        let lines = Self.codeLines(of: """
        let a = "https://example.com" // removeItem(at: x)
        /* trashItem(at: y) */ let b = 1
        let c = "do shell script" /* nested /* z */ still a comment */ + d
        /// unlink(path)
        """)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("https://example.com"))
        XCTAssertFalse(lines[0].contains("removeItem"))
        XCTAssertFalse(lines[1].contains("trashItem"))
        XCTAssertTrue(lines[1].contains("let b = 1"))
        XCTAssertTrue(lines[2].contains("do shell script"), "a command inside a string is what the scan looks for")
        XCTAssertTrue(lines[2].contains("+ d"))
        XCTAssertFalse(lines[3].contains("unlink"))
    }

    /// `source` split into lines with `//` and nested `/* */` comments blanked
    /// out. String literals are kept: a shell command inside a string is
    /// exactly what the scan must find. Line numbers are preserved.
    static func codeLines(of source: String) -> [String] {
        let chars = Array(source)
        var lines: [String] = []
        var current = ""
        var blockDepth = 0
        var inString = false
        var inMultilineString = false
        var i = 0

        func isTripleQuote(at index: Int) -> Bool {
            index + 2 < chars.count && chars[index] == "\"" && chars[index + 1] == "\"" && chars[index + 2] == "\""
        }

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            if c == "\n" {
                lines.append(current)
                current = ""
                inString = false
                i += 1
                continue
            }
            if blockDepth > 0 {
                if c == "/" && next == "*" { blockDepth += 1; i += 2; continue }
                if c == "*" && next == "/" { blockDepth -= 1; i += 2; continue }
                i += 1
                continue
            }
            if inMultilineString {
                if isTripleQuote(at: i) { current += "\"\"\""; inMultilineString = false; i += 3; continue }
                if c == "\\", let next, next != "\n" { current.append(c); current.append(next); i += 2; continue }
                current.append(c)
                i += 1
                continue
            }
            if inString {
                if c == "\\", let next, next != "\n" { current.append(c); current.append(next); i += 2; continue }
                if c == "\"" { inString = false }
                current.append(c)
                i += 1
                continue
            }
            if c == "/" && next == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && next == "*" { blockDepth = 1; i += 2; continue }
            if isTripleQuote(at: i) { current += "\"\"\""; inMultilineString = true; i += 3; continue }
            if c == "\"" { inString = true }
            current.append(c)
            i += 1
        }
        lines.append(current)
        return lines
    }
}
