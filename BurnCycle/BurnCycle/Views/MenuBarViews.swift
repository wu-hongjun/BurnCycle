import SwiftUI

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
                    .foregroundColor(engine.state.color)
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
}
