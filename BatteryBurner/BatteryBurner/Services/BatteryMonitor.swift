import Foundation
import IOKit.ps
import Combine

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published var percentage: Int = 0
    @Published var isPluggedIn: Bool = false
    @Published var isCharging: Bool = false

    private var timer: Timer?

    init() {
        update()
    }

    func startMonitoring() {
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.update()
            }
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func update() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
              let source = sources.first,
              let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            return
        }

        if let capacity = desc[kIOPSCurrentCapacityKey] as? Int {
            percentage = capacity
        }
        if let powerSource = desc[kIOPSPowerSourceStateKey] as? String {
            isPluggedIn = (powerSource == kIOPSACPowerValue)
        }
        if let charging = desc[kIOPSIsChargingKey] as? Bool {
            isCharging = charging
        }
    }
}
