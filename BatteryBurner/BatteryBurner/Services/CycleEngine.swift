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

    private let battery: BatteryMonitor
    private let charging: ChargingController
    private let mining: MiningManager
    private let settings: AppSettings

    private var timer: Timer?
    private var loadObserver: AnyCancellable?

    init(battery: BatteryMonitor, charging: ChargingController, mining: MiningManager, settings: AppSettings) {
        self.battery = battery
        self.charging = charging
        self.mining = mining
        self.settings = settings

        // React to load toggle changes in real-time
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

    private func onLoadToggleChanged(_ enabled: Bool) {
        guard isRunning, state == .draining else { return }
        if enabled && !mining.isMining {
            mining.start(walletOverride: settings.walletAddress)
        } else if !enabled && mining.isMining {
            mining.stop()
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

    private func transitionToCharging() {
        mining.stop()
        charging.startCharging(shortcutName: settings.startChargingShortcut)
        state = .charging
    }

    private func transitionToDraining() {
        charging.stopCharging(shortcutName: settings.stopChargingShortcut)
        if settings.loadEnabled {
            mining.start(walletOverride: settings.walletAddress)
        }
        state = .draining
    }
}
