import SwiftUI

struct MainView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var charging: ChargingController
    @ObservedObject var system: SystemMonitor
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 20) {
            // Battery display
            VStack(spacing: 8) {
                Text("\(battery.percentage)%")
                    .font(.system(size: 48, weight: .bold, design: .rounded))

                ProgressView(value: Double(battery.percentage), total: 100)
                    .tint(batteryColor)
                    .scaleEffect(y: 2)

                HStack(spacing: 16) {
                    Label(engine.state.rawValue, systemImage: stateIcon)
                        .foregroundColor(stateColor)
                        .fontWeight(.semibold)

                    Label(charging.outletOn ? "Outlet ON" : "Outlet OFF",
                          systemImage: charging.outletOn ? "powerplug.fill" : "powerplug")
                        .foregroundColor(charging.outletOn ? .green : .orange)
                }
                .font(.caption)

                if let error = charging.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }

            Divider()

            // Controls
            HStack(spacing: 12) {
                Button(engine.isRunning ? "Stop Cycling" : "Start Cycling") {
                    if engine.isRunning { engine.stop() } else { engine.start() }
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isRunning ? .red : .green)

                if engine.isRunning {
                    Button(engine.state == .paused ? "Resume" : "Pause") {
                        if engine.state == .paused { engine.resume() } else { engine.pause() }
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Mining status (only when load is enabled and mining)
            if mining.isMining {
                HStack {
                    Label(mining.hashrate != "0 H/s" ? mining.hashrate : mining.status,
                          systemImage: "cpu")
                        .foregroundColor(.green)
                    Spacer()
                    Text("CPU: \(String(format: "%.0f%%", system.cpuUsage))")
                    Text("Draw: \(String(format: "%.1f W", system.powerWatts))")
                }
                .font(.caption)
                .padding(.horizontal, 4)
            }

            if engine.cycleCount > 0 {
                Text("Cycles completed: \(engine.cycleCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Settings
            DisclosureGroup("Settings") {
                VStack(alignment: .leading, spacing: 12) {
                    // Thresholds
                    VStack(alignment: .leading) {
                        Text("Charge to: \(Int(settings.upperThreshold))%")
                        Slider(value: $settings.upperThreshold, in: 50...100, step: 5)
                    }
                    VStack(alignment: .leading) {
                        Text("Drain to: \(Int(settings.lowerThreshold))%")
                        Slider(value: $settings.lowerThreshold, in: 5...50, step: 5)
                    }

                    Divider()

                    // Load toggle
                    Toggle("Generate load while draining (mine XMR)", isOn: $settings.loadEnabled)

                    if settings.loadEnabled && !mining.isMining {
                        Button("Test Mining") { mining.start() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else if mining.isMining {
                        Button("Stop Mining") { mining.stop() }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .controlSize(.small)
                    }

                    Divider()

                    // Shortcuts
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Start Charging Shortcut")
                            Spacer()
                            Button("Test") {
                                charging.testStartCharging(shortcutName: settings.startChargingShortcut)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(charging.isRunningShortcut)
                        }
                        TextField("Shortcut name", text: $settings.startChargingShortcut)
                            .textFieldStyle(.roundedBorder)

                        HStack {
                            Text("Stop Charging Shortcut")
                            Spacer()
                            Button("Test") {
                                charging.testStopCharging(shortcutName: settings.stopChargingShortcut)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(charging.isRunningShortcut)
                        }
                        TextField("Shortcut name", text: $settings.stopChargingShortcut)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, 4)
            }

            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 320)
    }

    private var batteryColor: Color {
        if battery.percentage > 60 { return .green }
        if battery.percentage > 20 { return .yellow }
        return .red
    }

    private var stateColor: Color {
        switch engine.state {
        case .charging: return .green
        case .draining: return .orange
        case .paused: return .yellow
        case .idle: return .secondary
        }
    }

    private var stateIcon: String {
        switch engine.state {
        case .charging: return "bolt.fill"
        case .draining: return "flame.fill"
        case .paused: return "pause.circle.fill"
        case .idle: return "moon.fill"
        }
    }
}
