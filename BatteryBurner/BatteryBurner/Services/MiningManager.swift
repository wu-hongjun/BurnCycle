import Foundation

@MainActor
final class MiningManager: ObservableObject {
    @Published var isMining: Bool = false
    @Published var hashrate: String = "0 H/s"
    @Published var status: String = "Idle"

    private var process: Process?
    private var logTimer: Timer?
    private var lastLogOffset: UInt64 = 0
    private let logPath = NSTemporaryDirectory() + "battery_burner_xmrig.log"

    func start(xmrigPath: String, poolURL: String, wallet: String, threads: Int) {
        guard !isMining else { return }

        // Clear old log
        FileManager.default.createFile(atPath: logPath, contents: nil)
        lastLogOffset = 0

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: xmrigPath)
        proc.arguments = [
            "--url", poolURL,
            "--user", wallet,
            "--threads", "\(threads)",
            "--no-color",
            "--print-time", "5",
            "--tls",
            "--log-file", logPath
        ]

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.logTimer?.invalidate()
                self?.logTimer = nil
                self?.isMining = false
                self?.hashrate = "0 H/s"
                self?.status = "Stopped"
            }
        }

        do {
            try proc.run()
            process = proc
            isMining = true
            status = "Starting..."

            // Poll the log file every 2 seconds
            logTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.readLog()
                }
            }
        } catch {
            isMining = false
            status = "Failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        logTimer?.invalidate()
        logTimer = nil
        guard let proc = process, proc.isRunning else {
            isMining = false
            return
        }
        proc.terminate()
        process = nil
        isMining = false
        hashrate = "0 H/s"
        status = "Stopped"
    }

    private func readLog() {
        guard let handle = FileHandle(forReadingAtPath: logPath) else { return }
        defer { handle.closeFile() }

        handle.seek(toFileOffset: lastLogOffset)
        let data = handle.readDataToEndOfFile()
        lastLogOffset = handle.offsetInFile

        guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }

        let lines = output.components(separatedBy: "\n")
        for line in lines where !line.isEmpty {
            if line.contains("speed") && line.contains("H/s") {
                // Format: "speed 10s/60s/15m 1234.5 1200.0 1190.0 H/s"
                if let speedRange = line.range(of: #"speed\s+\S+\s+([\d.]+)"#, options: .regularExpression) {
                    let match = line[speedRange]
                    if let numRange = match.range(of: #"[\d.]+$"#, options: .regularExpression) {
                        let numStr = String(match[numRange])
                        if let value = Double(numStr) {
                            if value >= 1000 {
                                hashrate = String(format: "%.1f kH/s", value / 1000)
                            } else {
                                hashrate = String(format: "%.1f H/s", value)
                            }
                            status = "Mining"
                        }
                    }
                }
            } else if line.contains("new job") {
                status = "Mining"
            } else if line.contains("login") {
                status = "Connecting..."
            } else if line.contains("connect error") {
                let msg = line.components(separatedBy: "connect error:").last?
                    .trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\""))) ?? "Connection failed"
                status = "Error: \(msg)"
            } else if line.contains("READY") {
                status = "Ready"
            }
        }
    }

    deinit {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
    }
}
