import SwiftUI
import Combine

@main
struct BurnCycleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var charging = ChargingController()
    @StateObject private var mining = MiningManager()
    @StateObject private var stress = StressManager()
    @StateObject private var settings = AppSettings()
    @StateObject private var system = SystemMonitor()
    @StateObject private var history = HistoryRecorder()
    @State private var engine: CycleEngine?
    @State private var historyObserver: AnyCancellable?

    var body: some Scene {
        Window("BurnCycle", id: "main") {
            if let engine = engine {
                MainView(
                    battery: battery,
                    engine: engine,
                    mining: mining,
                    stress: stress,
                    charging: charging,
                    system: system,
                    settings: settings,
                    history: history
                )
            } else {
                SplashView()
                    .onAppear {
                        engine = CycleEngine(
                            battery: battery,
                            charging: charging,
                            mining: mining,
                            stress: stress,
                            system: system,
                            settings: settings
                        )
                        battery.startMonitoring()
                        system.startMonitoring()

                        historyObserver = battery.$cycleCount
                            .combineLatest(battery.$healthPercent, battery.$fullChargeCapacityMAh)
                            .sink { cycle, health, capacity in
                                Task { @MainActor in
                                    history.observe(cycleCount: cycle,
                                                    fullChargeCapacityMAh: capacity,
                                                    healthPercent: health)
                                }
                            }
                    }
            }
        }
        .windowResizability(.contentSize)

        // Menu bar status item with summary popover
        MenuBarExtra(isInserted: $settings.showInMenuBar) {
            if let engine = engine {
                MenuBarPopover(battery: battery, engine: engine, mining: mining,
                              stress: stress, settings: settings)
            } else {
                Text("Loading…").padding()
            }
        } label: {
            MenuBarLabel(battery: battery, engine: engine)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Compact label rendered in the menu bar — shows battery % + state icon
struct MenuBarLabel: View {
    @ObservedObject var battery: BatteryMonitor
    let engine: CycleEngine?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            Text("\(battery.percentage)%")
        }
    }

    private var iconName: String {
        guard let engine, engine.isRunning else {
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
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
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

            Divider()

            HStack(spacing: 8) {
                Button(engine.isRunning ? "Stop" : "Start") {
                    if engine.isRunning { engine.stop() } else { engine.start() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(engine.isRunning ? .red : .green)

                Button("Open Window") {
                    NSApp.activate(ignoringOtherApps: true)
                    if let win = NSApp.windows.first(where: { $0.title.contains("BurnCycle") || $0.contentViewController != nil }) {
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

/// Branded splash shown briefly while services finish initializing.
/// Pinned to the same size as MainView so the Window doesn't resize on transition.
/// No repeating animation here — `repeatForever` left lingering main-thread
/// transactions that hung the UI even after the splash was replaced.
struct SplashView: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.orange.opacity(0.5), Color.orange.opacity(0)],
                            center: .center,
                            startRadius: 4,
                            endRadius: 70
                        )
                    )
                    .frame(width: 140, height: 140)

                Image(systemName: "flame.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.55, blue: 0.10),
                                     Color(red: 1.0, green: 0.85, blue: 0.30)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 56, height: 56)
                    .shadow(color: .orange.opacity(0.6), radius: 12)
            }

            Text("BurnCycle")
                .font(.system(size: 22, weight: .semibold, design: .rounded))

            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
        }
        .frame(width: 320, height: 240)
    }
}

/// Reopen the main window when the dock icon is clicked or app is re-launched.
/// Without this, closing the window with the menu-bar item still active leaves the app
/// running with no visible UI and clicking the dock icon does nothing.
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
