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

/// Persists battery-health snapshots to `~/Library/Application Support/BurnCycle/history.json`.
/// One entry is recorded on the first valid observation and again whenever the
/// hardware cycle count advances, so the file grows by ~one row per real charge
/// cycle (capped at `maxEntries`). Used by the History panel to chart capacity
/// fade over time.
@MainActor
final class HistoryRecorder: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    /// Set when an encode/write fails so the UI can warn that history isn't being
    /// persisted. Cleared on a successful save.
    @Published var lastError: String?

    /// Cap on stored entries — this app cycles continuously so without a bound the
    /// array (and on-disk file) would grow forever. Keep the most recent N.
    private let maxEntries = 1000

    private let fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("history.json")

    private var lastRecordedCycleCount: Int = -1

    init() {
        load()
    }

    /// Called whenever battery slow values change.
    /// Records a snapshot when:
    ///  - First valid observation ever (no entries yet)
    ///  - Cycle count differs from the last recorded entry
    func observe(cycleCount: Int, fullChargeCapacityMAh: Int, healthPercent: Int) {
        guard cycleCount > 0, fullChargeCapacityMAh > 0, healthPercent > 0 else { return }

        let isFirstEver = entries.isEmpty
        let cycleChanged = cycleCount != lastRecordedCycleCount && lastRecordedCycleCount >= 0

        if isFirstEver || cycleChanged {
            let entry = HistoryEntry(timestamp: Date(), cycleCount: cycleCount,
                                     fullChargeCapacityMAh: fullChargeCapacityMAh,
                                     healthPercent: healthPercent)
            entries.append(entry)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            save()
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
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        do {
            let data = try encoder.encode(entries)
            try data.write(to: fileURL)
            lastError = nil
        } catch {
            lastError = "Couldn't save history: \(error.localizedDescription)"
        }
    }
}
