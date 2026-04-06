import SwiftUI

struct MainView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var charging: ChargingController
    @ObservedObject var system: SystemMonitor
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 12) {
            // Line 1: Battery info — %, cycles, health, draw
            HStack(spacing: 10) {
                Label("\(battery.percentage)%", systemImage: batteryIcon)
                    .foregroundColor(batteryColor)
                    .fontWeight(.bold)
                Spacer()
                Label("\(battery.cycleCount)", systemImage: "arrow.triangle.2.circlepath")
                Label("\(battery.healthPercent)%", systemImage: "heart.fill")
                    .foregroundColor(battery.healthPercent > 80 ? .green : battery.healthPercent > 50 ? .yellow : .red)
                Text("\(String(format: "%.1f", system.powerWatts))W")
                    .fontWeight(.medium)
            }
            .font(.caption)

            // Line 2: State, outlet, CPU, mining
            HStack(spacing: 10) {
                Label(stateLabel, systemImage: stateIcon)
                    .foregroundColor(stateColor)
                    .fontWeight(.semibold)
                Label(charging.outletOn ? "ON" : "OFF",
                      systemImage: charging.outletOn ? "powerplug.fill" : "powerplug")
                    .foregroundColor(charging.outletOn ? .green : .orange)
                if charging.isRunningShortcut {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                }
                Spacer()
                Text("CPU \(String(format: "%.0f%%", system.cpuUsage))")
                Text("GPU \(String(format: "%.0f%%", system.gpuUsage))")
                if mining.isMining {
                    Label(mining.hashrate != "0 H/s" ? mining.hashrate : mining.status,
                          systemImage: "cpu")
                        .foregroundColor(.green)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if let error = charging.lastError {
                Text(error).font(.caption2).foregroundColor(.red)
            }

            // Controls
            HStack(spacing: 12) {
                Button(engine.isRunning ? "Stop" : "Start") {
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

                Spacer()

                Toggle("Load", isOn: $settings.loadEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if engine.cycleCount > 0 {
                Text("Burn cycles: \(engine.cycleCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Settings
            DisclosureGroup("Settings") {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading) {
                        Text("Charge to: \(Int(settings.upperThreshold))%")
                        Slider(value: $settings.upperThreshold, in: 50...100, step: 5)
                    }
                    VStack(alignment: .leading) {
                        Text("Drain to: \(Int(settings.lowerThreshold))%")
                        Slider(value: $settings.lowerThreshold, in: 5...50, step: 5)
                    }

                    // Mining info
                    if mining.isMining {
                        HStack {
                            Text("Status: \(mining.status)")
                            Spacer()
                            Text(mining.hashrate)
                                .fontWeight(.medium)
                                .foregroundColor(.green)
                        }
                        .font(.caption)
                    }

                    VStack(alignment: .leading) {
                        Text("XMR Wallet (leave empty for default)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Wallet address", text: $settings.walletAddress)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Start Charging Shortcut")
                            Spacer()
                            Button("Test") {
                                charging.testStartCharging(shortcutName: settings.startChargingShortcut)
                            }
                            .buttonStyle(.bordered).controlSize(.mini)
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
                            .buttonStyle(.bordered).controlSize(.mini)
                            .disabled(charging.isRunningShortcut)
                        }
                        TextField("Shortcut name", text: $settings.stopChargingShortcut)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, 4)
            }
            .font(.callout)

            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 340)
    }

    private var batteryIcon: String {
        if battery.isCharging { return "battery.100.bolt" }
        if battery.percentage > 75 { return "battery.100" }
        if battery.percentage > 50 { return "battery.75" }
        if battery.percentage > 25 { return "battery.50" }
        return "battery.25"
    }

    private var batteryColor: Color {
        if battery.percentage > 60 { return .green }
        if battery.percentage > 20 { return .yellow }
        return .red
    }

    private var stateLabel: String {
        if engine.state == .charging && battery.chargerWatts > 0 {
            return "CHARGING (\(battery.chargerWatts)W)"
        }
        return engine.state.rawValue
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
