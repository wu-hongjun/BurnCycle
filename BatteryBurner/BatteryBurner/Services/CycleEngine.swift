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
    @Published var miningThrottled: Bool = false

    private let battery: BatteryMonitor
    private let charging: ChargingController
    private let mining: MiningManager
    private let system: SystemMonitor
    private let settings: AppSettings

    private var timer: Timer?
    private var loadObserver: AnyCancellable?
    private var batteryObserver: AnyCancellable?

    private let loadThreshold: Double = 80
    private let criticalBattery = 5 // Emergency: force charge at 5% regardless

    init(battery: BatteryMonitor, charging: ChargingController, mining: MiningManager,
         system: SystemMonitor, settings: AppSettings) {
        self.battery = battery
        self.charging = charging
        self.mining = mining
        self.system = system
        self.settings = settings

        // React to load toggle changes
        loadObserver = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.onLoadToggleChanged(self.settings.loadEnabled)
            }
        }

        // React to battery percentage changes immediately (don't wait for tick)
        batteryObserver = battery.$percentage.sink { [weak self] pct in
            Task { @MainActor in
                self?.onBatteryChanged(pct)
            }
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        battery.startMonitoring()
        battery.update()
        system.update()

        let pct = battery.percentage
        let upper = Int(settings.upperThreshold)
        let lower = Int(settings.lowerThreshold)

        if pct >= upper {
            transitionToDraining()
        } else if pct <= lower {
            transitionToCharging()
        } else {
            transitionToCharging()
        }

        // Check every 10 seconds (was 30s — too slow for safety)
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
        mining.stop()
        battery.stopMonitoring()
        miningThrottled = false
        state = .idle
    }

    // MARK: - Reactive battery safety

    /// Called whenever battery percentage changes (via BatteryMonitor's 5s poll)
    private func onBatteryChanged(_ pct: Int) {
        guard isRunning else { return }

        // CRITICAL SAFETY: force charge at 5% no matter what
        if pct <= criticalBattery && state == .draining {
            mining.stop()
            miningThrottled = false
            charging.startCharging(shortcutName: settings.startChargingShortcut)
            state = .charging
            return
        }

        // Normal threshold check
        if state == .draining && pct <= Int(settings.lowerThreshold) {
            cycleCount += 1
            transitionToCharging()
        } else if state == .charging && pct >= Int(settings.upperThreshold) {
            transitionToDraining()
        }
    }

    private func onLoadToggleChanged(_ enabled: Bool) {
        guard isRunning, state == .draining else { return }
        if enabled && !mining.isMining && isSystemLoadSafe() {
            mining.start(walletOverride: settings.walletAddress)
            miningThrottled = false
        } else if !enabled && mining.isMining {
            mining.stop()
            miningThrottled = false
        }
    }

    private func tick() {
        guard isRunning else { return }
        battery.update()
        system.update()

        // Battery checks are handled reactively via onBatteryChanged
        // Tick only handles mining load management
        if state == .draining {
            manageMiningLoad()
        }
    }

    private func manageMiningLoad() {
        guard settings.loadEnabled else { return }

        // Safety margin: stop mining 3% above threshold to give shortcut time to fire
        let safetyMargin = Int(settings.lowerThreshold) + 3
        if battery.percentage <= safetyMargin && mining.isMining {
            mining.stop()
            miningThrottled = false
            return
        }

        if mining.isMining {
            if !isSystemLoadSafe() {
                mining.stop()
                miningThrottled = true
            }
        } else if miningThrottled {
            if isSystemLoadSafe() && battery.percentage > safetyMargin {
                mining.start(walletOverride: settings.walletAddress)
                miningThrottled = false
            }
        }
    }

    private func isSystemLoadSafe() -> Bool {
        if mining.isMining { return true }
        return system.cpuUsage < loadThreshold && system.gpuUsage < loadThreshold
    }

    private func transitionToCharging() {
        mining.stop()
        miningThrottled = false
        charging.startCharging(shortcutName: settings.startChargingShortcut)
        state = .charging
    }

    private func transitionToDraining() {
        charging.stopCharging(shortcutName: settings.stopChargingShortcut)
        if settings.loadEnabled {
            if isSystemLoadSafe() {
                mining.start(walletOverride: settings.walletAddress)
                miningThrottled = false
            } else {
                miningThrottled = true
            }
        }
        state = .draining
    }
}
