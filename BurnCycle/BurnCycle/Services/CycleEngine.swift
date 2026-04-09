import Foundation
import Combine

enum CycleState: String {
    case charging = "CHARGING"
    case draining = "DRAINING"
    case idle = "IDLE"
    case testing = "TESTING"
}

@MainActor
final class CycleEngine: ObservableObject {
    @Published var state: CycleState = .idle
    @Published var cycleCount: Int = 0
    @Published var isRunning: Bool = false
    @Published var loadThrottled: Bool = false
    @Published var mismatchWarning: String?

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

    private var activeLoadMethod: String?
    private var verifyTicksRemaining: Int = 0 // countdown ticks to verify power state
    private var retryCount: Int = 0
    private let maxRetries = 3

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
                try? await Task.sleep(nanoseconds: 1_000_000); self?.onSettingsChanged()
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
        state = .testing
        mismatchWarning = "Testing outlet control..."
        battery.update()
        system.update()

        // Preflight: verify the shortcut actually controls power
        runPreflightTest()
    }

    /// Test that shortcuts can toggle power on/off.
    /// Turns outlet OFF, checks if AC disconnects, then restores.
    private func runPreflightTest() {
        let wasPluggedIn = battery.isPluggedIn

        // Step 1: Turn outlet OFF
        charging.stopCharging(shortcutName: settings.stopChargingShortcut)

        // Step 2: Wait 8s for the shortcut to execute and power state to settle
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            battery.update()

            let nowPluggedIn = battery.isPluggedIn

            if wasPluggedIn && !nowPluggedIn {
                // Shortcut works — outlet turned off successfully
                // Step 3: Restore power and start cycling
                mismatchWarning = "Outlet verified. Starting..."
                charging.startCharging(shortcutName: settings.startChargingShortcut)

                try? await Task.sleep(nanoseconds: 5_000_000_000)
                battery.update()
                mismatchWarning = nil
                beginCycling()

            } else if wasPluggedIn && nowPluggedIn {
                // Power didn't change — shortcut failed or multiple power sources
                mismatchWarning = "Outlet test failed: still charging after 'Stop' shortcut. Check that the shortcut controls the only power source (e.g. no Thunderbolt dock)."
                isRunning = false
                state = .idle

            } else if !wasPluggedIn {
                // Wasn't plugged in to begin with — can't test, just start
                mismatchWarning = "No AC detected. Connect charger via the controlled outlet, then try again."
                // Restore outlet ON so user can plug in
                charging.startCharging(shortcutName: settings.startChargingShortcut)
                isRunning = false
                state = .idle
            }
        }
    }

    /// Actually begin the charge/drain cycle after preflight passes
    private func beginCycling() {
        battery.update()
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

        // Verify physical power state matches expected state
        if verifyTicksRemaining > 0 {
            verifyTicksRemaining -= 1
            if verifyTicksRemaining == 0 {
                verifyPowerState()
            }
        }

        if state == .draining {
            manageLoad()
        }
    }

    /// Check that physical power state matches our cycle state
    /// Called ~20s after a transition (2 ticks at 10s) to give the shortcut time
    private func verifyPowerState() {
        let pluggedIn = battery.isPluggedIn

        if state == .charging && !pluggedIn {
            // Expected charging but not plugged in — shortcut failed or cable not connected
            if retryCount < maxRetries {
                retryCount += 1
                mismatchWarning = "Outlet not responding (retry \(retryCount)/\(maxRetries))..."
                charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
                verifyTicksRemaining = 2 // check again in ~20s
            } else {
                mismatchWarning = "Charger not detected. Check cable and outlet."
                retryCount = 0
            }
        } else if state == .draining && pluggedIn {
            // Expected draining but still plugged in
            if retryCount < maxRetries {
                retryCount += 1
                mismatchWarning = "Outlet not responding (retry \(retryCount)/\(maxRetries))..."
                charging.stopCharging(shortcutName: settings.stopChargingShortcut)
                verifyTicksRemaining = 2
            } else {
                mismatchWarning = "Still charging. Check outlet and shortcut."
                retryCount = 0
            }
        } else {
            // State matches — clear warnings
            mismatchWarning = nil
            retryCount = 0
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
        verifyTicksRemaining = 2 // verify in ~20s
        mismatchWarning = nil
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
        verifyTicksRemaining = 2
        mismatchWarning = nil
    }
}
