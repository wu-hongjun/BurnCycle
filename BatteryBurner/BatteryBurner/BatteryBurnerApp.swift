import SwiftUI

@main
struct BatteryBurnerApp: App {
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var charging = ChargingController()
    @StateObject private var mining = MiningManager()
    @StateObject private var settings = AppSettings()
    @StateObject private var system = SystemMonitor()
    @State private var engine: CycleEngine?

    private let maxThreads = ProcessInfo.processInfo.processorCount

    var body: some Scene {
        WindowGroup {
            if let engine = engine {
                PopoverView(
                    battery: battery,
                    engine: engine,
                    mining: mining,
                    charging: charging,
                    system: system,
                    settings: settings,
                    maxThreads: maxThreads
                )
            } else {
                ProgressView()
                    .onAppear {
                        engine = CycleEngine(
                            battery: battery,
                            charging: charging,
                            mining: mining,
                            settings: settings
                        )
                        battery.update()
                        system.startMonitoring()
                    }
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 340, height: 500)
    }
}
