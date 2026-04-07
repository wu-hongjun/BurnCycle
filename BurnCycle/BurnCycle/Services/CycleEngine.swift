import Foundation
import Combine

enum CycleState: String {
    case charging = "CHARGING"
    case draining = "DRAINING"
    case idle = "IDLE"
}

@MainActor
final class CycleEngine: ObservableObject {
    @Published var state: CycleState = .idle
    @Published var cycleCount: Int = 0
    @Published var isRunning: Bool = false
    @Published var loadThrottled: Bool = false

    private let battery: BatteryMonitor
    private let charging: ChargingController
    private let mining: MiningManager
    private let stress: StressManager
    private let system: SystemMonitor
    private let settings: AppSettings

    private var timer: Timer?
    private var settingsObserver: AnyCancellable?
    private var batteryObserver: AnyCancellable?

    private let loadThreshold: Double = 80
    private let criticalBattery = 5

    init(battery: BatteryMonitor, charging: ChargingController, mining: MiningManager,
         stress: StressManager, system: SystemMonitor, settings: AppSettings) {
        self.battery = battery
        self.charging = charging
        self.mining = mining
        self.stress = stress
        self.system = system
        self.settings = settings

        settingsObserver = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.onSettingsChanged()
            }
        }

        batteryObserver = battery.$percentage.sink { [weak self] pct in
            Task { @MainActor in
                self?.onBatteryChanged(pct)
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        battery.update()
        system.update()

        let pct = battery.percentage
        if pct >= Int(settings.upperThreshold) {
            transitionToDraining()
        } else {
            transitionToCharging()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        stopAllLoad()
        state = .idle
    }

    // MARK: - Reactive

    private func onBatteryChanged(_ pct: Int) {
        guard isRunning else { return }

        if pct <= criticalBattery && state == .draining {
            stopAllLoad()
            charging.startCharging(shortcutName: settings.startChargingShortcut)
            state = .charging
            return
        }

        if state == .draining && pct <= Int(settings.lowerThreshold) {
            cycleCount += 1
            transitionToCharging()
        } else if state == .charging && pct >= Int(settings.upperThreshold) {
            transitionToDraining()
        }
    }

    private func onSettingsChanged() {
        guard isRunning, state == .draining else { return }

        if settings.loadEnabled && !isLoadRunning() && isSystemLoadSafe() {
            startLoad()
        } else if !settings.loadEnabled && isLoadRunning() {
            stopAllLoad()
        }
    }

    private func tick() {
        guard isRunning else { return }
        battery.update()
        system.update()

        if state == .draining {
            manageLoad()
        }
    }

    // MARK: - Load management

    private func startLoad() {
        loadThrottled = false
        switch settings.selectedLoadMethod {
        case .mine:
            mining.start(walletOverride: settings.walletAddress)
        case .stress:
            stress.start()
        }
    }

    private func stopAllLoad() {
        mining.stop()
        stress.stop()
        loadThrottled = false
    }

    private func isLoadRunning() -> Bool {
        mining.isMining || stress.isRunning
    }

    private func manageLoad() {
        guard settings.loadEnabled else { return }

        let safetyMargin = Int(settings.lowerThreshold) + 3
        if battery.percentage <= safetyMargin && isLoadRunning() {
            stopAllLoad()
            return
        }

        if isLoadRunning() {
            if !isSystemLoadSafe() {
                stopAllLoad()
                loadThrottled = true
            }
        } else if loadThrottled {
            if isSystemLoadSafe() && battery.percentage > safetyMargin {
                startLoad()
            }
        }
    }

    private func isSystemLoadSafe() -> Bool {
        if isLoadRunning() { return true }
        return system.cpuUsage < loadThreshold && system.gpuUsage < loadThreshold
    }

    // MARK: - State transitions

    private func transitionToCharging() {
        stopAllLoad()
        charging.startCharging(shortcutName: settings.startChargingShortcut)
        state = .charging
    }

    private func transitionToDraining() {
        charging.stopCharging(shortcutName: settings.stopChargingShortcut)
        if settings.loadEnabled {
            if isSystemLoadSafe() {
                startLoad()
            } else {
                loadThrottled = true
            }
        }
        state = .draining
    }
}
