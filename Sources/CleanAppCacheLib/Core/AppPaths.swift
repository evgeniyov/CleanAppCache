import Foundation

/// Persistent app state is isolated from the signed app when XCTest hosts the library.
enum AppPaths {
    static let isTesting = NSClassFromString("XCTestCase") != nil
    static let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("CleanAppCacheTests-\(UUID().uuidString)", isDirectory: true)
    private static var directoryName: String {
        Bundle.main.bundleIdentifier == "com.cleanappcache.CleanAppCache.Audit"
            ? "CleanAppCache-Audit" : "CleanAppCache"
    }

    static var support: URL {
        if isTesting { return testRoot.appendingPathComponent("Support", isDirectory: true) }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    static var logs: URL? {
        if isTesting { return testRoot.appendingPathComponent("Logs/CleanAppCache", isDirectory: true) }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/" + directoryName, isDirectory: true)
    }
}
