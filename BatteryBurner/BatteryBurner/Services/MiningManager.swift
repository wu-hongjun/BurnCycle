import Foundation

@MainActor
final class MiningManager: ObservableObject {
    @Published var isMining: Bool = false
    @Published var hashrate: String = "0 H/s"

    private var process: Process?
    private var outputPipe: Pipe?

    func start(xmrigPath: String, poolURL: String, wallet: String, threads: Int) {
        guard !isMining else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: xmrigPath)
        proc.arguments = [
            "--url", poolURL,
            "--user", wallet,
            "--threads", "\(threads)",
            "--no-color",
            "--print-time", "30"
        ]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            self?.parseHashrate(from: line)
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.isMining = false
                self?.hashrate = "0 H/s"
            }
        }

        do {
            try proc.run()
            process = proc
            outputPipe = pipe
            isMining = true
        } catch {
            isMining = false
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            isMining = false
            return
        }
        proc.terminate()
        process = nil
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        isMining = false
        hashrate = "0 H/s"
    }

    private nonisolated func parseHashrate(from output: String) {
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            if line.contains("speed") && line.contains("H/s") {
                if let range = line.range(of: #"\d+\.?\d*\s*[kMG]?H/s"#, options: .regularExpression) {
                    let parsed = String(line[range])
                    Task { @MainActor [weak self] in
                        self?.hashrate = parsed
                    }
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
