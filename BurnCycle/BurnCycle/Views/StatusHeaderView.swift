import SwiftUI

/// Top status rows extracted from MainView: battery (percentage/health/cycles),
/// system (state/CPU/GPU/power), and the conditional load-status line. The
/// presentation helpers below format each value. The three rows are arranged in
/// a `VStack(spacing: 10)` so the spacing matches the parent column they came from.
struct StatusHeaderView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var stress: StressManager
    @ObservedObject var charging: ChargingController
    @ObservedObject var system: SystemMonitor

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
