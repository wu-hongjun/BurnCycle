import SwiftUI

struct MainView: View {
    @ObservedObject var battery: BatteryMonitor
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var stress: StressManager
    @ObservedObject var charging: ChargingController
    @ObservedObject var system: SystemMonitor
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: HistoryRecorder

    @State private var showSettings = false
    @State private var showInfo = false
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 10) {
            // Top status rows: battery, system, and (when active) load status.
            StatusHeaderView(battery: battery, engine: engine, mining: mining,
                             stress: stress, charging: charging, system: system)

            // Prefer the engine's error (orange) as the single source of truth.
            // Only fall back to charging.lastError (red) when the engine has none,
            // to avoid showing duplicate / stale/contradictory error lines.
            if let err = engine.errorMessage {
                Text(err).font(.caption2).foregroundColor(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let error = charging.lastError {
                Text(error).font(.caption2).foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = engine.statusMessage {
                Text(status).font(.caption2).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Controls
            HStack {
                Button("Info") {
                    showInfo.toggle()
                    if showInfo { showSettings = false; showHistory = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("History") {
                    showHistory.toggle()
                    if showHistory { showSettings = false; showInfo = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Settings") {
                    showSettings.toggle()
                    if showSettings { showInfo = false; showHistory = false }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button {
                    if engine.isRunning { engine.stop() } else { engine.start() }
                } label: {
                    Label(engine.isRunning ? "Stop" : "Start",
                          systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(engine.isRunning ? .red : .green)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(engine.isRunning ? "Stop cycling" : "Start cycling")
            }

            // Settings panel
            if showSettings {
                SettingsPanel(settings: settings, charging: charging, engine: engine,
                              mining: mining, stress: stress)
            }

            // Info panel
            if showInfo {
                InfoPanel(battery: battery)
            }

            // History panel
            if showHistory {
                HistoryPanel(history: history)
            }
        }
        .padding(16)
        .frame(minWidth: 320, idealWidth: 320, maxWidth: 420)
    }
}
