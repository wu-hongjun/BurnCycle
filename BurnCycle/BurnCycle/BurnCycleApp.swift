import SwiftUI
import Combine

/// Top-level container that owns all services. Creating one instance ensures
/// all services exist before any view body runs — no optional engine, no splash race.
@MainActor
final class AppServices: ObservableObject {
    let battery = BatteryMonitor()
    let charging = ChargingController()
    let mining = MiningManager()
    let stress = StressManager()
    let settings = AppSettings()
    let system = SystemMonitor()
    let history = HistoryRecorder()
    let watchdog = Watchdog()
    let engine: CycleEngine

    private var historyObserver: AnyCancellable?

    init() {
        // Initialise engine eagerly with the services above
        self.engine = CycleEngine(
            battery: battery,
            charging: charging,
            mining: mining,
            stress: stress,
            system: system,
            settings: settings,
            watchdog: watchdog
        )

        // Start monitoring services
        battery.startMonitoring()
        system.startMonitoring()

        // Crash/termination failsafe. Keep the watchdog LaunchAgent in sync with
        // the setting, then recover if a previous run was killed mid-cycle.
        if settings.watchdogEnabled {
            watchdog.install()
        } else {
            watchdog.uninstall()
        }
        // Defer recovery slightly so the first battery poll has populated state.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            engine.recoverFromUnexpectedExitIfNeeded()
        }

        // Record history snapshots when battery slow values change.
        // removeDuplicates() on each upstream avoids re-firing on every 60s slow-tick
        // when the values are identical (F-03).
        historyObserver = battery.$cycleCount.removeDuplicates()
            .combineLatest(battery.$healthPercent.removeDuplicates(),
                           battery.$fullChargeCapacityMAh.removeDuplicates())
            .sink { [weak self] cycle, health, capacity in
                Task { @MainActor in
                    self?.history.observe(cycleCount: cycle,
                                          fullChargeCapacityMAh: capacity,
                                          healthPercent: health)
                }
            }
    }
}

@main
struct BurnCycleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var services = AppServices()

    // Mirror of AppSettings.showInMenuBar backed by the same UserDefaults key. The
    // App body must observe this directly so toggling "Show in menu bar" in the
    // settings panel re-evaluates the scene and inserts/removes the MenuBarExtra
    // live (M5). AppServices does not forward settings.objectWillChange, so reading
    // services.settings here would not be reactive at the App level.
    @AppStorage("showInMenuBar") private var showInMenuBar: Bool = false

    var body: some Scene {
        Window("BurnCycle", id: "main") {
            MainView(
                battery: services.battery,
                engine: services.engine,
                mining: services.mining,
                stress: services.stress,
                charging: services.charging,
                system: services.system,
                settings: services.settings,
                history: services.history
            )
        }
        .windowResizability(.contentSize)

        // Menu bar status item with summary popover. Visibility is driven by the
        // App-level @AppStorage mirror so it reacts to settings changes live (M5).
        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarPopover(battery: services.battery, engine: services.engine,
                           mining: services.mining, stress: services.stress,
                           settings: services.settings)
        } label: {
            MenuBarLabel(battery: services.battery, engine: services.engine)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Reopen the main window when the dock icon is clicked or app is re-launched.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Bring an existing window forward when the user re-activates the app with
    /// no visible windows (Dock click, second launch) — without this, clicking
    /// the Dock icon does nothing once the main window has been closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }
}
