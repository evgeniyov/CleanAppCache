import Foundation

struct StorageSnapshot: Codable, Equatable, Sendable {
    struct Category: Codable, Equatable, Sendable {
        let key: String
        let bytes: UInt64
        let partial: Bool
        var members: [Member] = []
    }

    struct Member: Codable, Equatable, Sendable {
        let id: String
        let name: String
        let bytes: UInt64
        let partial: Bool
        var folderPath: String? = nil
    }

    let date: Date
    let usedBytes: UInt64
    let categories: [Category]
    let enumerationFailed: Bool?
    /// Paths that could not be read during the measurement. du counts a hard
    /// link under the first path it can reach, so a change in this set can move
    /// allocation between folders whose files did not change.
    let unreadablePaths: [String]?

    init(date: Date, usedBytes: UInt64, categories: [Category], enumerationFailed: Bool? = nil,
         unreadablePaths: [String]? = nil) {
        self.date = date
        self.usedBytes = usedBytes
        self.categories = categories
        self.enumerationFailed = enumerationFailed
        self.unreadablePaths = unreadablePaths
    }

    private enum CodingKeys: String, CodingKey {
        case date, usedBytes, categories, enumerationFailed, unreadablePaths
        // Written by builds that recorded only the ~/Library failure.
        case libraryEnumerationFailed
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = try values.decode(Date.self, forKey: .date)
        usedBytes = try values.decode(UInt64.self, forKey: .usedBytes)
        categories = try values.decode([Category].self, forKey: .categories)
        enumerationFailed = try values.decodeIfPresent(Bool.self, forKey: .enumerationFailed)
            ?? values.decodeIfPresent(Bool.self, forKey: .libraryEnumerationFailed)
        unreadablePaths = try values.decodeIfPresent([String].self, forKey: .unreadablePaths)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(date, forKey: .date)
        try values.encode(usedBytes, forKey: .usedBytes)
        try values.encode(categories, forKey: .categories)
        try values.encodeIfPresent(enumerationFailed, forKey: .enumerationFailed)
        try values.encodeIfPresent(unreadablePaths, forKey: .unreadablePaths)
    }

    init(date: Date, usedBytes: UInt64, breakdown: [StorageBreakdown]) {
        let enumerationFailed = breakdown.contains { row in
            row.accessIssues.contains { $0.enumerationFailed == true }
        }
        let categories = breakdown.map { row in
            let members: [Member]
            switch row.contents {
            case let .group(items):
                members = items.map {
                    Member(id: $0.path, name: $0.name, bytes: $0.size,
                           partial: $0.isPartial || !$0.sizeKnown, folderPath: $0.isDirectory ? $0.path : nil)
                }
            case let .volumes(volumes):
                // Device identifiers can change across boots. Compare allocation by APFS role.
                let byRole = Dictionary(grouping: volumes) { volume in
                    volume.roles.isEmpty ? "volume:" + (volume.uuid ?? volume.name) : volume.roles.sorted().joined(separator: ",")
                }
                members = byRole.keys.sorted().compactMap { key in
                    guard let group = byRole[key], let first = group.first else { return nil }
                    let bytes = group.compactMap(\.bytes).reduce(0, Self.addBytes)
                    let name = group.count == 1 && !first.name.isEmpty ? first.name : key
                    return Member(id: key, name: name, bytes: bytes,
                                  partial: row.isPartial || group.contains { $0.bytes == nil })
                }
            case .folder, .remainder:
                members = []
            }
            return Category(key: StorageCategory.from(rawName: row.name).rawValue, bytes: row.bytes,
                            partial: row.isResidual || row.isPartial || !row.sizeKnown, members: members)
        }
        let unreadable = Set(breakdown.flatMap { $0.accessIssues.map(\.path) })
        self.init(date: date, usedBytes: usedBytes, categories: categories,
                  enumerationFailed: enumerationFailed ? true : nil,
                  unreadablePaths: unreadable.isEmpty ? nil : unreadable.sorted())
    }

