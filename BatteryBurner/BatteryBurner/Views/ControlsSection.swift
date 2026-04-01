import SwiftUI

struct ControlsSection: View {
    @ObservedObject var engine: CycleEngine
    @ObservedObject var mining: MiningManager
    @ObservedObject var gpuStresser: GPUStresser
    @ObservedObject var aneStresser: ANEStresser
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 10) {
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
            }

            HStack(spacing: 8) {
                Button(mining.isMining ? "Stop XMR" : "Test XMR") {
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
                .controlSize(.small)
                .disabled(settings.walletAddress.isEmpty)

                Button(gpuStresser.isRunning ? "Stop GPU" : "Test GPU") {
                    if gpuStresser.isRunning {
                        gpuStresser.stop()
                    } else {
                        gpuStresser.start()
                    }
                }
                .buttonStyle(.bordered)
                .tint(gpuStresser.isRunning ? .orange : .purple)
                .controlSize(.small)

                Button(aneStresser.isRunning ? "Stop ANE" : "Test ANE") {
                    if aneStresser.isRunning {
                        aneStresser.stop()
                    } else {
                        aneStresser.start()
                    }
                }
                .buttonStyle(.bordered)
                .tint(aneStresser.isRunning ? .orange : .indigo)
                .controlSize(.small)
            }
        }
    }
}
