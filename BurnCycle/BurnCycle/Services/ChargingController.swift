import Foundation

@MainActor
final class ChargingController: ObservableObject {
    @Published var isRunningShortcut: Bool = false
    @Published var lastError: String?

    private var lastStartTime: Date = .distantPast
    private var lastStopTime: Date = .distantPast
    private let cooldown: TimeInterval = 30

    /// Start charging — safety-critical, bypasses cooldown
    func startCharging(shortcutName: String, force: Bool = false) {
        runShortcut(name: shortcutName, action: "start", skipCooldown: force)
    }

    func stopCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "stop", skipCooldown: false)
    }

    func testStartCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "start", skipCooldown: true)
    }

    func testStopCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "stop", skipCooldown: true)
    }

    private func runShortcut(name: String, action: String, skipCooldown: Bool) {
        let now = Date()
        if !skipCooldown {
            // Per-action cooldown so start and stop don't block each other
            let lastTime = action == "start" ? lastStartTime : lastStopTime
            guard now.timeIntervalSince(lastTime) >= cooldown else { return }
        }
        guard !isRunningShortcut else { return }

        if action == "start" { lastStartTime = now } else { lastStopTime = now }
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
                    self.lastError = nil
                } else {
                    self.lastError = errMsg ?? "Shortcut failed"
                }
            }
        }
    }
}
