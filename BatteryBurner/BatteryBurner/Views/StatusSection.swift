import SwiftUI

struct StatusSection: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var gpuStresser: GPUStresser
    @ObservedObject var aneStresser: ANEStresser
    @ObservedObject var charging: ChargingController
    @ObservedObject var system: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Battery")
                    .font(.headline)
                Spacer()
                Text("\(battery.percentage)%")
                    .font(.title2)
                    .fontWeight(.bold)
            }

            ProgressView(value: Double(battery.percentage), total: 100)
                .tint(batteryColor)

            HStack {
                Text("State:")
                Text(engine.state.rawValue)
                    .fontWeight(.semibold)
                    .foregroundColor(stateColor)
            }

            HStack {
                Text("Outlet:")
                HStack(spacing: 4) {
                    Circle()
                        .fill(charging.outletOn ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(charging.outletOn ? "ON" : "OFF")
                        .fontWeight(.medium)
                        .foregroundColor(charging.outletOn ? .green : .orange)
                }
                if charging.isRunningShortcut {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                }
                Spacer()
                Text("Mining:")
                HStack(spacing: 4) {
                    Circle()
                        .fill(mining.isMining ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(mining.isMining ? (mining.hashrate != "0 H/s" ? mining.hashrate : mining.status) : "Off")
                        .fontWeight(.medium)
                        .foregroundColor(mining.isMining ? .green : .secondary)
                }
            }

            if let error = charging.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Text("GPU:")
                HStack(spacing: 4) {
                    Circle()
                        .fill(gpuStresser.isRunning ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(gpuStresser.isRunning ? gpuStresser.status : "Off")
                        .fontWeight(.medium)
                        .foregroundColor(gpuStresser.isRunning ? .green : .secondary)
                }
                Spacer()
                Text("ANE:")
                HStack(spacing: 4) {
                    Circle()
                        .fill(aneStresser.isRunning ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(aneStresser.isRunning ? aneStresser.status : "Off")
                        .fontWeight(.medium)
                        .foregroundColor(aneStresser.isRunning ? .green : .secondary)
                }
            }

            HStack {
                Text("CPU:")
                Text(String(format: "%.0f%%", system.cpuUsage))
                    .fontWeight(.medium)
                Spacer()
                Text("Draw:")
                Text(String(format: "%.1f W", system.powerWatts))
                    .fontWeight(.medium)
            }

            if engine.cycleCount > 0 {
                HStack {
                    Text("Cycles:")
                    Text("\(engine.cycleCount)")
                }
            }
        }
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
}
