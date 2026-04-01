import SwiftUI

struct SettingsSection: View {
    @ObservedObject var settings: AppSettings
    let maxThreads: Int

    var body: some View {
        DisclosureGroup("Settings") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading) {
                    Text("Upper Threshold: \(Int(settings.upperThreshold))%")
                    Slider(value: $settings.upperThreshold, in: 50...100, step: 5)
                }

                VStack(alignment: .leading) {
                    Text("Lower Threshold: \(Int(settings.lowerThreshold))%")
                    Slider(value: $settings.lowerThreshold, in: 5...50, step: 5)
                }

                Divider()

                VStack(alignment: .leading) {
                    Text("Wallet Address")
                    TextField("XMR wallet address", text: $settings.walletAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }

                VStack(alignment: .leading) {
                    Text("Pool URL")
                    TextField("pool:port", text: $settings.poolURL)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading) {
                    Text("Threads: \(settings.threadCount)")
                    Slider(value: Binding(
                        get: { Double(settings.threadCount) },
                        set: { settings.threadCount = Int($0) }
                    ), in: 1...Double(maxThreads), step: 1)
                }

                Divider()

                VStack(alignment: .leading) {
                    Text("Start Charging Shortcut")
                    TextField("Shortcut name", text: $settings.startChargingShortcut)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading) {
                    Text("Stop Charging Shortcut")
                    TextField("Shortcut name", text: $settings.stopChargingShortcut)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading) {
                    Text("XMRig Path")
                    TextField("/opt/homebrew/bin/xmrig", text: $settings.xmrigPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }
}
