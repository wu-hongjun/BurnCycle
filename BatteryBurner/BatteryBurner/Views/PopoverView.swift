import SwiftUI

struct PopoverView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var gpuStresser: GPUStresser
    @ObservedObject var aneStresser: ANEStresser
    @ObservedObject var charging: ChargingController
    @ObservedObject var system: SystemMonitor
    @ObservedObject var settings: AppSettings
    let maxThreads: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusSection(battery: battery, engine: engine, mining: mining,
                         gpuStresser: gpuStresser, aneStresser: aneStresser,
                         charging: charging, system: system)

            Divider()

            ControlsSection(engine: engine, mining: mining,
                          gpuStresser: gpuStresser, aneStresser: aneStresser,
                          settings: settings)

            Divider()

            SettingsSection(settings: settings, charging: charging, maxThreads: maxThreads)

            Divider()

            Button("Quit") {
                engine.stop()
                NSApplication.shared.terminate(nil)
            }
            .foregroundColor(.secondary)
            .font(.caption)
        }
        .padding()
        .frame(width: 360)
    }
}
