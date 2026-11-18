import Foundation

public struct CleanableItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let category: ScanCategory
    public let size: UInt64
    public let itemCount: Int

    /// Whether this specific item may be preselected for cleaning.
    ///
    /// The category alone is too coarse: `~/Library/Logs` is safe to clear by
    /// default, `/var/log` is not, and both land in `.logs`. Same for the temp
    /// category, where the per-user temp dir is routine and `/tmp` holds live
    /// sockets and lock files of running daemons.
    public let autoSelect: Bool
    /// Only fresh rows identify the object and parent authorized for cleanup.
    let removalIdentity: RemovalIdentity?

    /// Designated init — callers supply all fields. `autoSelect` defaults to the
    /// category's blanket policy so existing call sites keep their behaviour.
    public init(
        url: URL,
        category: ScanCategory,
        size: UInt64,
        itemCount: Int,
        autoSelect: Bool? = nil
    ) {
        self.init(url: url, category: category, size: size, itemCount: itemCount,
                  autoSelect: autoSelect, removalIdentity: RemovalIdentity(at: url))
    }

    init(
        url: URL,
        category: ScanCategory,
        size: UInt64,
        itemCount: Int,
        autoSelect: Bool?,
        removalIdentity: RemovalIdentity?
    ) {
        self.id = UUID()
        self.url = url
        self.category = category
        self.size = size
        self.itemCount = itemCount
        self.autoSelect = autoSelect ?? category.isSafeToAutoClean
        self.removalIdentity = removalIdentity
    }

    public var formattedSize: String {
        Fmt.bytes(Int64(size))
    }

    public var name: String {
        url.lastPathComponent
    }

    public var path: String {
        url.path
    }

    // Identity is a per-instance UUID, so compare by the meaningful fields
    // instead of the synthesized id (which would make two items describing
    // the same file unequal).
    public static func == (lhs: CleanableItem, rhs: CleanableItem) -> Bool {
        lhs.url == rhs.url &&
        lhs.category == rhs.category &&
        lhs.size == rhs.size &&
        lhs.itemCount == rhs.itemCount &&
        lhs.autoSelect == rhs.autoSelect
    }
}