    /// The unreadable paths, or nil when a snapshot that predates the list was
    /// partial and so its set is unknown.
    var knownUnreadable: Set<String>? {
        if let unreadablePaths { return Set(unreadablePaths) }
        return categories.contains { $0.partial && $0.key != StorageCategory.other.rawValue } ? nil : []
    }

    static func addBytes(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

actor StorageSnapshotStore {
    static let shared = StorageSnapshotStore(directory: AppPaths.support)
    private let file: URL
    private let calendar: Calendar
    private var snapshots: [StorageSnapshot]?

    init(directory: URL, calendar: Calendar = .current) {
        file = directory.appendingPathComponent("storage-snapshots.json")
        self.calendar = calendar
    }

    func history(now: Date = Date()) -> [StorageSnapshot] {
        if snapshots == nil {
            do {
                snapshots = try JSONDecoder().decode([StorageSnapshot].self, from: Data(contentsOf: file))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                snapshots = []
            } catch {
                Log.warn("StorageSnapshotStore: cannot load \(file.path): \(error)")
                snapshots = []
            }
        }
        return retained(snapshots ?? [], now: now)
    }

    func record(_ snapshot: StorageSnapshot, now: Date = Date()) {
        guard !Task.isCancelled else { return }
        let updated = retained(history(now: now) + [snapshot], now: now)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: file, options: .atomic)
            snapshots = updated
        } catch {
            Log.error("StorageSnapshotStore: cannot save \(file.path): \(error)")
        }
    }

    private func retained(_ values: [StorageSnapshot], now: Date) -> [StorageSnapshot] {
        let today = calendar.startOfDay(for: now)
        let cutoff = calendar.date(byAdding: .day, value: -89, to: today) ?? today
        var byDay: [Date: StorageSnapshot] = [:]
        for snapshot in values where snapshot.date >= cutoff {
            let day = calendar.startOfDay(for: snapshot.date)
            if let existing = byDay[day], existing.date > snapshot.date { continue }
            byDay[day] = snapshot
        }
        return byDay.values.sorted { $0.date < $1.date }
    }
}

enum StorageSnapshotPeriod: Int, CaseIterable {
    case previous = 0, week = 7, month = 30

    struct Selection {
        let from: StorageSnapshot
        let to: StorageSnapshot
        let shortHistory: Bool
    }

    func select(_ snapshots: [StorageSnapshot], calendar: Calendar = .current) -> Selection? {
        let ordered = snapshots.sorted { $0.date < $1.date }
        guard let latest = ordered.last, let oldest = ordered.first, ordered.count >= 2 else { return nil }
        let earlier = ordered.dropLast()
        if self == .previous, let previous = earlier.last {
            return Selection(from: previous, to: latest, shortHistory: false)
        }
        let start = calendar.date(byAdding: .day, value: -rawValue, to: latest.date) ?? latest.date
        let baseline = earlier.last { $0.date <= start }
        return Selection(from: baseline ?? oldest, to: latest, shortHistory: baseline == nil)
    }
}

struct StorageSnapshotComparison {
    struct Change: Identifiable {
        enum Presence { case changed, added, removed }
        let category: String
        let member: StorageSnapshot.Member?
        let presence: Presence
        let uncertain: Bool
        let currentPartial: Bool
        let delta: Int64
        let currentBytes: UInt64

        var id: [String] { [category] + (member.map { [$0.id] } ?? []) }
        var folderPath: String? { presence == .removed ? nil : member?.folderPath }
    }

    let usedDelta: Int64
    let freedBytes: UInt64
    let trashedBytes: UInt64
    let changes: [Change]

