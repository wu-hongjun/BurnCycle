import Foundation
import Combine

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
    @Published var miningThrottled: Bool = false

    private let battery: BatteryMonitor
    private let charging: ChargingController
    private let mining: MiningManager
    private let system: SystemMonitor
    private let settings: AppSettings

    private var timer: Timer?
    private var loadObserver: AnyCancellable?

    private let loadThreshold: Double = 80 // Don't mine if CPU or GPU > 80%

    init(battery: BatteryMonitor, charging: ChargingController, mining: MiningManager,
         system: SystemMonitor, settings: AppSettings) {
        self.battery = battery
        self.charging = charging
        self.mining = mining
        self.system = system
        self.settings = settings

        loadObserver = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.onLoadToggleChanged(self.settings.loadEnabled)
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
        miningThrottled = false
        state = .idle
    }

    func pause() {
        guard isRunning else { return }
        mining.stop()
        charging.startCharging(shortcutName: settings.startChargingShortcut)
        miningThrottled = false
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
        guard isRunning, state != .paused else { return }
        battery.update()
        system.update()

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
            } else {
                // Check system load and manage mining accordingly
                manageMiningLoad()
            }
        default:
            break
        }
    }

    /// Start/stop mining based on system load to avoid overloading the machine
    private func manageMiningLoad() {
        guard settings.loadEnabled else { return }

        if mining.isMining {
            // If system is overloaded (another app using heavy resources), pause mining
            if !isSystemLoadSafe() {
                mining.stop()
                miningThrottled = true
            }
        } else if miningThrottled {
            // Was throttled — check if load has dropped enough to resume
            if isSystemLoadSafe() {
                mining.start(walletOverride: settings.walletAddress)
                miningThrottled = false
            }
        }
    }

    /// Check if CPU and GPU have headroom for mining
    /// Returns false if either is above threshold (excluding our own mining load)
    private func isSystemLoadSafe() -> Bool {
        // If we're already mining, the high load is from us — that's fine
        if mining.isMining { return true }
        // If not mining and load is high, something else is using the system
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
