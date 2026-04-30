import Foundation

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let cycleCount: Int
    let fullChargeCapacityMAh: Int
    let healthPercent: Int

    init(timestamp: Date, cycleCount: Int, fullChargeCapacityMAh: Int, healthPercent: Int) {
        self.id = UUID()
        self.timestamp = timestamp
        self.cycleCount = cycleCount
        self.fullChargeCapacityMAh = fullChargeCapacityMAh
        self.healthPercent = healthPercent
    }
}

@MainActor
final class HistoryRecorder: ObservableObject {
    @Published var entries: [HistoryEntry] = []

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BurnCycle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private var lastRecordedCycleCount: Int = -1
    private var lastDailySnapshot: Date = .distantPast

    init() {
        load()
    }

    /// Called periodically from BatteryMonitor updates.
    /// Records a snapshot when:
    ///  - Cycle count changes (every new cycle)
    ///  - First entry of the day (daily snapshot)
    func observe(cycleCount: Int, fullChargeCapacityMAh: Int, healthPercent: Int) {
        guard cycleCount > 0, fullChargeCapacityMAh > 0, healthPercent > 0 else { return }

        let now = Date()
        let cal = Calendar.current
        let cycleChanged = cycleCount != lastRecordedCycleCount && lastRecordedCycleCount >= 0
        let isNewDay = !cal.isDate(now, inSameDayAs: lastDailySnapshot)
        let isFirstEver = lastRecordedCycleCount < 0 && entries.isEmpty

        if cycleChanged || isNewDay || isFirstEver {
            let entry = HistoryEntry(timestamp: now, cycleCount: cycleCount,
                                     fullChargeCapacityMAh: fullChargeCapacityMAh,
                                     healthPercent: healthPercent)
            entries.append(entry)
            save()
            lastDailySnapshot = now
        }

        lastRecordedCycleCount = cycleCount
    }

    func clearAll() {
        entries.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([HistoryEntry].self, from: data) {
            entries = decoded
            lastRecordedCycleCount = decoded.last?.cycleCount ?? -1
            lastDailySnapshot = decoded.last?.timestamp ?? .distantPast
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: fileURL)
        }
    }
}