    /// Rows come from what could be enumerated at the time, so a row present on
    /// one side only can mean that access changed rather than that data moved:
    /// a denied folder collapses into one fallback row and splits again once it
    /// is readable. Categories that appear or disappear are therefore never
    /// reported, and a member counts as removed only when its folder is gone now.
    init(from: StorageSnapshot, to: StorageSnapshot, cleanups: [CleanupRecord] = [],
         pathExists: (String) -> Bool = { path in
             // Unreadable is not missing: only ENOENT proves the folder is gone.
             var info = stat()
             return lstat(path, &info) == 0 || errno != ENOENT
         }) {
        usedDelta = Self.difference(from.usedBytes, to.usedBytes)
        let events = cleanups.filter { $0.date > from.date && $0.date <= to.date }
        freedBytes = events.map(\.freedBytes).reduce(0, StorageSnapshot.addBytes)
        trashedBytes = events.map(\.trashedBytes).reduce(0, StorageSnapshot.addBytes)
        let before = Dictionary(from.categories.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(to.categories.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        // A folder that could not be listed moves its contents into a fallback
        // row, so either side's row layout is unreliable and no difference
        // between the two can be stated exactly.
        let incomplete = from.enumerationFailed == true || to.enumerationFailed == true
            || from.knownUnreadable == nil || to.knownUnreadable == nil
            || from.knownUnreadable != to.knownUnreadable
        var rows: [Change] = []
        for category in Set(before.keys).union(after.keys) {
            let old = before[category]
            let new = after[category]
            let oldPartial = (old?.partial ?? false) || incomplete
            let newPartial = (new?.partial ?? false) || incomplete
            if old != nil, new != nil,
               let change = Self.change(category: category, member: nil, before: old?.bytes, after: new?.bytes,
                                        beforePartial: oldPartial, afterPartial: newPartial) {
                rows.append(change)
            }
            // A role in a saved partial group can have its own allocation and still be incomplete.
            let isVolumeGroup = category == StorageCategory.serviceVolumes.rawValue
            let oldMembers = Dictionary((old?.members ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newMembers = Dictionary((new?.members ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in Set(oldMembers.keys).union(newMembers.keys) {
                let left = oldMembers[id]
                let right = newMembers[id]
                if right == nil {
                    // Only a folder that no longer exists was removed; anything
                    // else is a change in how the branch could be read.
                    guard !incomplete, let path = left?.folderPath, !pathExists(path) else { continue }
                } else if left == nil {
                    // A member is new only against a side that listed its group completely.
                    guard old != nil, !oldPartial else { continue }
                }
                if let change = Self.change(category: category, member: right ?? left,
                                            before: left?.bytes, after: right?.bytes,
                                            beforePartial: (left?.partial ?? oldPartial) || incomplete || (isVolumeGroup && oldPartial),
                                            afterPartial: (right?.partial ?? newPartial) || incomplete || (isVolumeGroup && newPartial)) {
                    rows.append(change)
                }
            }
        }
        changes = rows.sorted {
            if $0.uncertain != $1.uncertain { return !$0.uncertain }
            if !$0.uncertain && $0.delta.magnitude != $1.delta.magnitude {
                return $0.delta.magnitude > $1.delta.magnitude
            }
            return $0.id.lexicographicallyPrecedes($1.id)
        }
    }

    private static func change(category: String, member: StorageSnapshot.Member?,
                               before: UInt64?, after: UInt64?, beforePartial: Bool, afterPartial: Bool) -> Change? {
        let delta = difference(before ?? 0, after ?? 0)
        let presence: Change.Presence
        if before == nil && !beforePartial {
            presence = .added
        } else if after == nil && !afterPartial {
            presence = .removed
        } else {
            presence = .changed
        }
        let uncertain = beforePartial || afterPartial
        let threshold = max(100_000_000, (before ?? 0) / 100)
        guard uncertain || presence != .changed || delta.magnitude >= threshold else { return nil }
        return Change(category: category, member: member, presence: presence, uncertain: uncertain,
                      currentPartial: afterPartial, delta: delta, currentBytes: after ?? 0)
    }

    private static func difference(_ before: UInt64, _ after: UInt64) -> Int64 {
        after >= before ? Int64(clamping: after - before) : -Int64(clamping: before - after)
    }
}

extension Notification.Name {
    static let storageSnapshotsChanged = Notification.Name("storageSnapshotsChanged")
}
