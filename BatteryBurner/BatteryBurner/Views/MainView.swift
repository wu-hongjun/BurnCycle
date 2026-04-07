import SwiftUI

struct MainView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var charging: ChargingController
    @ObservedObject var system: SystemMonitor
    @ObservedObject var settings: AppSettings

    @State private var showSettings = false
    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 10) {
            // Row 1: Battery — percentage, health, cycles
            HStack {
                Label("\(battery.percentage)%", systemImage: batteryIcon)
                    .foregroundColor(batteryColor)
                    .fontWeight(.bold)
                Spacer()
                Label("\(battery.healthPercent)%", systemImage: "heart.fill")
                    .foregroundColor(battery.healthPercent > 80 ? .green : battery.healthPercent > 50 ? .yellow : .red)
                Label("\(battery.cycleCount)", systemImage: "arrow.triangle.2.circlepath")
            }
            .font(.caption)

            // Row 2: System — state, CPU, GPU, power
            HStack {
                Label(stateLabel, systemImage: stateIcon)
                    .foregroundColor(stateColor)
                    .fontWeight(.semibold)
                if charging.isRunningShortcut {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                }
                Spacer()
                Text("CPU \(String(format: "%.0f%%", system.cpuUsage))")
                Text("GPU \(String(format: "%.0f%%", system.gpuUsage))")
                Text("\(String(format: "%.1f", system.powerWatts))W")
                    .fontWeight(.medium)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            // Row 3: Mining status (if active)
            if mining.isMining || engine.miningThrottled {
                HStack {
                    if mining.isMining {
                        Label(mining.hashrate != "0 H/s" ? mining.hashrate : mining.status,
                              systemImage: "cpu")
                            .foregroundColor(.green)
                    } else if engine.miningThrottled {
                        Label("Mining throttled (system busy)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                    }
                    Spacer()
                    if engine.cycleCount > 0 {
                        Text("Cycles: \(engine.cycleCount)")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            if let error = charging.lastError {
                Text(error).font(.caption2).foregroundColor(.red)
            }

            // Controls: Settings, Info, Start/Stop
            HStack {
                Button("Settings") {
                    showSettings.toggle()
                    if showSettings { showInfo = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Info") {
                    showInfo.toggle()
                    if showInfo { showSettings = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button(engine.isRunning ? "Stop" : "Start") {
                    if engine.isRunning { engine.stop() } else { engine.start() }
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isRunning ? .red : .green)
            }

            // Settings panel
            if showSettings {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading) {
                        Text("Charge to: \(Int(settings.upperThreshold))%")
                        Slider(value: $settings.upperThreshold, in: 50...100, step: 5)
                    }
                    VStack(alignment: .leading) {
                        Text("Drain to: \(Int(settings.lowerThreshold))%")
                        Slider(value: $settings.lowerThreshold, in: 5...50, step: 5)
                    }

                    // Load / Mining
                    Toggle("Mine XMR while draining", isOn: $settings.loadEnabled)

                    if settings.loadEnabled {
                        if mining.isMining {
                            HStack {
                                Text("Mining: \(mining.status)")
                                Spacer()
                                Text(mining.hashrate).fontWeight(.medium).foregroundColor(.green)
                            }
                            .font(.caption)
                        } else if engine.miningThrottled {
                            Text("Mining paused — system busy (CPU/GPU > 80%)")
                                .font(.caption).foregroundColor(.yellow)
                        }

                        VStack(alignment: .leading) {
                            Text("XMR Wallet (empty = default)")
                                .font(.caption).foregroundColor(.secondary)
                            TextField("Wallet address", text: $settings.walletAddress)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
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

                    HStack {
                        Spacer()
                        Button("Quit Battery Burner") {
                            engine.stop()
                            NSApplication.shared.terminate(nil)
                        }
                        .font(.caption).foregroundColor(.red)
                        Spacer()
                    }
                }
                .font(.callout)
                .padding(.top, 4)
            }

            // Info panel
            if showInfo {
                VStack(spacing: 6) {
                    infoRow("Battery Charge", "\(battery.currentCapacityMAh) mAh (\(battery.percentage)%)")
                    infoRow("Full Charge Capacity", "\(battery.fullChargeCapacityMAh) mAh")
                    infoRow("Design Capacity", "\(battery.designCapacityMAh) mAh")
                    if battery.designCapacityMAh > 0 {
                        infoRow("Battery Health (Real)", String(format: "%.1f%%",
                            Double(battery.fullChargeCapacityMAh) / Double(battery.designCapacityMAh) * 100))
                    }
                    infoRow("Battery Health (Apple)", "\(battery.healthPercent)%")
                    infoRow("Charge Cycles", "\(battery.cycleCount)")
                    infoRow("Temperature", String(format: "%.1f °C", battery.temperature))
                    infoRow("Voltage", String(format: "%.3f V", battery.voltage))
                    infoRow("Serial", battery.serial)
                    if battery.isPluggedIn {
                        infoRow("Power Adapter", battery.adapterName)
                        infoRow("Battery Input", String(format: "%.1f W", battery.chargingWatts))
                    } else {
                        infoRow("Battery Output", String(format: "%.1f W", battery.chargingWatts))
                    }
                }
                .font(.caption)
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }

    private var batteryIcon: String {
        if battery.isPluggedIn { return "battery.100.bolt" }
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
        case .idle: return .secondary
        }
    }

    private var stateIcon: String {
        switch engine.state {
        case .charging: return "bolt.fill"
        case .draining: return "flame.fill"
        case .idle: return "moon.fill"
        }
    }
}
