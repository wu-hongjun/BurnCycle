import Foundation

enum CycleState: String {
    case charging = "CHARGING"
    case draining = "DRAINING"
    case paused = "PAUSED"
    case idle = "IDLE"
}

@MainActor
final class CycleEngine: ObservableObject {
    @Published var state: CycleState = .idle
    @Published var cycleCount: Int = 0
    @Published var isRunning: Bool = false

    private let battery: BatteryMonitor
    private let charging: ChargingController
    private let mining: MiningManager
    private let settings: AppSettings

    private var timer: Timer?

    init(battery: BatteryMonitor, charging: ChargingController, mining: MiningManager, settings: AppSettings) {
        self.battery = battery
        self.charging = charging
        self.mining = mining
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        battery.startMonitoring()
        battery.update()

        // Determine initial state based on battery level
        // Always fire the shortcut to ensure outlet matches desired state
        let pct = battery.percentage
        let upper = Int(settings.upperThreshold)
        let lower = Int(settings.lowerThreshold)

        if pct >= upper {
            // At or above upper threshold — start draining
            transitionToDraining()
        } else if pct <= lower {
            // At or below lower threshold — start charging
            transitionToCharging()
        } else {
            // Between thresholds — charge up to upper first
            // Always ensure outlet is ON when we start in charging mode
            transitionToCharging()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        mining.stop()
        battery.stopMonitoring()
        state = .idle
    }

    func pause() {
        guard isRunning else { return }
        mining.stop()
        charging.startCharging(shortcutName: settings.startChargingShortcut)
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        let pct = battery.percentage
        if pct >= Int(settings.upperThreshold) {
            transitionToDraining()
        } else {
            transitionToCharging()
        }
    }

    private func tick() {
        guard isRunning, state != .paused else { return }
        battery.update()

        let pct = battery.percentage
        switch state {
        case .charging:
            if pct >= Int(settings.upperThreshold) {
                transitionToDraining()
            }
        case .draining:
            if pct <= Int(settings.lowerThreshold) {
                cycleCount += 1
                transitionToCharging()
            }
        default:
            break
        }
    }

    /// Turn outlet ON, stop mining
    private func transitionToCharging() {
        mining.stop()
        charging.startCharging(shortcutName: settings.startChargingShortcut)
        state = .charging
    }

    /// Turn outlet OFF, start mining if load enabled
    private func transitionToDraining() {
        charging.stopCharging(shortcutName: settings.stopChargingShortcut)
        if settings.loadEnabled {
            mining.start()
        }
        state = .draining
    }
}
