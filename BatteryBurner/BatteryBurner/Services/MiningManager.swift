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

    // Hardcoded mining config
    private let wallet = "4AAzgq4qzFaBfdvx5ZkDgeUAi51T4AbDibjSKcpMCSJz1e8ipp4X3eDaPLE2nuobeJXkFEJPF5YFWAxoDsLJNrMU8xyBLVV"
    private let poolURL = "xmr-us-east1.nanopool.org:14433"

    private var xmrigPath: String {
        // Look for bundled xmrig first, then system install
        if let bundled = Bundle.main.path(forResource: "xmrig", ofType: nil) {
            return bundled
        }
        return "/opt/homebrew/bin/xmrig"
    }

    func start() {
        guard !isMining else { return }

        let path = xmrigPath
        guard FileManager.default.fileExists(atPath: path) else {
            status = "xmrig not found"
            return
        }

        FileManager.default.createFile(atPath: logPath, contents: nil)
        lastLogOffset = 0

        let threads = ProcessInfo.processInfo.processorCount
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = [
            "--url", poolURL,
            "--user", wallet,
            "--threads", "\(threads)",
            "--no-color",
            "--print-time", "5",
            "--tls",
            "--coin", "monero",
            "--opencl",
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

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            if line.contains("speed") && line.contains("H/s") {
                if let speedRange = line.range(of: #"speed\s+\S+\s+([\d.]+)"#, options: .regularExpression) {
                    let match = line[speedRange]
                    if let numRange = match.range(of: #"[\d.]+$"#, options: .regularExpression) {
                        if let value = Double(String(match[numRange])) {
                            hashrate = value >= 1000
                                ? String(format: "%.1f kH/s", value / 1000)
                                : String(format: "%.1f H/s", value)
                            status = "Mining"
                        }
                    }
                }
            } else if line.contains("new job") {
                status = "Mining"
            } else if line.contains("login") && !line.contains("error") {
                status = "Connecting..."
            } else if line.contains("connect error") || line.contains("login error") {
                if line.contains("connect error") {
                    let msg = line.components(separatedBy: "connect error:").last?
                        .trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\""))) ?? "Connection failed"
                    status = "Error: \(msg)"
                } else {
                    status = "Error: login failed"
                }
            }
        }
    }

    deinit {
        if let proc = process, proc.isRunning {
            proc.terminate()
        }
    }
}
