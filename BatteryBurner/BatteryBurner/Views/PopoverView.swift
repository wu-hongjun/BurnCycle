import SwiftUI

struct PopoverView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var charging: ChargingController
    @ObservedObject var settings: AppSettings
    let maxThreads: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusSection(battery: battery, engine: engine, mining: mining, charging: charging)

            Divider()

            ControlsSection(engine: engine)

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
        .frame(width: 320)
    }
}
