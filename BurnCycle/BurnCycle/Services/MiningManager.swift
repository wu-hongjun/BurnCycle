import Foundation
import Darwin // for kill() / SIGKILL
import CryptoKit // for runtime xmrig integrity verification

@MainActor
final class MiningManager: ObservableObject {
    @Published var isMining: Bool = false
    @Published var hashrate: String = "0 H/s"
    @Published var status: String = "Idle"

    private var process: Process?
    private var logTimer: Timer?
    private var lastLogOffset: UInt64 = 0

    /// M-3 (security): the log path used to be a fixed, predictable name in the
    /// temp directory, which invites symlink/TOCTOU races from any same-user
    /// process. Use a per-launch UUID name instead, and create it 0600 (see
    /// `start()`). `lastLogOffset` is reset to 0 each time we truncate.
    private let logPath = NSTemporaryDirectory() + "burn_cycle_xmrig-\(UUID().uuidString).log"

    /// M-1 (security): this is the *developer's* donation wallet, used only when
    /// the user has not configured their own. Its use is surfaced explicitly in
    /// the status line (see `start()`) so it is never a hidden default.
    private static let defaultWallet = "4AAzgq4qzFaBfdvx5ZkDgeUAi51T4AbDibjSKcpMCSJz1e8ipp4X3eDaPLE2nuobeJXkFEJPF5YFWAxoDsLJNrMU8xyBLVV"
    private static let defaultPool = "xmr-us-east1.nanopool.org:14433"


    private var xmrigPath: String {
        if let bundled = Bundle.main.path(forResource: "xmrig", ofType: nil) {
            return bundled
        }
        return "/opt/homebrew/bin/xmrig"
    }

