import Foundation

@MainActor
final class ChargingController: ObservableObject {
    @Published var lastAction: String = "None"
    @Published var isRunningShortcut: Bool = false
    @Published var outletOn: Bool = false
    @Published var lastError: String?

    private var lastActionTime: Date = .distantPast
    private let cooldown: TimeInterval = 30

    func startCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "Start Charging", skipCooldown: false)
    }

    func stopCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "Stop Charging", skipCooldown: false)
    }

    func testStartCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "Start Charging", skipCooldown: true)
    }

    func testStopCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "Stop Charging", skipCooldown: true)
    }

    private func runShortcut(name: String, action: String, skipCooldown: Bool) {
        let now = Date()
        if !skipCooldown {
            guard now.timeIntervalSince(lastActionTime) >= cooldown else { return }
        }
        guard !isRunningShortcut else { return }

        lastActionTime = now
        isRunningShortcut = true
        lastError = nil

        Task.detached { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]

            let errPipe = Pipe()
            process.standardError = errPipe

            let succeeded: Bool
            let errorOutput: String?

            do {
                try process.run()
                process.waitUntilExit()
                let ok = process.terminationStatus == 0
                if !ok {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    errorOutput = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    errorOutput = nil
                }
                succeeded = ok
            } catch {
                succeeded = false
                errorOutput = error.localizedDescription
            }

            let didSucceed = succeeded
            let errMsg = errorOutput

            await MainActor.run {
                guard let self else { return }
                self.isRunningShortcut = false
                if didSucceed {
                    self.lastAction = action
                    self.lastError = nil
                    self.outletOn = (action == "Start Charging")
                } else {
                    self.lastError = errMsg ?? "Shortcut failed"
                }
            }
        }
    }
}
