import SwiftUI

@main
struct BatteryBurnerApp: App {
    @StateObject private var battery = BatteryMonitor()
    @StateObject private var charging = ChargingController()
    @StateObject private var mining = MiningManager()
    @StateObject private var gpuStresser = GPUStresser()
    @StateObject private var aneStresser = ANEStresser()
    @StateObject private var settings = AppSettings()
    @StateObject private var system = SystemMonitor()
    @State private var engine: CycleEngine?
    @State private var nativeMiner: NativeMiner?

    private let maxThreads = ProcessInfo.processInfo.processorCount

    var body: some Scene {
        WindowGroup {
            if let engine = engine, let nativeMiner = nativeMiner {
                PopoverView(
                    battery: battery,
                    engine: engine,
                    mining: mining,
                    nativeMiner: nativeMiner,
                    gpuStresser: gpuStresser,
                    aneStresser: aneStresser,
                    charging: charging,
                    system: system,
                    settings: settings,
                    maxThreads: maxThreads
                )
            } else {
                ProgressView()
                    .onAppear {
                        let nm = NativeMiner(gpuStresser: gpuStresser, aneStresser: aneStresser)
                        nativeMiner = nm
                        let eng = CycleEngine(
                            battery: battery,
                            charging: charging,
                            mining: mining,
                            nativeMiner: nm,
                            gpuStresser: gpuStresser,
                            aneStresser: aneStresser,
                            settings: settings
                        )
                        engine = eng
                        system.startMonitoring()
                    }
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 600)
    }
}
