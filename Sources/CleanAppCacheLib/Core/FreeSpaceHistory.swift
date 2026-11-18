import Foundation

@MainActor
final class FreeSpaceHistory: ObservableObject {
    struct Sample: Codable, Identifiable {
        let date: Date
        let bytes: UInt64
        var id: Date { date }
    }

    static let shared = FreeSpaceHistory()
    @Published private(set) var samples: [Sample]
    private let defaults: UserDefaults
    private let key = "storage.freeSpaceHistory"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        samples = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([Sample].self, from: $0) } ?? []
    }

    func capture() async {
        let info = await Task.detached(priority: .utility) { StorageInfo.read() }.value
        guard !Task.isCancelled, let info else { return }
        record(bytes: info.freeBytes, at: Date())
    }

    func record(bytes: UInt64, at date: Date) {
        let cutoff = date.addingTimeInterval(-31 * 86_400)
        let hour = floor(date.timeIntervalSinceReferenceDate / 3600)
        samples = samples.filter {
            $0.date >= cutoff && floor($0.date.timeIntervalSinceReferenceDate / 3600) != hour
        } + [Sample(date: date, bytes: bytes)]
        if let data = try? JSONEncoder().encode(samples) {
            defaults.set(data, forKey: key)
        }
    }
}
