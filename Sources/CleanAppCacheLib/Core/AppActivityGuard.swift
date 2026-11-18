import Foundation
import AppKit

/// Conservative preflight: a closed window is not evidence that an app or build stopped.
enum AppActivityGuard {
    static func cacheIsInUse(_ url: URL) -> Bool {
        !runningCacheOwners(for: url).isEmpty
    }

    static func runningCacheOwners(for url: URL) -> [NSRunningApplication] {
        let owners = cacheOwners(for: url)
        guard !owners.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated, let id = app.bundleIdentifier?.lowercased() else { return false }
            return owners.contains { owner in
                id == owner || id.hasPrefix(owner + ".") || owner.hasPrefix(id + ".")
            }
        }
    }

    /// Vendor folders contain unrelated applications; ownership follows the product.
    static func cacheOwners(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        let roots = [home.path + "/Library/Caches/", home.path + "/Library/Logs/"]
        let path = url.standardizedFileURL.path
        guard let root = roots.first(where: { path.hasPrefix($0) }) else { return [] }
        let parts = path.dropFirst(root.count).split(separator: "/").map { $0.lowercased() }
        guard let entry = parts.first else { return [] }
        if entry == "google" {
            guard parts.count > 1 else { return ["com.google"] }
            if parts[1].hasPrefix("androidstudio") { return ["com.google.android.studio"] }
            switch parts[1] {
            case "chrome": return ["com.google.chrome"]
            case "chrome beta": return ["com.google.chrome.beta"]
            case "chrome canary": return ["com.google.chrome.canary"]
            case "chrome dev": return ["com.google.chrome.dev"]
            default: return ["com.google"]
            }
        }
        let aliases: [String: String] = ["firefox": "org.mozilla.firefox",
            "microsoft edge": "com.microsoft.edgemac", "bravesoftware": "com.brave.browser",
            "arc": "company.thebrowser.browser", "vivaldi": "com.vivaldi.vivaldi"]
        return [aliases[entry] ?? entry]
    }

    /// Native uv cleanup owns its cache lock; this preflight also catches a
    /// running uv/uvx command, including caches configured outside the home.
    /// Unknown process state is busy, never permission for a destructive call.
    static func uvIsInUse() -> Bool {
        processIsRunning(["uv", "uvx"]) != false
    }

    static func developerIsInUse(_ url: URL) -> Bool {
        let names = developerProcesses(for: url)
        guard !names.isEmpty else { return false }
        if Scanner.touchedRecently(url, within: 3600) { return true }
        return processIsRunning(names) != false
    }

    static func developerProcesses(for url: URL) -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = url.standardizedFileURL.path
        let relative = path.hasPrefix(home.path + "/") ? String(path.dropFirst(home.path.count + 1)) : ""
        if relative.hasPrefix("Library/Developer/") { return ["Xcode", "xcodebuild", "Simulator", "swift", "swift-frontend", "clang"] }
        if relative == ".m2/repository" || relative.hasPrefix(".gradle/") { return ["java", "gradle", "mvn"] }
        if relative == ".npm" || relative == "Library/Caches/Yarn" { return ["node", "npm", "yarn"] }
        if relative == "Library/Caches/pip" { return ["pip", "pip3", "python", "python3"] }
        if relative == "Library/Caches/org.swift.swiftpm" { return ["swift", "swiftc", "swift-frontend", "Xcode"] }
        if relative == "Library/Caches/CocoaPods" { return ["pod", "ruby", "xcodebuild"] }
        if relative == "Library/Caches/org.carthage.CarthageKit" { return ["carthage", "xcodebuild"] }
        if relative == "Library/Caches/Homebrew" { return ["brew", "ruby"] }
        if relative == ".android/cache" { return ["java", "adb", "emulator"] }
        if relative == ".sdkman/archives" { return ["sdk", "java", "unzip", "curl"] }
        if relative == "Library/Caches/go-build" || relative == "go/pkg/mod" { return ["go", "gopls"] }
        if relative.hasPrefix(".cargo/") { return ["cargo", "rustc"] }
        if relative == ".pub-cache" { return ["dart", "flutter"] }
        if relative.hasPrefix("Library/Containers/com.docker.docker/") { return ["Docker", "com.docker.backend", "dockerd"] }
        if relative.hasPrefix(".orbstack/") { return ["OrbStack", "orb", "orbstack"] }
        switch url.lastPathComponent {
        case "node_modules": return ["node", "npm", "yarn", "pnpm"]
        case ".build": return ["swift", "swiftc", "swift-frontend", "clang", "Xcode"]
        case "target": return ["cargo", "rustc"]
        default: return []
        }
    }

    /// nil means process enumeration failed; a destructive caller treats that as busy.
    private static func processIsRunning(_ names: Set<String>) -> Bool? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // Kernel short names can truncate long helper names such as Docker's.
        // Match executable basenames in full command lines, never a bare substring.
        task.arguments = ["-f", processPattern(names)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
        task.waitUntilExit()
        watchdog.cancel()
        switch task.terminationStatus {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    static func processPattern(_ names: Set<String>) -> String {
        let names = names.sorted().map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        return "(^|/)(\(names))([[:space:]]|$)"
    }
}
