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
            settings: settings
        )

        // Start monitoring services
        battery.startMonitoring()
        system.startMonitoring()

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

/// Compact label rendered in the menu bar — shows battery % + state icon
struct MenuBarLabel: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            Text("\(battery.percentage)%")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("BurnCycle: battery \(battery.percentage) percent, \(stateDescription)")
    }

    private var stateDescription: String {
        guard engine.isRunning else {
            return battery.isPluggedIn ? "plugged in, idle" : "on battery, idle"
        }
        switch engine.state {
        case .charging: return "charging"
        case .draining: return "draining"
        case .testing: return "testing outlet"
        case .idle: return "idle"
        }
    }

    private var iconName: String {
        guard engine.isRunning else {
            return battery.isPluggedIn ? "battery.100.bolt" : "battery.50"
        }
        switch engine.state {
        case .charging: return "bolt.fill"
        case .draining: return "flame.fill"
        case .testing: return "checkmark.circle"
        case .idle: return "moon.fill"
        }
    }
}

/// Popover content shown when menu bar icon is clicked
struct MenuBarPopover: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var stress: StressManager
    @ObservedObject var settings: AppSettings

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(battery.percentage)%")
                    .font(.largeTitle.weight(.semibold))
                    .fontDesign(.rounded)
                Spacer()
                Text(engine.state.rawValue)
                    .font(.caption).fontWeight(.semibold)
                    .foregroundColor(stateColor)
            }

            Divider()

            HStack {
                Text("Health")
                Spacer()
                Text("\(battery.healthPercent)%")
                    .foregroundColor(battery.healthPercent > 80 ? .green : battery.healthPercent > 50 ? .yellow : .red)
            }
            .font(.caption)

            HStack {
                Text("Cycles")
                Spacer()
                Text("\(battery.cycleCount)")
            }
            .font(.caption)

            if mining.isMining {
                HStack {
                    Text("Mining")
                    Spacer()
                    Text(mining.hashrate).foregroundColor(.green)
                }
                .font(.caption)
            } else if stress.isRunning {
                HStack {
                    Text("Stress")
                    Spacer()
                    Text("Active").foregroundColor(.orange)
                }
                .font(.caption)
            }

            // Surface engine errors here too — a user running with the main window
            // closed would otherwise see no indication of a failure (L4/L7).
            if let err = engine.errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    if engine.isRunning { engine.stop() } else { engine.start() }
                } label: {
                    Label(engine.isRunning ? "Stop" : "Start",
                          systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(engine.isRunning ? .red : .green)

                Button("Open Window") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let win = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        win.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "main")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Quit") {
                    engine.stop()
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260)
    }

    private var stateColor: Color {
        switch engine.state {
        case .charging: return .green
        case .draining: return .orange
        case .testing: return .blue
        case .idle: return .secondary
        }
    }
}

/// Reopen the main window when the dock icon is clicked or app is re-launched.
final class AppDelegate: NSObject, NSApplicationDelegate {
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
