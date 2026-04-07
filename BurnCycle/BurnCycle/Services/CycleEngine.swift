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

    private let externalLoadThreshold: Double = 80
    private let criticalBattery = 5

    // Track what method was last started so we can detect changes
    private var activeLoadMethod: String?

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

        // CRITICAL SAFETY: force charge at 5%, bypass cooldown
        if pct <= criticalBattery && state == .draining {
            stopAllLoad()
            charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
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

        let wantLoad = settings.loadEnabled
        let wantMethod = settings.loadMethod
        let running = isLoadRunning()

        if wantLoad && !running && isExternalLoadSafe() {
            startLoad()
        } else if !wantLoad && running {
            stopAllLoad()
        } else if wantLoad && running && wantMethod != activeLoadMethod {
            // Method changed while running — switch
            stopAllLoad()
            startLoad()
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
        activeLoadMethod = settings.loadMethod
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
        activeLoadMethod = nil
    }

    private func isLoadRunning() -> Bool {
        mining.isMining || stress.isRunning
    }

    private func manageLoad() {
        guard settings.loadEnabled else { return }

        // Safety margin: stop load 3% above threshold
        let safetyMargin = Int(settings.lowerThreshold) + 3
        if battery.percentage <= safetyMargin && isLoadRunning() {
            stopAllLoad()
            return
        }

        // Check if external apps are using heavy resources
        // (our own load doesn't count — subtract approximate baseline)
        if isLoadRunning() {
            if !isExternalLoadSafe() {
                stopAllLoad()
                loadThrottled = true
            }
        } else if loadThrottled {
            if isExternalLoadSafe() && battery.percentage > safetyMargin {
                startLoad()
            }
        }
    }

    /// Check if external (non-BurnCycle) load is below threshold
    /// When our load is running, we check if usage is excessively high (>95%)
    /// which suggests external apps are also consuming heavily
    private func isExternalLoadSafe() -> Bool {
        if isLoadRunning() {
            // If we're running and CPU/GPU is near 100%, external apps are also heavy
            return system.cpuUsage < 95 && system.gpuUsage < 95
        }
        // If we're not running, check the raw threshold
        return system.cpuUsage < externalLoadThreshold && system.gpuUsage < externalLoadThreshold
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
            if isExternalLoadSafe() {
                startLoad()
            } else {
                loadThrottled = true
            }
        }
        state = .draining
    }
}
