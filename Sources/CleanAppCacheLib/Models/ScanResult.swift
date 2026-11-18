import Foundation

/// Skipped paths never become selectable items or contribute cleanable bytes.
public enum ScanSkipReason: String, Codable, CaseIterable, Sendable {
    case inUse, recent, safetyProtected, systemProtected, unreadable, verificationLimit, symbolicLink, ownLogs, managedCache, userExcluded

    var titleKey: String { "scan.skipped.\(rawValue)" }
}

public struct ScanSkippedItem: Codable, Sendable {
    public let path: String
    public let category: ScanCategory?
    public let reason: ScanSkipReason
}

public struct ScanSkipSummary: Codable, Sendable {
    public static let detailLimit = 200
    public private(set) var paths: [ScanSkippedItem] = []
    public private(set) var counts: [ScanSkipReason: Int] = [:]
    /// Older cached results did not record why paths were excluded.
    public var explanationsAvailable = true
    public var totalCount: Int { counts.values.reduce(0, +) }
    public var omittedCount: Int { max(0, totalCount - paths.count) }
    public var needsNotice: Bool { totalCount > 0 || !explanationsAvailable }

    public init() {}

    mutating func record(_ url: URL, category: ScanCategory? = nil, reason: ScanSkipReason) {
        counts[reason, default: 0] += 1
        if paths.count < Self.detailLimit {
            paths.append(ScanSkippedItem(path: url.path, category: category, reason: reason))
        }
    }

    mutating func merge(_ other: Self) {
        for (reason, count) in other.counts { counts[reason, default: 0] += count }
        paths.append(contentsOf: other.paths.prefix(max(0, Self.detailLimit - paths.count)))
        explanationsAvailable = explanationsAvailable && other.explanationsAvailable
    }

    /// Keep aggregate reasons but do not persist names from Trash or Downloads.
    func withoutPrivatePaths() -> Self {
        var copy = self
        copy.paths.removeAll { $0.category == .trash || $0.category == .installers }
        return copy
    }
}

public struct ScanResult: Sendable {
    public let items: [CleanableItem]
    public let totalSize: UInt64
    public let duration: TimeInterval
    public let categorySizes: [ScanCategory: UInt64]
    public let skipped: ScanSkipSummary

    public init(items: [CleanableItem], totalSize: UInt64, duration: TimeInterval,
                categorySizes: [ScanCategory: UInt64], skipped: ScanSkipSummary = ScanSkipSummary()) {
        self.items = items
        self.totalSize = totalSize
        self.duration = duration
        self.categorySizes = categorySizes
        self.skipped = skipped
    }

    public var formattedTotalSize: String {
        Fmt.bytes(Int64(totalSize))
    }

    public func items(for category: ScanCategory) -> [CleanableItem] {
        items.filter { $0.category == category }
    }

    public func size(for category: ScanCategory) -> UInt64 {
        categorySizes[category] ?? 0
    }
}

public struct ScanProgress: Sendable {
    public let currentCategory: ScanCategory
    public let categoriesDone: Int
    public let totalCategories: Int
    public let currentPath: String
    public let partialSize: UInt64

    public var percent: Double {
        Double(categoriesDone) / Double(totalCategories)
    }
}

// MARK: - Persistence helpers (used by DashboardViewModel for cross-launch caching)

extension ScanResult {
    /// Flat, Codable representation used for JSON persistence.
    struct Cached: Codable {
        let items: [CleanableItem.Cached]
        let totalSize: UInt64
        let duration: TimeInterval
        let categorySizes: [String: UInt64]
        let skipped: ScanSkipSummary?
        let savedAt: Date

        init(from result: ScanResult) {
            items = result.items.map { CleanableItem.Cached(from: $0) }
            totalSize = result.totalSize
            duration = result.duration
            categorySizes = Dictionary(uniqueKeysWithValues:
                result.categorySizes.map { ($0.key.rawValue, $0.value) }
            )
            skipped = result.skipped.withoutPrivatePaths()
            savedAt = Date()
        }

        func toScanResult() -> ScanResult {
            // A legacy whole-Google entry mixes Chrome and IDE caches. It must
            // never be offered for cleaning again, even from an older cache.
            let google = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/Google").path
            let parsedItems = items.map { $0.toCleanableItem() }.filter {
                $0.url.standardizedFileURL.path != google
            }
            var parsedCategorySizes: [ScanCategory: UInt64] = [:]
            for item in parsedItems { parsedCategorySizes[item.category, default: 0] += item.size }
            var summary = skipped ?? ScanSkipSummary()
            if skipped == nil || parsedItems.count != items.count { summary.explanationsAvailable = false }
            return ScanResult(
                items: parsedItems,
                totalSize: parsedItems.reduce(0) { $0 + $1.size },
                duration: duration,
                categorySizes: parsedCategorySizes,
                skipped: summary
            )
        }
    }
}

extension CleanableItem {
    struct Cached: Codable {
        let urlPath: String
        let category: String
        let size: UInt64
        let itemCount: Int
        /// Optional so a cache written by an earlier build still decodes; a
        /// missing value falls back to the category's blanket policy.
        let autoSelect: Bool?

        init(from item: CleanableItem) {
            urlPath = item.url.path
            category = item.category.rawValue
            size = item.size
            itemCount = item.itemCount
            autoSelect = item.autoSelect
        }

        func toCleanableItem() -> CleanableItem {
            let url = URL(fileURLWithPath: urlPath)
            let cat = ScanCategory(rawValue: category) ?? .userCache
            return CleanableItem(
                url: url, category: cat, size: size,
                itemCount: itemCount, autoSelect: autoSelect, removalIdentity: nil
            )
        }
    }
}
