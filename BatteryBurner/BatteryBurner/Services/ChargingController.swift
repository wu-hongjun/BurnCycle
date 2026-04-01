import Foundation

@MainActor
final class ChargingController: ObservableObject {
    @Published var lastAction: String = "None"
    @Published var isRunningShortcut: Bool = false

    private var lastActionTime: Date = .distantPast
    private let cooldown: TimeInterval = 30

    func startCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "Start Charging")
    }

    func stopCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "Stop Charging")
    }

    private func runShortcut(name: String, action: String) {
        let now = Date()
        guard now.timeIntervalSince(lastActionTime) >= cooldown else { return }
        guard !isRunningShortcut else { return }

        lastActionTime = now
        isRunningShortcut = true

        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // Shortcut execution failed
            }

            await MainActor.run { [weak self] in
                self?.lastAction = action
                self?.isRunningShortcut = false
            }
        }
    }
}
