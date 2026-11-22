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

    init(date: Date, usedBytes: UInt64, categories: [Category]) {
        self.date = date
        self.usedBytes = usedBytes
        self.categories = categories
    }

    init(date: Date, usedBytes: UInt64, breakdown: [StorageBreakdown]) {
        self.init(date: date, usedBytes: usedBytes, categories: breakdown.map { row in
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
                                  partial: group.contains { $0.bytes == nil })
                }
            case .folder, .remainder:
                members = []
            }
            return Category(key: StorageCategory.from(rawName: row.name).rawValue, bytes: row.bytes,
                            partial: row.isResidual || row.isPartial || !row.sizeKnown, members: members)
        })
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

    init(from: StorageSnapshot, to: StorageSnapshot, cleanups: [CleanupRecord] = []) {
        usedDelta = Self.difference(from.usedBytes, to.usedBytes)
        let events = cleanups.filter { $0.date > from.date && $0.date <= to.date }
        freedBytes = events.map(\.freedBytes).reduce(0, StorageSnapshot.addBytes)
        trashedBytes = events.map(\.trashedBytes).reduce(0, StorageSnapshot.addBytes)
        let before = Dictionary(from.categories.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(to.categories.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var rows: [Change] = []
        for category in Set(before.keys).union(after.keys) {
            let old = before[category]
            let new = after[category]
            if let change = Self.change(category: category, member: nil, before: old?.bytes, after: new?.bytes,
                                        beforePartial: old?.partial == true, afterPartial: new?.partial == true) {
                rows.append(change)
            }
            let oldMembers = Dictionary((old?.members ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let newMembers = Dictionary((new?.members ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in Set(oldMembers.keys).union(newMembers.keys) {
                let left = oldMembers[id]
                let right = newMembers[id]
                if let change = Self.change(category: category, member: right ?? left,
                                            before: left?.bytes, after: right?.bytes,
                                            beforePartial: left?.partial ?? (old?.partial == true),
                                            afterPartial: right?.partial ?? (new?.partial == true)) {
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
        let presence: Change.Presence = before == nil ? .added : (after == nil ? .removed : .changed)
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
