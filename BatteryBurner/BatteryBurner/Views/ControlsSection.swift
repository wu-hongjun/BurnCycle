import SwiftUI

struct ControlsSection: View {
    @ObservedObject var engine: CycleEngine

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
        }
    }
}
