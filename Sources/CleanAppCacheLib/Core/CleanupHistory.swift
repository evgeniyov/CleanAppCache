import Foundation

/// One completed cleanup operation: when it happened, which section did it,
/// how many items were removed, how much space was freed and how much only
/// moved to the Trash.
public struct CleanupRecord: Identifiable, Codable, Sendable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        case smartCleanup, systemJunk, largeFiles, duplicates, developer
        case uninstaller, leftovers, trash, orphans

        /// Localization key for the section name.
        public var labelKey: String { "history.source.\(rawValue)" }

        /// SF Symbol for the section.
        public var icon: String {
            switch self {
            case .smartCleanup: return "sparkles"
            case .systemJunk: return "trash.square"
            case .largeFiles: return "doc.text.magnifyingglass"
            case .duplicates: return "doc.on.doc"
            case .developer: return "chevron.left.forwardslash.chevron.right"
            case .uninstaller: return "trash.slash"
            case .leftovers: return "questionmark.folder"
            case .trash: return "trash"
            case .orphans: return "link.badge.plus"
            }
        }
    }

    public let id: UUID
    public let date: Date
    public let source: Source
    public let itemCount: Int
    /// Bytes deleted for good: space the disk actually got back.
    public let freedBytes: UInt64
    /// Bytes moved to the Trash. They occupy the disk until the Trash is
    /// emptied, and emptying it through Smart Cleanup is logged as freed then,
    /// so counting them as freed here would count the same bytes twice.
    public let trashedBytes: UInt64
    public let report: Report?

    /// The outcome at the end of the operation. The journal's running totals
    /// can change later if the user puts items back from the Trash.
    public struct Report: Codable, Sendable {
        public struct Category: Identifiable, Codable, Sendable {
            public let category: ScanCategory
            public let selected: Int
            public let removed: Int
            public let bytes: UInt64
            public var id: ScanCategory { category }
        }

        public let categories: [Category]
        public let skipped: [ScanSkipReason: Int]
        public let failed: [RemovalObstacle: Int]
        public let alreadyGone: Int
        public let notAttempted: Int
    }

    public init(date: Date = Date(), source: Source, itemCount: Int,
                freedBytes: UInt64, trashedBytes: UInt64 = 0, report: Report? = nil) {
        self.id = UUID()
        self.date = date
        self.source = source
        self.itemCount = itemCount
        self.freedBytes = freedBytes
        self.trashedBytes = trashedBytes
        self.report = report
    }

    /// The same record with its Trash moves taken back — what an Undo leaves.
    func restoringTrashBytes(_ bytes: UInt64) -> CleanupRecord {
        CleanupRecord(id: id, date: date, source: source, itemCount: itemCount,
                      freedBytes: freedBytes, trashedBytes: trashedBytes - min(bytes, trashedBytes), report: report)
    }

    private init(id: UUID, date: Date, source: Source, itemCount: Int,
                 freedBytes: UInt64, trashedBytes: UInt64, report: Report?) {
        self.id = id
        self.date = date
        self.source = source
        self.itemCount = itemCount
        self.freedBytes = freedBytes
        self.trashedBytes = trashedBytes
        self.report = report
    }

    /// Records written before `trashedBytes` existed decode with zero. Their
    /// `freedBytes` may include moves to the Trash; the file does not say.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        source = try container.decode(Source.self, forKey: .source)
        itemCount = try container.decode(Int.self, forKey: .itemCount)
        freedBytes = try container.decode(UInt64.self, forKey: .freedBytes)
        trashedBytes = try container.decodeIfPresent(UInt64.self, forKey: .trashedBytes) ?? 0
        report = try? container.decodeIfPresent(Report.self, forKey: .report)
    }

    public var formattedFreed: String {
        Fmt.bytes(Int64(freedBytes))
    }
}

/// Persistent journal of cleanups. Every section logs here after a successful
/// delete, and the Smart Cleanup screen shows the running total.
@MainActor
public final class CleanupHistory: ObservableObject {
    public static let shared = CleanupHistory()

    @Published public private(set) var records: [CleanupRecord] = []

