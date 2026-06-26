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
    @State private var showClearConfirm = false
    @State private var showAdvanced = false
    /// History-chart entry currently under the cursor (nil when not hovering).
    @State private var hoverEntry: HistoryEntry?

    // Draft threshold values for the Settings input boxes. They hold the user's
    // edits until "Save" commits them to AppSettings, so typing an intermediate
    // value (e.g. "8" on the way to "80") doesn't momentarily drive the engine.
    @State private var upperDraft = 90
    @State private var lowerDraft = 5
    @State private var thresholdError: String?

    /// True when the draft boxes differ from the saved thresholds (enables Save).
    private var thresholdsDirty: Bool {
        upperDraft != Int(settings.upperThreshold) || lowerDraft != Int(settings.lowerThreshold)
    }

    /// Reload the draft boxes from the saved settings (called when the panel opens
    /// so discarded edits don't linger, and after a successful Save).
    private func syncThresholdDrafts() {
        upperDraft = Int(settings.upperThreshold)
        lowerDraft = Int(settings.lowerThreshold)
        thresholdError = nil
    }

    /// Validate and commit the draft thresholds. Ranges mirror the old sliders
    /// (charge 50–100, drain 5–50) and the engine's required 5% gap.
    private func saveThresholds() {
        let upper = min(max(upperDraft, 50), 100)
        let lower = min(max(lowerDraft, 5), 50)
        guard Double(upper) >= Double(lower) + AppSettings.minThresholdGap else {
            thresholdError = "Charge must be at least \(Int(AppSettings.minThresholdGap))% above drain."
            return
        }
        settings.upperThreshold = Double(upper)
        settings.lowerThreshold = Double(lower)
        upperDraft = upper
        lowerDraft = lower
        thresholdError = nil
    }

    var body: some View {
        VStack(spacing: 10) {
            // Row 1: Battery — percentage, health, cycles
            HStack {
                Label("\(battery.percentage)%", systemImage: batteryIcon)
                    .foregroundColor(batteryColor)
                    .fontWeight(.bold)
                    .accessibilityLabel("Battery \(battery.percentage) percent, \(battery.isPluggedIn ? "plugged in" : "on battery")")
                Spacer()
                Label("\(battery.healthPercent)%", systemImage: healthIcon)
                    .foregroundColor(healthColor)
                    .accessibilityLabel("Battery health \(battery.healthPercent) percent, \(healthDescription)")
                Label("\(battery.cycleCount)", systemImage: "arrow.triangle.2.circlepath")
                    .accessibilityLabel("\(battery.cycleCount) hardware charge cycles")
            }
            .font(.caption)

            // Row 2: System — state, CPU, GPU, power
            HStack {
                Label(stateLabel, systemImage: stateIcon)
                    .foregroundColor(stateColor)
                    .fontWeight(.semibold)
                    .accessibilityLabel("State: \(stateLabel)")
                if charging.isRunningShortcut {
                    ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        .accessibilityLabel("Running shortcut")
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
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    if engine.cycleCount > 0 {
                        Text("Session: \(engine.cycleCount)")
                            .accessibilityLabel("\(engine.cycleCount) cycles completed this session")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            // Prefer the engine's error (orange) as the single source of truth.
            // Only fall back to charging.lastError (red) when the engine has none,
            // to avoid showing duplicate / stale/contradictory error lines.
            if let err = engine.errorMessage {
                Text(err).font(.caption2).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = charging.lastError {
                Text(error).font(.caption2).foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = engine.statusMessage {
                Text(status).font(.caption2).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Controls
            HStack {
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

                Button("Settings") {
                    showSettings.toggle()
                    if showSettings { showInfo = false; showHistory = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    if engine.isRunning { engine.stop() } else { engine.start() }
                } label: {
                    Label(engine.isRunning ? "Stop" : "Start",
                          systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isRunning ? .red : .green)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(engine.isRunning ? "Stop cycling" : "Start cycling")
            }

            // Settings panel
            if showSettings {
                VStack(alignment: .leading, spacing: 10) {
                    // -- Battery Thresholds --
                    Text("Battery Thresholds").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Text("Charge to")
                            TextField("", value: $upperDraft, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 44)
                            Text("%")
                        }
                        HStack(spacing: 4) {
                            Text("Drain to")
                            TextField("", value: $lowerDraft, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 44)
                            Text("%")
                        }
                        Spacer()
                        Button("Save") { saveThresholds() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!thresholdsDirty)
                    }
                    if let thresholdError {
                        Text(thresholdError)
                            .font(.caption2).foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // -- Outlet Control --
                    Text("Outlet Control").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text("Start").font(.caption)
                                    Button("Test") {
                                        charging.testStartCharging(shortcutName: settings.startChargingShortcut)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                    .disabled(charging.isRunningShortcut)
                                }
                                TextField("Start shortcut", text: $settings.startChargingShortcut)
                                    .textFieldStyle(.roundedBorder)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text("Stop").font(.caption)
                                    Button("Test") {
                                        charging.testStopCharging(shortcutName: settings.stopChargingShortcut)
                                    }
                                    .buttonStyle(.bordered).controlSize(.mini)
                                    .disabled(charging.isRunningShortcut)
                                }
                                TextField("Stop shortcut", text: $settings.stopChargingShortcut)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        if engine.isRunning {
                            Text("Shortcut name changes apply on the next charge/drain phase.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    }

                    Text("Behavior").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                    Toggle("Pause cycling when Mac sleeps", isOn: $settings.pauseOnSleep)
                    HStack(spacing: 4) {
                        Toggle("Relaunch if killed mid-cycle", isOn: $settings.watchdogEnabled)
                        InfoButton(text: "Restores charging and resumes if the app is closed unexpectedly while draining. Recommended.")
                        Spacer()
                    }

                    Text("Load Generation").font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    Toggle("Generate load while draining", isOn: $settings.loadEnabled)

                    // -- Advanced (collapsed): load method --
                    // Hand-rolled disclosure: a plain Button toggling `showAdvanced`
                    // is reliable both ways, unlike DisclosureGroup(isExpanded:) which
                    // can stick open when it hosts controls (Picker/TextField/Toggle).
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                            Text("Advanced").font(.caption).fontWeight(.semibold)
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showAdvanced {
                        VStack(alignment: .leading, spacing: 8) {
                            if settings.loadEnabled {
                                Picker("Load Method", selection: $settings.loadMethod) {
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

                                    if let stressErr = stress.lastError {
                                        Label(stressErr, systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption).foregroundColor(.orange)
                                    }
                                }

                                if engine.loadThrottled {
                                    Label("Load paused — system busy (CPU/GPU > 80%)",
                                          systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption).foregroundColor(.orange)
                                }
                            } else {
                                Text("Turn on “Generate load while draining” to pick a load method.")
                                    .font(.caption).foregroundColor(.secondary)
                            }

                            Divider()

                            HStack(spacing: 4) {
                                Button("Force re-test before next Start") {
                                    engine.invalidatePreflightCache()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(engine.isRunning || !engine.hasCachedPreflight)
                                InfoButton(text: "Before the first Start, BurnCycle flips your outlet off then on to confirm the Shortcut really controls power. That check is reused for 30 minutes. Use this to force a fresh check after moving the plug or changing hubs.")
                                Spacer()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

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
                .onAppear { syncThresholdDrafts() }
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
                    infoRow("Serial", battery.serial.isEmpty ? "—" : battery.serial)
                    if battery.isPluggedIn {
                        infoRow("Power Adapter", battery.adapterName.isEmpty ? "—" : battery.adapterName)
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
                    // Chart of health % (left axis) and full-charge capacity in mAh
                    // (right axis) over cycle count. Apple's reported health is an
                    // integer that holds the same value for 100+ cycles, so on its
                    // own it's a flat line; capacity in mAh has far finer resolution
                    // and reveals the actual degradation trend. Capacity is plotted
                    // in the health axis' coordinate space (see capacityToHealthScale)
                    // so a single chart keeps both series perfectly aligned, with the
                    // trailing axis de-normalizing the ticks back to mAh.
                    if history.entries.count >= 2 {
                        // Hover readout — reflects the entry under the cursor. Fixed
                        // height so the layout doesn't jump as it appears/clears.
                        HStack(spacing: 8) {
                            if let e = hoverEntry {
                                Text("Cycle \(e.cycleCount)").fontWeight(.semibold)
                                Text("\(e.fullChargeCapacityMAh) mAh").foregroundStyle(.blue)
                                Text("\(e.healthPercent)%").foregroundStyle(.green)
                                Spacer()
                                Text(e.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Hover the chart for exact values")
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                        .font(.caption2)
                        .frame(height: 14)

                        Chart {
                            ForEach(history.entries) { entry in
                                LineMark(
                                    x: .value("Cycle", entry.cycleCount),
                                    y: .value("Health %", Double(entry.healthPercent)),
                                    series: .value("Series", "Health %")
                                )
                                .foregroundStyle(by: .value("Series", "Health %"))
                                .interpolationMethod(.monotone)

                                LineMark(
                                    x: .value("Cycle", entry.cycleCount),
                                    y: .value("Capacity", capacityToHealthScale(entry.fullChargeCapacityMAh)),
                                    series: .value("Series", "Capacity (mAh)")
                                )
                                .foregroundStyle(by: .value("Series", "Capacity (mAh)"))
                                .interpolationMethod(.monotone)
                            }

                            // Hover feedback: a vertical rule marks the entry under
                            // the cursor; the exact values are shown in the readout
                            // line above the chart (the 120pt frame is too tight for
                            // an in-chart annotation without clipping).
                            if let e = hoverEntry {
                                RuleMark(x: .value("Cycle", e.cycleCount))
                                    .foregroundStyle(.gray.opacity(0.5))
                                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            }
                        }
                        .chartForegroundStyleScale(["Health %": Color.green, "Capacity (mAh)": Color.blue])
                        .chartYScale(domain: Double(chartHealthDomain.lowerBound)...Double(chartHealthDomain.upperBound))
                        .chartXScale(domain: chartCycleDomain)
                        .chartYAxis {
                            // Leading axis: real health % ticks (green).
                            AxisMarks(position: .leading) { value in
                                AxisGridLine()
                                AxisTick()
                                if let v = value.as(Double.self) {
                                    AxisValueLabel { Text("\(Int(v.rounded()))").foregroundStyle(.green) }
                                }
                            }
                            // Trailing axis: same tick positions, de-normalized to mAh (blue).
                            AxisMarks(position: .trailing) { value in
                                if let v = value.as(Double.self) {
                                    AxisValueLabel { Text("\(healthScaleToCapacity(v))").foregroundStyle(.blue) }
                                }
                            }
                        }
                        .chartXAxisLabel("Cycle")
                        .chartLegend(position: .bottom, spacing: 4)
                        .chartOverlay { proxy in
                            GeometryReader { geo in
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .onContinuousHover { phase in
                                        switch phase {
                                        case .active(let location):
                                            guard let plotFrame = proxy.plotFrame else { hoverEntry = nil; return }
                                            let xPos = location.x - geo[plotFrame].origin.x
                                            guard let cycle = proxy.value(atX: xPos, as: Int.self) else { hoverEntry = nil; return }
                                            hoverEntry = nearestEntry(toCycle: cycle)
                                        case .ended:
                                            hoverEntry = nil
                                        }
                                    }
                            }
                        }
                        .frame(height: 120)
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
                                showClearConfirm = true
                            }
                            .buttonStyle(.bordered).controlSize(.mini)
                            .tint(.red)
                            .confirmationDialog("Delete all history?",
                                                isPresented: $showClearConfirm,
                                                titleVisibility: .visible) {
                                Button("Delete All Entries", role: .destructive) {
                                    history.clearAll()
                                }
                                Button("Cancel", role: .cancel) { }
                            } message: {
                                Text("This permanently removes all recorded battery health history. This cannot be undone.")
                            }
                        }
                    }

                    if let saveErr = history.lastError {
                        Label(saveErr, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundColor(.orange)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(minWidth: 320, idealWidth: 320, maxWidth: 420)
    }

    /// Auto-zoom Y axis around recorded health values for clearer trend visibility
    private var chartHealthDomain: ClosedRange<Int> {
        let values: [Int] = history.entries.map { $0.healthPercent }
        guard let lo = values.min(), let hi = values.max() else { return 0...100 }
        let pad: Int = max(2, (hi - lo) / 4)
        return max(0, lo - pad)...min(100, hi + pad)
    }

    /// X axis range — starts at the smallest recorded cycle, not 0
    private var chartCycleDomain: ClosedRange<Int> {
        let values: [Int] = history.entries.map { $0.cycleCount }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        // If only one unique cycle value, pad so the line is visible
        if lo == hi { return (lo - 1)...(hi + 1) }
        let pad: Int = max(1, (hi - lo) / 10)
        return max(0, lo - pad)...(hi + pad)
    }

    /// Auto-zoomed mAh range for the capacity (right) axis. Padded so the trend
    /// fills the plot rather than hugging an edge.
    private var chartCapacityDomain: ClosedRange<Int> {
        let values: [Int] = history.entries.map { $0.fullChargeCapacityMAh }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if lo == hi { return (lo - 10)...(hi + 10) }
        let pad: Int = max(5, (hi - lo) / 4)
        return (lo - pad)...(hi + pad)
    }

    /// Map a capacity (mAh) into the health axis' coordinate space so both
    /// series share one Y scale and stay perfectly aligned. Linear remap from
    /// the capacity domain onto the health domain.
    private func capacityToHealthScale(_ capacity: Int) -> Double {
        let h = chartHealthDomain, c = chartCapacityDomain
        let cLo = Double(c.lowerBound), cHi = Double(c.upperBound)
        let hLo = Double(h.lowerBound), hHi = Double(h.upperBound)
        guard cHi > cLo else { return hLo }
        return hLo + (Double(capacity) - cLo) / (cHi - cLo) * (hHi - hLo)
    }

    /// Inverse of `capacityToHealthScale` — turns a health-axis tick position
    /// back into the mAh value it represents, for the trailing axis labels.
    private func healthScaleToCapacity(_ y: Double) -> Int {
        let h = chartHealthDomain, c = chartCapacityDomain
        let cLo = Double(c.lowerBound), cHi = Double(c.upperBound)
        let hLo = Double(h.lowerBound), hHi = Double(h.upperBound)
        guard hHi > hLo else { return c.lowerBound }
        return Int((cLo + (y - hLo) / (hHi - hLo) * (cHi - cLo)).rounded())
    }

    /// Entry whose cycle count is closest to `cycle` (the hovered x position).
    private func nearestEntry(toCycle cycle: Int) -> HistoryEntry? {
        history.entries.min(by: { abs($0.cycleCount - cycle) < abs($1.cycleCount - cycle) })
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

    // Health uses both color AND a distinct SF Symbol so the state is not conveyed
    // by color alone (M2). orange instead of yellow for the mid tier (L6 contrast).
    private var healthColor: Color {
        if battery.healthPercent > 80 { return .green }
        if battery.healthPercent > 50 { return .orange }
        return .red
    }

    private var healthIcon: String {
        if battery.healthPercent > 80 { return "heart.fill" }
        if battery.healthPercent > 50 { return "heart" }
        return "heart.slash.fill"
    }

    private var healthDescription: String {
        if battery.healthPercent > 80 { return "good" }
        if battery.healthPercent > 50 { return "fair" }
        return "poor"
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

/// An `info.circle` icon that reveals help text in a popover on click (reliable,
/// unlike `.help()` which only shows a slow hover tooltip and ignores clicks).
/// The hover tooltip is kept too, as a bonus for users who do hover.
private struct InfoButton: View {
    let text: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.caption)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 240)
        }
    }
}
