import SwiftUI

/// Compact label rendered in the menu bar. The state icon is always visible;
/// battery percentage text is an opt-in preference.
struct MenuBarLabel: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
            if settings.showBatteryPercentageInMenuBar {
                Text("\(battery.percentage)%")
            }
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
        case .testing: return "hourglass"
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
    @ObservedObject var system: SystemMonitor
    @ObservedObject var settings: AppSettings

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(battery.percentage)%")
                    .font(.largeTitle.weight(.semibold))
                    .fontDesign(.rounded)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(engine.state.rawValue)
                        .font(.caption).fontWeight(.semibold)
                        .foregroundColor(engine.state.color)
                    Text(phaseTargetText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            Grid(horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    metric(title: "CPU", value: cpuText, icon: "cpu")
                    metric(title: "Temperature", value: temperatureText,
                           icon: "thermometer.medium")
                }
                GridRow {
                    metric(title: "Battery power", value: powerText, icon: "bolt")
                    metric(title: etaTitle, value: etaText, icon: "clock")
                }
                GridRow {
                    metric(title: "Health", value: healthText, icon: "heart")
                    metric(title: "Cycles", value: "\(battery.cycleCount)",
                           icon: "arrow.triangle.2.circlepath")
                }
            }

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
        .frame(width: 280)
    }

    private func metric(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cpuText: String {
        String(format: "%.0f%%", system.cpuUsage)
    }

    private var temperatureText: String {
        guard battery.temperature > 0 else { return "—" }
        return String(format: "%.1f°C", battery.temperature)
    }

    private var powerText: String {
        guard system.powerWatts > 0 else { return "—" }
        return String(format: "%.1f W", system.powerWatts)
    }

    private var healthText: String {
        battery.healthReadFailed || battery.healthPercent <= 0
            ? "—" : "\(battery.healthPercent)%"
    }

    private var etaTitle: String {
        switch engine.state {
        case .charging: return "Charge ETA"
        case .draining: return "Drain ETA"
        case .idle, .testing: return "Cycle ETA"
        }
    }

    private var phaseTargetText: String {
        switch engine.state {
        case .charging: return "to \(Int(settings.effectiveUpperThreshold))%"
        case .draining: return "to \(Int(settings.effectiveLowerThreshold))%"
        case .testing: return "verifying outlet"
        case .idle: return battery.isPluggedIn ? "plugged in" : "on battery"
        }
    }

    /// Estimate time to the active threshold from remaining battery capacity and
    /// instantaneous battery power. It intentionally reports "Calculating" when
    /// macOS has not supplied enough telemetry instead of inventing a duration.
    private var etaText: String {
        guard engine.isRunning else { return "—" }

        let targetPercent: Double
        let remainingMAh: Double
        let fullCapacity = Double(battery.fullChargeCapacityMAh)
        guard fullCapacity > 0, battery.voltage > 0, system.powerWatts >= 0.5 else {
            return "Calculating…"
        }

        let currentCapacity = battery.currentCapacityMAh > 0
            ? Double(battery.currentCapacityMAh)
            : fullCapacity * Double(battery.percentage) / 100

        switch engine.state {
        case .charging:
            guard battery.isPluggedIn else { return "Waiting for AC" }
            targetPercent = settings.effectiveUpperThreshold
            remainingMAh = max(0, fullCapacity * targetPercent / 100 - currentCapacity)
        case .draining:
            guard !battery.isPluggedIn else { return "Waiting to drain" }
            targetPercent = settings.effectiveLowerThreshold
            remainingMAh = max(0, currentCapacity - fullCapacity * targetPercent / 100)
        case .idle, .testing:
            return "—"
        }

        let currentMA = system.powerWatts / battery.voltage * 1_000
        guard currentMA > 0 else { return "Calculating…" }
        let minutes = max(1, Int((remainingMAh / currentMA * 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
