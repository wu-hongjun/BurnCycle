import SwiftUI
import Combine

@main
struct BurnCycleApp: App {
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var charging = ChargingController()
    @StateObject private var mining = MiningManager()
    @StateObject private var stress = StressManager()
    @StateObject private var settings = AppSettings()
    @StateObject private var system = SystemMonitor()
    @StateObject private var history = HistoryRecorder()
    @State private var engine: CycleEngine?
    @State private var historyObserver: AnyCancellable?

    var body: some Scene {
        WindowGroup {
            if let engine = engine {
                MainView(
                    battery: battery,
                    engine: engine,
                    mining: mining,
                    stress: stress,
                    charging: charging,
                    system: system,
                    settings: settings,
                    history: history
                )
            } else {
                ProgressView()
                    .onAppear {
                        engine = CycleEngine(
                            battery: battery,
                            charging: charging,
                            mining: mining,
                            stress: stress,
                            system: system,
                            settings: settings
                        )
                        battery.startMonitoring()
                        system.startMonitoring()

                        // Record history snapshots whenever battery slow values change
                        historyObserver = battery.$cycleCount
                            .combineLatest(battery.$healthPercent, battery.$fullChargeCapacityMAh)
                            .sink { cycle, health, capacity in
                                Task { @MainActor in
                                    history.observe(cycleCount: cycle,
                                                    fullChargeCapacityMAh: capacity,
                                                    healthPercent: health)
                                }
                            }
                    }
            }
        }
        .windowResizability(.contentSize)
    }
}
