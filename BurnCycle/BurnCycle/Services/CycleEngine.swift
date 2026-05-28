import Foundation
import Combine
import AppKit

/// Coarse-grained cycle phase. `.testing` is the one-shot preflight that
/// verifies the configured shortcuts actually toggle outlet power before
/// the engine commits to a real charge/drain loop.
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
    private let brightness: BrightnessController

    // nonisolated(unsafe): written only on the main actor; read once in `deinit`
    // (the sole nonisolated accessor), which runs when no other reference exists.
    private nonisolated(unsafe) var timer: Timer?
    private nonisolated(unsafe) var preflightTask: Task<Void, Never>?
    /// Delayed auto-resume scheduled after `didWake`. Stored so `stop()` can cancel
    /// it; otherwise pressing Stop during the post-wake delay would silently restart
    /// the engine when the delay elapses (concurrency M-2).
    private nonisolated(unsafe) var wakeResumeTask: Task<Void, Never>?
    private nonisolated(unsafe) var settingsObserver: AnyCancellable?
    private nonisolated(unsafe) var batteryObserver: AnyCancellable?

    private let externalLoadThreshold: Double = 80
    private let criticalBattery = 3
    private let preflightCacheTTL: TimeInterval = 30 * 60   // 30 minutes

    private var lastSuccessfulPreflight: Date?

    private var activeLoadMethod: String?
    private var verifyTicksRemaining: Int = 0 // countdown ticks to verify power state
    private var retryCount: Int = 0
    private let maxRetries = 3

    // Throttle hysteresis — require N consecutive 10s ticks before flipping load
    // on/off, to avoid self-oscillation when our own load pushes CPU near 100%.
    // Asymmetric: stop fast (~30s) when the system looks busy, resume slow (~60s)
    // so a momentary dip doesn't immediately re-pile load on a hot machine.
    private var consecutiveHighLoadTicks: Int = 0
    private var consecutiveLowLoadTicks: Int = 0
    private let highLoadStopThreshold: Int = 3   // need 3 ticks (~30s) of "too hot" to stop
    private let lowLoadResumeThreshold: Int = 6  // need 6 ticks (~60s) of "cool" to resume

    private var wasRunningBeforeSleep = false
    private nonisolated(unsafe) var sleepObserver: NSObjectProtocol?
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?

    // Charging-stall watchdog — macOS Optimized Battery Charging can cap charging
    // at ~80%, so the cycle would wait for upperThreshold forever. We warn (non-fatal)
    // if we've been .charging too long without reaching the threshold.
    private var chargingStartedAt: Date?
    private let chargingStallWarnInterval: TimeInterval = 90 * 60   // 90 minutes
    private var chargingStallWarned = false

    /// One-shot emergency-charge latch for the "stopped but critically low" safeguard.
    /// Set true after firing on the stopped path so we don't spam the shortcut every
    /// publish; cleared once `percentage` recovers above `criticalBattery` (C-1).
    private var firedIdleEmergencyCharge = false

    init(battery: BatteryMonitor, charging: ChargingController, mining: MiningManager,
         stress: StressManager, system: SystemMonitor, settings: AppSettings,
         brightness: BrightnessController) {
        self.battery = battery
        self.charging = charging
        self.mining = mining
        self.stress = stress
        self.system = system
        self.settings = settings
        self.brightness = brightness

        settingsObserver = settings.objectWillChange
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.onSettingsChanged()
                }
            }

        batteryObserver = battery.$percentage
            .removeDuplicates()   // only react to actual % changes (F-04)
            .sink { [weak self] pct in
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

    deinit {
        // Defensive cleanup for any future non-singleton lifecycle (previews/tests).
        // NSWorkspace's notification center retains the block independently of the
        // token, so it must be explicitly removed or it fires against a dead object.
        let nc = NSWorkspace.shared.notificationCenter
        if let sleepObserver { nc.removeObserver(sleepObserver) }
        if let wakeObserver { nc.removeObserver(wakeObserver) }
        timer?.invalidate()
        preflightTask?.cancel()
        wakeResumeTask?.cancel()
        settingsObserver?.cancel()
        batteryObserver?.cancel()
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
        // Also clear the charging controller's red shortcut error so a stale stderr
        // message doesn't linger after the engine has moved on (M3/M4/L5/L7). The
        // UI prefers engine.errorMessage as the authoritative channel.
        charging.lastError = nil
    }

    private func handleSleep() {
        guard settings.pauseOnSleep else { return }
        if isRunning {
            // Only mark for fast resume if we were actually cycling. If we were still
            // in preflight (.testing), the outlet control was never confirmed, so a
            // bare resume that bypasses preflight would be unsafe (M-4). In that case
            // we just stop; the user re-presses Start and preflight runs fresh.
            wasRunningBeforeSleep = (state == .charging || state == .draining)
            stop()
            setStatus("Paused for sleep")
        }
    }

    private func handleWake() {
        // A manual start() after wake should re-run preflight in case hardware
        // changed while asleep (e.g. a dock was added) — invalidate the cache (M-2).
        // The auto-resume path below intentionally bypasses preflight.
        guard settings.pauseOnSleep, wasRunningBeforeSleep else {
            lastSuccessfulPreflight = nil
            return
        }
        wasRunningBeforeSleep = false
        lastSuccessfulPreflight = nil
        // Defer slightly so battery state reflects wake conditions. Stored so stop()
        // can cancel it — otherwise pressing Stop during the delay would silently
        // restart the engine after the sleep completes (concurrency M2).
        wakeResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.clearMessages()
            self.startAfterWake()
        }
    }

    /// Fast resume after sleep — bypasses preflight unconditionally.
    /// The cycle was running before sleep so preflight had already succeeded;
    /// any drift will be caught by `verifyPowerState` within ~20s.
    private func startAfterWake() {
        guard !isRunning else { return }
        guard hasUsableBattery() else { return }
        isRunning = true
        clearMessages()
        battery.update()
        system.update()
        beginCycling()
    }

    /// Refuse to cycle on a Mac with no internal battery (e.g. a desktop). Otherwise
    /// the engine would sit in .charging forever, repeatedly retrying the outlet (H-4).
    /// Sets a blocking error and returns false when no battery is present.
    private func hasUsableBattery() -> Bool {
        if !battery.hasBattery {
            isRunning = false
            state = .idle
            setError("No internal battery detected — cannot cycle.")
            return false
        }
        return true
    }

    func start() {
        guard !isRunning else { return }
        guard hasUsableBattery() else { return }

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
        // Defensive: never start cycling if the engine was stopped while preflight
        // (or the wake-resume delay) was still in flight (H-1).
        guard isRunning else { return }
        guard hasUsableBattery() else { return }
        battery.update()
        let pct = battery.percentage
        if pct >= Int(settings.effectiveUpperThreshold) {
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
        wakeResumeTask?.cancel()
        wakeResumeTask = nil
        stopAllLoad()
        brightness.restore()
        clearMessages()
        retryCount = 0
        verifyTicksRemaining = 0
        chargingStartedAt = nil
        chargingStallWarned = false
        firedIdleEmergencyCharge = false
        resetThrottleHysteresis()
        state = .idle
    }

    // MARK: - Brightness helpers

    /// Save the user's current brightness and dim, but only while we're in a
    /// charging state and the option is enabled (and the API is available).
    /// Safe to call repeatedly during a charge phase — `BrightnessController`
    /// remembers the pre-dim baseline on the first call and only re-applies
    /// the target on subsequent ones.
    private func applyDimIfEnabled() {
        guard settings.dimWhileCharging, brightness.isAvailable else { return }
        let target = Float(max(0.0, min(1.0, settings.dimBrightness)))
        brightness.saveAndDim(to: target)
    }

    // MARK: - Reactive

    private func onBatteryChanged(_ pct: Int) {
        // Read the live value rather than trusting the captured argument — rapid
        // publishes can enqueue tasks out of order with stale pct values (M-5).
        let pct = battery.percentage

        // CRITICAL SAFETY (stopped case): even when not cycling, if the app is open
        // and the battery is critically low on battery power, fire one best-effort
        // emergency charge (C-1). This is a one-shot per low-battery episode (reset
        // on recovery); it is NOT a substitute for the running-state floor, since a
        // stopped engine has no tick timer to re-verify or re-attempt a failed shortcut.
        guard isRunning else {
            if pct <= criticalBattery && !battery.isPluggedIn && battery.hasBattery {
                if !firedIdleEmergencyCharge {
                    firedIdleEmergencyCharge = true
                    charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
                    setError("Critically low (\(pct)%) — forced an emergency charge. Press Start to resume cycling.")
                }
            } else if pct > criticalBattery {
                firedIdleEmergencyCharge = false
            }
            return
        }
        // While running, keep the idle one-shot disarmed/recovered.
        if pct > criticalBattery { firedIdleEmergencyCharge = false }

        // Auto-clear active error/status when physical state matches expected
        if errorMessage != nil || statusMessage != nil {
            let pluggedIn = battery.isPluggedIn
            if (state == .charging && pluggedIn) || (state == .draining && !pluggedIn) {
                clearMessages()
                retryCount = 0
                verifyTicksRemaining = 0
            }
        }

        // CRITICAL SAFETY: force charge at/below critical%, regardless of state
        // (testing, charging that isn't actually delivering power, draining — all
        // covered). Re-verify the power state shortly after so a failed shortcut
        // doesn't leave us falsely believing we're charging (C-1).
        if pct <= criticalBattery {
            // If the battery jumped straight from above the lower threshold to
            // critical in one reading, the normal drain→charge branch below never
            // ran — count that completed drain here so the cycle isn't undercounted.
            let wasDraining = (state == .draining)
            stopAllLoad()
            resetThrottleHysteresis()
            charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
            if wasDraining { cycleCount += 1 }
            state = .charging
            chargingStartedAt = Date()
            chargingStallWarned = false
            applyDimIfEnabled()
            verifyTicksRemaining = 2
            return
        }

        if state == .draining && pct <= Int(settings.effectiveLowerThreshold) {
            // Edge-triggered: flip state to .charging FIRST so a repeated reading at
            // the threshold (before the shortcut completes) can't re-enter this branch
            // and double-count the cycle (H-3).
            state = .charging
            cycleCount += 1
            transitionToCharging()
        } else if state == .charging && pct >= Int(settings.effectiveUpperThreshold) {
            transitionToDraining()
        }
    }

    private func onSettingsChanged() {
        guard isRunning else { return }

        // Threshold changes mid-cycle should take effect immediately rather than
        // waiting for the next battery publish (M-1). Use effective thresholds so a
        // mis-ordered slider pair can't cause thrash.
        let pct = battery.percentage
        if state == .charging && pct >= Int(settings.effectiveUpperThreshold) {
            // Upper was lowered to at/below current charge — start draining now.
            transitionToDraining()
            return
        } else if state == .draining && pct <= Int(settings.effectiveLowerThreshold) {
            // Lower was raised to at/above current charge — start charging now.
            state = .charging
            cycleCount += 1
            transitionToCharging()
            return
        }

        // Dim-while-charging settings react live during a charge phase:
        // - Toggle on while charging → save & dim now.
        // - Toggle off while charging → restore immediately.
        // - Slider moved while charging and currently dimmed → re-apply target.
        if state == .charging {
            if settings.dimWhileCharging {
                applyDimIfEnabled()
            } else if brightness.isDimming {
                brightness.restore()
            }
        }

        guard state == .draining else { return }

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

        checkChargingStall()
    }

    /// Non-fatal watchdog: macOS Optimized Battery Charging can cap charging at ~80%,
    /// so the cycle would sit in .charging waiting for upperThreshold forever (H-2).
    /// After a long interval still charging, surface a warning but keep cycling.
    private func checkChargingStall() {
        guard state == .charging, let started = chargingStartedAt else { return }
        if !chargingStallWarned,
           Date().timeIntervalSince(started) >= chargingStallWarnInterval,
           battery.percentage < Int(settings.effectiveUpperThreshold) {
            chargingStallWarned = true
            setError("Charging stalled — macOS optimized charging may cap at 80%. Disable in System Settings ▸ Battery.")
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
                // Do NOT give up: a charging failure that goes unanswered drains the
                // battery toward 0%. Keep a sticky error, but reset and re-attempt on a
                // slower cadence so the engine never permanently abandons the battery
                // (C-2). Combined with the critical-battery guard this guarantees a floor.
                setError("Charger not detected. Check cable and outlet. Still retrying...")
                retryCount = 0
                // Outlet stopped responding — invalidate the preflight cache so a
                // future manual Start re-runs the test instead of skipping.
                lastSuccessfulPreflight = nil
                charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
                verifyTicksRemaining = 6 // ~60s, then check again
            }
        } else if state == .draining && pluggedIn {
            // Expected draining but still plugged in
            if retryCount < maxRetries {
                retryCount += 1
                setStatus("Outlet not responding (retry \(retryCount)/\(maxRetries))...")
                charging.stopCharging(shortcutName: settings.stopChargingShortcut, force: true)
                verifyTicksRemaining = 2
            } else {
                // Likely a second, non-controlled power source (e.g. a Thunderbolt
                // dock added mid-cycle, C-3). Our stop shortcut works but power keeps
                // flowing. Keep retrying on a slow cadence rather than abandoning (C-2).
                setError("Still charging while draining — a second power source may be connected (e.g. a Thunderbolt dock). Unplug it to continue. Still retrying...")
                retryCount = 0
                lastSuccessfulPreflight = nil
                charging.stopCharging(shortcutName: settings.stopChargingShortcut, force: true)
                verifyTicksRemaining = 6 // ~60s, then check again
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

        // Safety margin: stop load 3% above threshold (use effective lower so a
        // mis-ordered slider pair can't drive this above the upper threshold).
        let safetyMargin = Int(settings.effectiveLowerThreshold) + 3
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
        // Set state BEFORE the side-effectful shortcut call so a re-entrant
        // onBatteryChanged can't trigger a second transition in the torn window (M-3).
        state = .charging
        chargingStartedAt = Date()
        chargingStallWarned = false
        stopAllLoad()
        charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
        applyDimIfEnabled()
        verifyTicksRemaining = 2 // verify in ~20s
        resetThrottleHysteresis()
        // A drain just finished — meaningful moment to refresh battery health.
        // The call is internally throttled to once per hour, so adding it here
        // is safe even on rapid cycles.
        battery.refreshHealth()
        clearMessages()
    }

    private func transitionToDraining() {
        // Set state first (M-3), and use force:true so the stop command is never
        // silently dropped when another shortcut is in flight (consistent with
        // transitionToCharging's startCharging).
        state = .draining
        chargingStartedAt = nil
        chargingStallWarned = false
        brightness.restore()
        charging.stopCharging(shortcutName: settings.stopChargingShortcut, force: true)
        if settings.loadEnabled {
            if isExternalLoadSafe() {
                startLoad()
            } else {
                loadThrottled = true
            }
        }
        verifyTicksRemaining = 2
        resetThrottleHysteresis()
        clearMessages()
    }
}
