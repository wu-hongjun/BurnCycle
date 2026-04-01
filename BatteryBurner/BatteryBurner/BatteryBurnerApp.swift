import SwiftUI

@main
struct BatteryBurnerApp: App {
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var charging = ChargingController()
    @StateObject private var mining = MiningManager()
    @StateObject private var settings = AppSettings()
    @State private var engine: CycleEngine?

    private let maxThreads = ProcessInfo.processInfo.processorCount

    var body: some Scene {
        MenuBarExtra("Battery Burner", systemImage: menuBarIcon) {
            if let engine = engine {
                PopoverView(
                    battery: battery,
                    engine: engine,
                    mining: mining,
                    settings: settings,
                    maxThreads: maxThreads
                )
            } else {
                ProgressView()
                    .onAppear {
                        let eng = CycleEngine(
                            battery: battery,
                            charging: charging,
                            mining: mining,
                            settings: settings
                        )
                        engine = eng
                    }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        guard let engine = engine else { return "battery.100" }
        switch engine.state {
        case .charging: return "battery.100.bolt"
        case .draining: return "battery.50"
        case .paused: return "battery.75"
        case .idle: return "battery.100"
        }
    }
}
