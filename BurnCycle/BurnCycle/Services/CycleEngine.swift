import Foundation
import Combine
import AppKit

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

    /// Transient progress message for an in-flight operation (gray in UI).
    @Published var statusMessage: String?
    /// Sticky error the user should act on (orange in UI).
    @Published var errorMessage: String?

    private let battery: BatteryMonitor
    private let charging: ChargingController
    private let mining: MiningManager
    private let stress: StressManager
    private let system: SystemMonitor
    private let settings: AppSettings

    private var timer: Timer?
    private var preflightTask: Task<Void, Never>?
    private var settingsObserver: AnyCancellable?
    private var batteryObserver: AnyCancellable?

    private let externalLoadThreshold: Double = 80
    private let criticalBattery = 3
    private let preflightCacheTTL: TimeInterval = 30 * 60   // 30 minutes

    private var lastSuccessfulPreflight: Date?

    private var activeLoadMethod: String?
    private var verifyTicksRemaining: Int = 0 // countdown ticks to verify power state
    private var retryCount: Int = 0
    private let maxRetries = 3

    // Throttle hysteresis — require N consecutive ticks before flipping load on/off
    // to avoid self-oscillation when our own load pushes CPU near 100%.
    private var consecutiveHighLoadTicks: Int = 0
    private var consecutiveLowLoadTicks: Int = 0
    private let highLoadStopThreshold: Int = 3   // need 3 ticks (~30s) of "too hot" to stop
    private let lowLoadResumeThreshold: Int = 6  // need 6 ticks (~60s) of "cool" to resume

    private var wasRunningBeforeSleep = false
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init(battery: BatteryMonitor, charging: ChargingController, mining: MiningManager,
         stress: StressManager, system: SystemMonitor, settings: AppSettings) {
        self.battery = battery
        self.charging = charging
        self.mining = mining
        self.stress = stress
        self.system = system
        self.settings = settings

        settingsObserver = settings.objectWillChange
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.onSettingsChanged()
                }
            }

        batteryObserver = battery.$percentage.sink { [weak self] pct in
            Task { @MainActor in
                self?.onBatteryChanged(pct)
            }
        }

        // System sleep awareness — pause cycling when Mac sleeps
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(forName: NSWorkspace.willSleepNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSleep() }
        }
        wakeObserver = nc.addObserver(forName: NSWorkspace.didWakeNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
    }

    // MARK: - Message routing helpers
    //
    // All message assignments go through these helpers so the routing is greppable.
    // - setStatus: transient "we're working on it" — gray.
    // - setError:  user must act — orange. Clears any in-flight status.
    // - clearMessages: operation succeeded or moved on — clear both.

    private func setStatus(_ s: String?) {
        statusMessage = s
    }

    private func setError(_ e: String?) {
        errorMessage = e
        if e != nil { statusMessage = nil }
    }

    private func clearMessages() {
        statusMessage = nil
        errorMessage = nil
    }

    private func handleSleep() {
        guard settings.pauseOnSleep else { return }
        if isRunning {
            wasRunningBeforeSleep = true
            stop()
            setStatus("Paused for sleep")
        }
    }

    private func handleWake() {
        guard settings.pauseOnSleep, wasRunningBeforeSleep else { return }
        wasRunningBeforeSleep = false
        // Defer slightly so battery state reflects wake conditions
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            clearMessages()
            self.startAfterWake()
        }
    }

    /// Fast resume after sleep — bypasses preflight unconditionally.
    /// The cycle was running before sleep so preflight had already succeeded;
    /// any drift will be caught by `verifyPowerState` within ~20s.
    private func startAfterWake() {
        guard !isRunning else { return }
        isRunning = true
        clearMessages()
        battery.update()
        system.update()
        beginCycling()
    }

    func start() {
        guard !isRunning else { return }

        // Skip preflight if we have a recent successful result cached.
        if let last = lastSuccessfulPreflight,
           Date().timeIntervalSince(last) < preflightCacheTTL {
            isRunning = true
            clearMessages()
            battery.update()
            system.update()
            beginCycling()
            return
        }

        isRunning = true
        state = .testing
        clearMessages()
        setStatus("Testing outlet control...")
        battery.update()
        system.update()

        // Preflight: verify the shortcut actually controls power
        runPreflightTest()
    }

    /// User-initiated cache invalidation. The next `start()` will re-run preflight
    /// instead of skipping. No-op if no cache exists or if the engine is currently
    /// running (don't disturb an active cycle).
    func invalidatePreflightCache() {
        guard !isRunning else { return }
        lastSuccessfulPreflight = nil
    }

    /// Read-only view of the cache state for UI affordance enable/disable.
    var hasCachedPreflight: Bool { lastSuccessfulPreflight != nil }

    /// Test that shortcuts can toggle power by flipping the outlet and verifying the state changes.
    /// Handles both initial states: outlet ON (plugged in) or outlet OFF (on battery).
    private func runPreflightTest() {
        let wasPluggedIn = battery.isPluggedIn

        preflightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if wasPluggedIn {
                // Case A: Currently plugged in — test by turning OFF
                setStatus("Testing: turning outlet OFF...")
                charging.stopCharging(shortcutName: settings.stopChargingShortcut)

                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled || !isRunning { return }
                battery.update()

                if !battery.isPluggedIn {
                    setStatus("Testing: turning outlet ON...")
                    charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)

                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if Task.isCancelled || !isRunning { return }
                    battery.update()

                    if battery.isPluggedIn {
                        clearMessages()
                        lastSuccessfulPreflight = Date()
                        beginCycling()
                    } else {
                        setError("Outlet test failed: 'Start' shortcut didn't restore power.")
                        lastSuccessfulPreflight = nil
                        isRunning = false
                        state = .idle
                    }
                } else {
                    setError("Outlet test failed: still charging after 'Stop' shortcut. Check for multiple power sources (e.g. Thunderbolt dock).")
                    lastSuccessfulPreflight = nil
                    isRunning = false
                    state = .idle
                }
            } else {
                // Case B: Currently on battery — test by turning ON
                setStatus("Testing: turning outlet ON...")
                charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)

                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled || !isRunning { return }
                battery.update()

                if battery.isPluggedIn {
                    setStatus("Testing: turning outlet OFF...")
                    charging.stopCharging(shortcutName: settings.stopChargingShortcut)

                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if Task.isCancelled || !isRunning { return }
                    battery.update()

                    if !battery.isPluggedIn {
                        charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if Task.isCancelled || !isRunning { return }
                        battery.update()
                        clearMessages()
                        lastSuccessfulPreflight = Date()
                        beginCycling()
                    } else {
                        setError("Outlet test failed: 'Stop' shortcut didn't disconnect power.")
                        lastSuccessfulPreflight = nil
                        isRunning = false
                        state = .idle
                    }
                } else {
                    setError("Outlet test failed: no power after 'Start' shortcut. Check that the charger cable is plugged into the controlled outlet.")
                    lastSuccessfulPreflight = nil
                    isRunning = false
                    state = .idle
                }
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
        preflightTask?.cancel()
        preflightTask = nil
        stopAllLoad()
        clearMessages()
        retryCount = 0
        verifyTicksRemaining = 0
        resetThrottleHysteresis()
        state = .idle
    }

    // MARK: - Reactive

    private func onBatteryChanged(_ pct: Int) {
        guard isRunning else { return }

        // Auto-clear active error/status when physical state matches expected
        if errorMessage != nil || statusMessage != nil {
            let pluggedIn = battery.isPluggedIn
            if (state == .charging && pluggedIn) || (state == .draining && !pluggedIn) {
                clearMessages()
                retryCount = 0
                verifyTicksRemaining = 0
            }
        }

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

        // Clear throttle state when load is disabled — it's no longer relevant
        if !wantLoad {
            loadThrottled = false
        }

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
                setStatus("Outlet not responding (retry \(retryCount)/\(maxRetries))...")
                charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
                verifyTicksRemaining = 2 // check again in ~20s
            } else {
                setError("Charger not detected. Check cable and outlet.")
                retryCount = 0
                // Outlet just stopped responding — invalidate the preflight
                // cache so the next Start re-runs the test instead of skipping.
                lastSuccessfulPreflight = nil
            }
        } else if state == .draining && pluggedIn {
            // Expected draining but still plugged in
            if retryCount < maxRetries {
                retryCount += 1
                setStatus("Outlet not responding (retry \(retryCount)/\(maxRetries))...")
                charging.stopCharging(shortcutName: settings.stopChargingShortcut)
                verifyTicksRemaining = 2
            } else {
                setError("Still charging. Check outlet and shortcut.")
                retryCount = 0
                lastSuccessfulPreflight = nil
            }
        } else {
            // State matches — clear messages
            clearMessages()
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

    private func resetThrottleHysteresis() {
        consecutiveHighLoadTicks = 0
        consecutiveLowLoadTicks = 0
    }

    private func manageLoad() {
        guard settings.loadEnabled else { return }

        // Safety margin: stop load 3% above threshold (unchanged)
        let safetyMargin = Int(settings.lowerThreshold) + 3
        if battery.percentage <= safetyMargin && isLoadRunning() {
            stopAllLoad()
            resetThrottleHysteresis()
            return
        }

        let externalSafe = isExternalLoadSafe()

        if isLoadRunning() {
            if !externalSafe {
                consecutiveHighLoadTicks += 1
                consecutiveLowLoadTicks = 0
                if consecutiveHighLoadTicks >= highLoadStopThreshold {
                    stopAllLoad()
                    loadThrottled = true
                    consecutiveHighLoadTicks = 0
                }
            } else {
                consecutiveHighLoadTicks = 0
            }
        } else if loadThrottled {
            if externalSafe && battery.percentage > safetyMargin {
                consecutiveLowLoadTicks += 1
                consecutiveHighLoadTicks = 0
                if consecutiveLowLoadTicks >= lowLoadResumeThreshold {
                    startLoad()
                    consecutiveLowLoadTicks = 0
                }
            } else {
                consecutiveLowLoadTicks = 0
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
        resetThrottleHysteresis()
        // A drain just finished — meaningful moment to refresh battery health.
        // The call is internally throttled to once per hour, so adding it here
        // is safe even on rapid cycles.
        battery.refreshHealth()
        clearMessages()
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
        resetThrottleHysteresis()
        clearMessages()
    }
}
