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

    let battery: BatteryMonitor
    let charging: ChargingController
    let mining: MiningManager
    let stress: StressManager
    let system: SystemMonitor
    let settings: AppSettings

    // nonisolated(unsafe): written only on the main actor; read once in `deinit`
    // (the sole nonisolated accessor), which runs when no other reference exists.
    nonisolated(unsafe) var timer: Timer?
    nonisolated(unsafe) var preflightTask: Task<Void, Never>?
    /// Delayed auto-resume scheduled after `didWake`. Stored so `stop()` can cancel
    /// it; otherwise pressing Stop during the post-wake delay would silently restart
    /// the engine when the delay elapses (concurrency M-2).
    nonisolated(unsafe) var wakeResumeTask: Task<Void, Never>?
    private nonisolated(unsafe) var settingsObserver: AnyCancellable?
    private nonisolated(unsafe) var batteryObserver: AnyCancellable?

    let externalLoadThreshold: Double = 80
    let criticalBattery = 3
    private let preflightCacheTTL: TimeInterval = 30 * 60   // 30 minutes

    var lastSuccessfulPreflight: Date?

    var activeLoadMethod: String?
    var verifyTicksRemaining: Int = 0 // countdown ticks to verify power state
    var retryCount: Int = 0
    let maxRetries = 3

    // Throttle hysteresis — require N consecutive 10s ticks before flipping load
    // on/off, to avoid self-oscillation when our own load pushes CPU near 100%.
    // Asymmetric: stop fast (~30s) when the system looks busy, resume slow (~60s)
    // so a momentary dip doesn't immediately re-pile load on a hot machine.
    var consecutiveHighLoadTicks: Int = 0
    var consecutiveLowLoadTicks: Int = 0
    let highLoadStopThreshold: Int = 3   // need 3 ticks (~30s) of "too hot" to stop
    let lowLoadResumeThreshold: Int = 6  // need 6 ticks (~60s) of "cool" to resume

    var wasRunningBeforeSleep = false
    private nonisolated(unsafe) var sleepObserver: NSObjectProtocol?
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?

    // Charging-stall watchdog — macOS Optimized Battery Charging can cap charging
    // at ~80%, so the cycle would wait for upperThreshold forever. We warn (non-fatal)
    // if we've been .charging too long without reaching the threshold.
    var chargingStartedAt: Date?
    let chargingStallWarnInterval: TimeInterval = 90 * 60   // 90 minutes
    var chargingStallWarned = false

    /// One-shot emergency-charge latch for the "stopped but critically low" safeguard.
    /// Set true after firing on the stopped path so we don't spam the shortcut every
    /// publish; cleared once `percentage` recovers above `criticalBattery` (C-1).
    var firedIdleEmergencyCharge = false

    let watchdog: Watchdog
    /// Tracks the last-applied watchdog setting so the debounced settings observer
    /// only reloads the LaunchAgent when the toggle actually changes.
    var lastWatchdogEnabled: Bool
    private nonisolated(unsafe) var terminateObserver: NSObjectProtocol?

    init(battery: BatteryMonitor, charging: ChargingController, mining: MiningManager,
         stress: StressManager, system: SystemMonitor, settings: AppSettings,
         watchdog: Watchdog) {
        self.battery = battery
        self.charging = charging
        self.mining = mining
        self.stress = stress
        self.system = system
        self.settings = settings
        self.watchdog = watchdog
        self.lastWatchdogEnabled = settings.watchdogEnabled

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

        // Clean-quit catch-all: a graceful termination (⌘Q, logout, launchd
        // bootout) fires this so we tear down the watchdog and never leave the
        // outlet OFF. A jetsam SIGKILL CANNOT fire it — which is precisely why a
        // surviving sentinel is a reliable "we were killed" signal.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // Run SYNCHRONOUSLY (not via `Task { @MainActor }`): the process is
            // terminating, and a deferred hop may never execute before exit,
            // leaving the sentinel uncleared → a spurious watchdog relaunch after
            // a clean quit. willTerminate is delivered on the main thread (queue:
            // .main), so assuming MainActor isolation here is valid.
            MainActor.assumeIsolated { self?.handleCleanQuit() }
        }
    }

    deinit {
        // Defensive cleanup for any future non-singleton lifecycle (previews/tests).
        // NSWorkspace's notification center retains the block independently of the
        // token, so it must be explicitly removed or it fires against a dead object.
        let nc = NSWorkspace.shared.notificationCenter
        if let sleepObserver { nc.removeObserver(sleepObserver) }
        if let wakeObserver { nc.removeObserver(wakeObserver) }
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
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

    func setStatus(_ s: String?) {
        statusMessage = s
    }

    func setError(_ e: String?) {
        errorMessage = e
        if e != nil { statusMessage = nil }
    }

    func clearMessages() {
        statusMessage = nil
        errorMessage = nil
        // Also clear the charging controller's red shortcut error so a stale stderr
        // message doesn't linger after the engine has moved on (M3/M4/L5/L7). The
        // UI prefers engine.errorMessage as the authoritative channel.
        charging.lastError = nil
    }

    /// Refuse to cycle on a Mac with no internal battery (e.g. a desktop). Otherwise
    /// the engine would sit in .charging forever, repeatedly retrying the outlet (H-4).
    /// Sets a blocking error and returns false when no battery is present.
    func hasUsableBattery() -> Bool {
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

    func stop() {
        let wasDraining = state == .draining
        isRunning = false
        timer?.invalidate()
        timer = nil
        preflightTask?.cancel()
        preflightTask = nil
        wakeResumeTask?.cancel()
        wakeResumeTask = nil
        stopAllLoad()
        // No longer cycling — the watchdog must not relaunch us, and on-launch
        // recovery must not fire.
        watchdog.clearCycling()
        // Fail-safe: never leave the outlet OFF when we're not actively cycling.
        // If we were draining (or are otherwise on battery), restore charging.
        if wasDraining || !battery.isPluggedIn {
            charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
        }
        clearMessages()
        retryCount = 0
        verifyTicksRemaining = 0
        chargingStartedAt = nil
        chargingStallWarned = false
        firedIdleEmergencyCharge = false
        resetThrottleHysteresis()
        state = .idle
    }
}
