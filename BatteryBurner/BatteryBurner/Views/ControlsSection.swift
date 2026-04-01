import SwiftUI

struct ControlsSection: View {
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            Button(engine.isRunning ? "Stop" : "Start") {
                if engine.isRunning {
                    engine.stop()
                } else {
                    engine.start()
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRunning ? .red : .green)

            if engine.isRunning {
                Button(engine.state == .paused ? "Resume" : "Pause") {
                    if engine.state == .paused {
                        engine.resume()
                    } else {
                        engine.pause()
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button(mining.isMining ? "Stop Mining" : "Test Mining") {
                if mining.isMining {
                    mining.stop()
                } else {
                    mining.start(
                        xmrigPath: settings.xmrigPath,
                        poolURL: settings.poolURL,
                        wallet: settings.walletAddress,
                        threads: settings.threadCount,
                        useGPU: settings.useGPU
                    )
                }
            }
            .buttonStyle(.bordered)
            .tint(mining.isMining ? .orange : .blue)
            .disabled(settings.walletAddress.isEmpty)
        }
    }
}