    private static let maxRecords = 300

    private let fileURL: URL

    /// False when an existing history file could be neither read nor moved
    /// aside; saving would then overwrite the only copy of those records.
    private var canSave = true

    private convenience init() {
        self.init(directory: AppPaths.support)
    }

    /// Stores the journal as `cleanup-history.json` inside `directory`.
    init(directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("cleanup-history.json")
        load()
    }

    // MARK: - Derived stats

    /// Space deleted for good. Moves to the Trash are not part of it.
    public var totalFreedBytes: UInt64 { records.reduce(0) { $0 &+ $1.freedBytes } }

    public var formattedTotalFreed: String {
        Fmt.bytes(Int64(totalFreedBytes))
    }

    /// Bytes ever moved to the Trash by the app, whether or not the Trash has
    /// been emptied since.
    public var totalTrashedBytes: UInt64 { records.reduce(0) { $0 &+ $1.trashedBytes } }

    public var lastCleanupDate: Date? { records.first?.date }

    // MARK: - Mutations

    /// Records a finished cleanup: `freedBytes` for what was deleted for good,
    /// `trashedBytes` for what went to the Trash. No-ops when nothing was
    /// actually removed. Returns the record's id for Undo.
    @discardableResult
    public func log(_ source: CleanupRecord.Source, items: Int,
                    freedBytes: UInt64 = 0, trashedBytes: UInt64 = 0,
                    report: CleanupRecord.Report? = nil) -> UUID? {
        guard items > 0 || freedBytes > 0 || trashedBytes > 0 else { return nil }
        let record = CleanupRecord(source: source, itemCount: items,
                                   freedBytes: freedBytes, trashedBytes: trashedBytes, report: report)
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records.removeLast(records.count - Self.maxRecords)
        }
        save()
        return record.id
    }

    /// Takes back only the bytes actually restored. A mixed operation retains
    /// its permanent deletions and any Trash moves Undo could not restore.
    public func undoTrashMoves(_ id: UUID?, restoredBytes: UInt64? = nil) {
        guard let id, let index = records.firstIndex(where: { $0.id == id }) else { return }
        let updated = records[index].restoringTrashBytes(restoredBytes ?? records[index].trashedBytes)
        if updated.freedBytes == 0, updated.trashedBytes == 0 {
            records.remove(at: index)
        } else {
            records[index] = updated
        }
        save()
    }

    public func clear() {
        records = []
        save()
    }

    // MARK: - Persistence

    /// Where an undecodable history file is kept instead of being overwritten.
    var corruptFileURL: URL { fileURL.appendingPathExtension("corrupt") }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Log.error("CleanupHistory: cannot read \(fileURL.path): \(error)")
            canSave = false
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            // Record by record: one entry this version cannot read (a source
            // added by a newer version, say) costs that entry, not the file.
            let entries = try decoder.decode([Lossy].self, from: data)
            records = entries.compactMap(\.record)
            if records.count < entries.count {
                Log.warn("CleanupHistory: skipped \(entries.count - records.count) unreadable record(s)")
            }
        } catch {
            Log.error("CleanupHistory: cannot decode \(fileURL.path): \(error)")
            preserveCorruptFile()
        }
    }

    /// One array element, decoded if it can be.
    private struct Lossy: Decodable {
        let record: CleanupRecord?
        init(from decoder: Decoder) throws {
            record = try? CleanupRecord(from: decoder)
        }
    }

    /// Moves the unreadable file to `corruptFileURL`, replacing an older copy,
    /// so the history starts empty without destroying the original bytes.
    private func preserveCorruptFile() {
        let fm = FileManager.default
        let target = corruptFileURL
        do {
            if fm.fileExists(atPath: target.path) {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: fileURL, to: target)
            Log.error("CleanupHistory: kept the unreadable history as \(target.path)")
        } catch {
            Log.error("CleanupHistory: cannot move \(fileURL.path) aside: \(error); history will not be saved")
            canSave = false
        }
    }

    private func save() {
        guard canSave else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("CleanupHistory: cannot save \(fileURL.path): \(error)")
        }
    }
}
