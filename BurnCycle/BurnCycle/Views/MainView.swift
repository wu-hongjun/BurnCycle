import SwiftUI
import Charts

struct MainView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var stress: StressManager
    @ObservedObject var charging: ChargingController
    @ObservedObject var system: SystemMonitor
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryRecorder

    @State private var showSettings = false
    @State private var showInfo = false
    @State private var showHistory = false

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

            // Row 3: Load status (if active)
            if mining.isMining || stress.isRunning || engine.loadThrottled {
                HStack {
                    if mining.isMining {
                        Label(mining.hashrate != "0 H/s" ? mining.hashrate : mining.status,
                              systemImage: "bitcoinsign.circle")
                            .foregroundColor(.green)
                    } else if stress.isRunning {
                        Label(stress.status, systemImage: "bolt.trianglebadge.exclamationmark")
                            .foregroundColor(.orange)
                    } else if engine.loadThrottled {
                        Label("Throttled (system busy)", systemImage: "exclamationmark.triangle.fill")
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
            if let warning = engine.mismatchWarning {
                Text(warning).font(.caption2).foregroundColor(.orange)
            }

            // Controls
            HStack {
                Button("Settings") {
                    showSettings.toggle()
                    if showSettings { showInfo = false; showHistory = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Info") {
                    showInfo.toggle()
                    if showInfo { showSettings = false; showHistory = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("History") {
                    showHistory.toggle()
                    if showHistory { showSettings = false; showInfo = false }
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
                    // -- Battery Thresholds --
                    Text("Battery Thresholds").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    VStack(alignment: .leading) {
                        Text("Charge to: \(Int(settings.upperThreshold))%")
                        Slider(value: $settings.upperThreshold, in: 50...100, step: 5)
                    }
                    VStack(alignment: .leading) {
                        Text("Drain to: \(Int(settings.lowerThreshold))%")
                        Slider(value: $settings.lowerThreshold, in: 5...50, step: 5)
                    }

                    // -- Load Settings --
                    Text("Load Generation").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)

                    Toggle("Generate load while draining", isOn: $settings.loadEnabled)

                    if settings.loadEnabled {
                        Picker("Method", selection: $settings.loadMethod) {
                            ForEach(LoadMethod.allCases, id: \.rawValue) { method in
                                Text(method.rawValue).tag(method.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)

                        if settings.selectedLoadMethod == .mine {
                            VStack(alignment: .leading) {
                                Text("XMR Wallet (empty = default)")
                                    .font(.caption).foregroundColor(.secondary)
                                TextField("Wallet address", text: $settings.walletAddress)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.caption, design: .monospaced))
                            }

                            if mining.isMining {
                                HStack {
                                    Text("Mining: \(mining.status)")
                                    Spacer()
                                    Text(mining.hashrate).fontWeight(.medium).foregroundColor(.green)
                                }
                                .font(.caption)
                            }
                        } else {
                            Text("Stress test uses all CPU cores + GPU via Metal. No internet required.")
                                .font(.caption).foregroundColor(.secondary)

                            if stress.isRunning {
                                HStack {
                                    Text("Status:")
                                    Text(stress.status).fontWeight(.medium).foregroundColor(.orange)
                                }
                                .font(.caption)
                            }
                        }

                        if engine.loadThrottled {
                            Text("Load paused — system busy (CPU/GPU > 80%)")
                                .font(.caption).foregroundColor(.yellow)
                        }
                    }

                    // -- Outlet Control --
                    Text("Outlet Control").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)

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

                    Text("Behavior").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                    Toggle("Pause cycling when Mac sleeps", isOn: $settings.pauseOnSleep)

                    HStack {
                        Spacer()
                        Button("Quit BurnCycle") {
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

            // History panel
            if showHistory {
                VStack(alignment: .leading, spacing: 6) {
                    // Chart of health % over cycle count (only meaningful with 2+ entries)
                    if history.entries.count >= 2 {
                        Chart(history.entries) { entry in
                            LineMark(
                                x: .value("Cycle", entry.cycleCount),
                                y: .value("Health %", entry.healthPercent)
                            )
                            .foregroundStyle(.green)
                            .interpolationMethod(.monotone)

                            PointMark(
                                x: .value("Cycle", entry.cycleCount),
                                y: .value("Health %", entry.healthPercent)
                            )
                            .foregroundStyle(.green)
                            .symbolSize(20)
                        }
                        .chartYScale(domain: chartHealthDomain)
                        .chartYAxisLabel("Health %")
                        .chartXAxisLabel("Cycle")
                        .frame(height: 100)
                        .padding(.bottom, 4)

                        Divider()
                    }

                    HStack {
                        Text("Cycle").fontWeight(.semibold).frame(width: 45, alignment: .leading)
                        Text("Date").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                        Text("Capacity (mAh)").fontWeight(.semibold).frame(width: 90, alignment: .trailing)
                        Text("Health").fontWeight(.semibold).frame(width: 50, alignment: .trailing)
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    Divider()

                    if history.entries.isEmpty {
                        Text("No history yet. An entry is recorded on first observation and on every cycle count change.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        // Show up to 5 rows; scroll if more.
                        // Each row ≈ 18pt (caption2 + 4 spacing).
                        let rowHeight: CGFloat = 18
                        let visibleRows = min(history.entries.count, 5)
                        let scrollHeight = CGFloat(visibleRows) * rowHeight
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(history.entries.reversed()) { entry in
                                    HStack {
                                        Text("\(entry.cycleCount)")
                                            .frame(width: 45, alignment: .leading)
                                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text("\(entry.fullChargeCapacityMAh)")
                                            .frame(width: 90, alignment: .trailing)
                                        Text("\(entry.healthPercent)%")
                                            .frame(width: 50, alignment: .trailing)
                                            .foregroundColor(entry.healthPercent > 80 ? .green : entry.healthPercent > 50 ? .yellow : .red)
                                    }
                                    .font(.caption2)
                                }
                            }
                        }
                        .frame(height: scrollHeight)

                        HStack {
                            Text("\(history.entries.count) entries")
                                .font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Button("Clear All") {
                                history.clearAll()
                            }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .tint(.red)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    /// Auto-zoom Y axis around recorded health values for clearer trend visibility
    private var chartHealthDomain: ClosedRange<Int> {
        let values: [Int] = history.entries.map { $0.healthPercent }
        guard let lo = values.min(), let hi = values.max() else { return 0...100 }
        let pad: Int = max(2, (hi - lo) / 4)
        return max(0, lo - pad)...min(100, hi + pad)
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
        switch engine.state {
        case .charging:
            if battery.isPluggedIn && battery.chargerWatts > 0 {
                return "CHARGING (\(battery.chargerWatts)W)"
            } else if battery.isPluggedIn {
                return "CHARGING"
            } else {
                return "WAITING FOR AC"
            }
        case .draining:
            if battery.isPluggedIn {
                return "WAITING TO DRAIN"
            } else {
                return "DRAINING"
            }
        case .testing:
            return "TESTING OUTLET"
        case .idle:
            return "IDLE"
        }
    }

    private var stateColor: Color {
        switch engine.state {
        case .charging:
            return battery.isPluggedIn ? .green : .yellow
        case .draining:
            return battery.isPluggedIn ? .yellow : .orange
        case .testing:
            return .blue
        case .idle:
            return .secondary
        }
    }

    private var stateIcon: String {
        switch engine.state {
        case .charging:
            return battery.isPluggedIn ? "bolt.fill" : "exclamationmark.triangle.fill"
        case .draining:
            return battery.isPluggedIn ? "exclamationmark.triangle.fill" : "flame.fill"
        case .testing:
            return "checkmark.circle"
        case .idle:
            return "moon.fill"
        }
    }
}