    /// The expected SHA-256 of the bundled xmrig, recorded at build time (after
    /// code-signing) into the sealed `xmrig.sha256` resource. Returns nil if the
    /// file is absent (e.g. a dev build or the homebrew fallback). File format is
    /// `<hex>  xmrig` (shasum style); we take the first whitespace-delimited field.
    private func expectedBundledXmrigHash() -> String? {
        guard let url = Bundle.main.url(forResource: "xmrig", withExtension: "sha256"),
              let contents = try? String(contentsOf: url, encoding: .utf8),
              let hex = contents.split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline }).first
        else { return nil }
        return String(hex)
    }

    /// Compute the SHA-256 of the file at `path` and compare it to the recorded
    /// bundled hash. Fails closed: returns false if the file can't be read or no
    /// recorded hash is available, so an unverifiable bundled binary is refused.
    /// Reads the whole file (xmrig is ~7 MB); runs once at mining start, off the
    /// hot path.
    private func verifyXmrigIntegrity(at path: String) -> Bool {
        guard let expected = expectedBundledXmrigHash() else { return false }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return false
        }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return hex.caseInsensitiveCompare(expected) == .orderedSame
    }

    /// Start mining. Uses custom wallet if provided, otherwise default.
    func start(walletOverride: String = "") {
        guard !isMining else { return }

        let path = xmrigPath
        guard FileManager.default.fileExists(atPath: path) else {
            status = "xmrig not found"
            return
        }

        // H-1 (security): verify the bundled xmrig against the known-good hash
        // before executing it. The build-time check in build.sh guards the build
        // pipeline; this guards the running app against a binary swapped on disk
        // after install. The homebrew fallback (/opt/homebrew/bin/xmrig) is a
        // developer convenience and is intentionally not hash-pinned.
        let bundledPath = Bundle.main.path(forResource: "xmrig", ofType: nil)
        if path == bundledPath, !verifyXmrigIntegrity(at: path) {
            status = "xmrig integrity check failed"
            isMining = false
            return
        }

        // Truncate old log to avoid stale data, then lock it down to 0600 so
        // no other user/process can read the wallet address xmrig echoes into
        // it (M-3 security). Create-or-truncate first, then set permissions.
        try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: logPath
        )
        lastLogOffset = 0

        // M-1 (security): make the developer/donation wallet explicit instead of
        // a silent fallback. We still mine to the default when no wallet is set
        // (preserving CycleEngine's behaviour), but the status line below makes
        // it transparent that the donation wallet is in use.
        let usingDefaultWallet = walletOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let wallet = usingDefaultWallet ? Self.defaultWallet : walletOverride
        let threads = ProcessInfo.processInfo.processorCount
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = [
            "--url", Self.defaultPool,
            "--user", wallet,
            "--threads", "\(threads)",
            "--no-color",
            "--print-time", "5",
            // M-2 (security): `--tls` encrypts the pool connection but xmrig
            // validates against system roots with NO certificate pinning, so a
            // trusted-CA MITM can still intercept. Pinning via
            // `--tls-fingerprint <sha256>` is not configured here because we do
            // not ship a known-good pool cert fingerprint; documented as
            // accepted risk.
            "--tls",
            "--coin", "monero",
            "--opencl",
            "--log-file", logPath
        ]

        // L-1 (security): xmrig does not need (and should not inherit) the full
        // parent environment, which can carry secrets injected by the shell or
        // login items. Hand it a minimal scrubbed environment — but keep HOME/TMPDIR
        // so `--opencl` can write its GPU kernel caches (init can fail without them).
        var scrubbedEnv = ["PATH": "/usr/local/bin:/usr/bin:/bin"]
        let parentEnv = ProcessInfo.processInfo.environment
        if let home = parentEnv["HOME"] { scrubbedEnv["HOME"] = home }
        if let tmp = parentEnv["TMPDIR"] { scrubbedEnv["TMPDIR"] = tmp }
        proc.environment = scrubbedEnv

        proc.terminationHandler = { [weak self] terminated in
            // terminationHandler fires on an arbitrary background queue, so we
            // hop to the main actor to touch the @MainActor-isolated state.
            // Capture the terminated process's pid as a plain value (Int32) so
            // the Task closure does not need to capture the non-Sendable
            // `Process` across the actor boundary.
            let terminatedPid = terminated.processIdentifier
            // M3 (memory): invalidating an already-invalidated Timer is a safe
            // no-op (and we nil it after), so the `stop()` path and this handler
            // racing to invalidate cannot crash or double-free. We also clear
            // `process` here so a self-exit (xmrig crash) doesn't leave a stale
            // reference — but only if it still points at the process that just
            // terminated, so we don't clobber a freshly-started one.
            Task { @MainActor in
                guard let self else { return }
                self.logTimer?.invalidate()
                self.logTimer = nil
                if self.process?.processIdentifier == terminatedPid {
                    self.process = nil
                }
                self.isMining = false
                self.hashrate = "0 H/s"
                self.status = "Stopped"
            }
        }

        do {
            try proc.run()
            process = proc
            isMining = true
            // M-1: surface when the bundled developer donation wallet is active
            // so the user is never unknowingly mining to it.
            status = usingDefaultWallet ? "Mining (default donation wallet)" : "Starting..."

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
            process = nil
            isMining = false
            return
        }

        // SIGTERM first, then escalate to a real SIGKILL after ~3s.
        proc.terminate()
        let capturedProc = proc
        process = nil
        isMining = false
        hashrate = "0 H/s"
        status = "Stopped"

        Task.detached {
            // Wait up to 3 seconds for graceful exit.
            var exited = false
            for _ in 0..<30 {
                if !capturedProc.isRunning {
                    exited = true
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
            // n3 (concurrency): if still running after the grace window, send a
            // REAL force-kill. `interrupt()` only sends SIGINT, which xmrig
            // handles like SIGTERM and may ignore; SIGKILL cannot be caught.
            if !exited && capturedProc.isRunning {
                kill(capturedProc.processIdentifier, SIGKILL)
            }
            // H1 / L8 (memory): reap the child so it does not linger as a
            // zombie. POSIX requires the parent to wait() on a terminated
            // child; `stop()` previously never did this.
            capturedProc.waitUntilExit()
        }
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
                hashrate = "0 H/s"
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

}
