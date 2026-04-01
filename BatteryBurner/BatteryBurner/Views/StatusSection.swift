import SwiftUI

struct StatusSection: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager

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

            if mining.isMining {
                HStack {
                    Text("Hashrate:")
                    Text(mining.hashrate)
                        .fontWeight(.medium)
                }
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
