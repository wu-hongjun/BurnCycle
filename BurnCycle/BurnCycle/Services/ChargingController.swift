import Foundation

/// Thread-safe boolean flag used to coordinate the watchdog and the
/// task that owns the subprocess. Both sides may read/write from
/// different threads (the watchdog runs on a detached Task, the
/// subprocess wait blocks the owning task), so we need a lock.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
final class ChargingController: ObservableObject {
    /// UI signal only — does NOT gate concurrent calls. Use `inflight` for
    /// queueing decisions. Cleared when the most-recent task completes.
    @Published var isRunningShortcut: Bool = false
    @Published var lastError: String?

    private var lastStartTime: Date = .distantPast
    private var lastStopTime: Date = .distantPast
    private let cooldown: TimeInterval = 30

    /// Timeout for an individual `shortcuts run` invocation. `shortcuts`
    /// usually fails fast (≤5s) on CoAP errors and rarely takes more than
    /// ~10s on success, so 20s is a comfortable upper bound.
    private let shortcutTimeoutSeconds: TimeInterval = 20

    /// Serial chain of in-flight shortcut tasks. A new task awaits the
    /// previous one before running, so force calls are queued (never
    /// dropped) when another shortcut is already executing.
    private var inflight: Task<Void, Never>?

    /// Monotonically increasing identifier for each enqueued task. The
    /// most-recent task is the one whose id matches `latestTaskId`; only
    /// that task clears the UI signal and `inflight` on completion.
    private var latestTaskId: UInt64 = 0

    /// Start charging — safety-critical, bypasses cooldown AND in-flight guard
    func startCharging(shortcutName: String, force: Bool = false) {
        runShortcut(name: shortcutName, action: "start", force: force)
    }

    func stopCharging(shortcutName: String, force: Bool = false) {
        runShortcut(name: shortcutName, action: "stop", force: force)
    }

    func testStartCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "start", force: true)
    }

    func testStopCharging(shortcutName: String) {
        runShortcut(name: shortcutName, action: "stop", force: true)
    }

    private func runShortcut(name: String, action: String, force: Bool) {
        let now = Date()

        // Non-force calls respect both the cooldown window AND the
        // "don't stack redundant work" guard. Force calls bypass both:
        // they are always enqueued onto the serial chain so they cannot
        // be silently dropped (this is the entire safety contract).
        if !force {
            let lastTime = action == "start" ? lastStartTime : lastStopTime
            guard now.timeIntervalSince(lastTime) >= cooldown else { return }
            guard inflight == nil else { return }
        }

        // Capture the previous task so the new one can serialize behind it.
        let previous = inflight

        // Update UI signal immediately so the user sees activity even if
        // we're queued behind another task. It will be cleared when the
        // most-recent task in the chain finishes.
        isRunningShortcut = true
        lastError = nil

        let timeoutSeconds = shortcutTimeoutSeconds

        // Each task gets a unique id so on completion it can detect
        // whether it is still the most-recent task in the chain (and
        // therefore the one responsible for clearing UI state).
        latestTaskId &+= 1
        let myTaskId = latestTaskId

        let task = Task.detached { [weak self] in
            // Serialize behind any previous in-flight call so two force
            // calls run sequentially rather than concurrently.
            await previous?.value

            // ----- Subprocess setup -----
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", name]

            let errPipe = Pipe()
            process.standardError = errPipe

            // ----- Watchdog: terminate the process if it hangs -----
            let didTimeout = TimeoutFlag()
            let nanos = UInt64(timeoutSeconds * 1_000_000_000)

            let succeeded: Bool
            let errorOutput: String?

            do {
                try process.run()

                // Spawn the watchdog only AFTER the process is running.
                // It does not capture `self`, only the local `process`
                // and `didTimeout` flag, so it cannot keep the
                // controller alive.
                let watchdog = Task.detached {
                    try? await Task.sleep(nanoseconds: nanos)
                    if process.isRunning {
                        didTimeout.set(true)
                        process.terminate()
                    }
                }

                process.waitUntilExit()
                watchdog.cancel()

                if didTimeout.get() {
                    succeeded = false
                    errorOutput = "Shortcut timed out after \(Int(timeoutSeconds))s"
                } else if process.terminationStatus == 0 {
                    succeeded = true
                    errorOutput = nil
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let trimmed = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    succeeded = false
                    errorOutput = (trimmed?.isEmpty == false) ? trimmed : nil
                }
            } catch {
                succeeded = false
                errorOutput = error.localizedDescription
            }

            let didSucceed = succeeded
            let errMsg = errorOutput

            await MainActor.run {
                guard let self else { return }

                // Cooldown is recorded ONLY on actual successful invocation.
                // A failed call (CoAP error, timeout, etc.) does not burn
                // the cooldown window — the user can retry immediately.
                if didSucceed {
                    let stamp = Date()
                    if action == "start" {
                        self.lastStartTime = stamp
                    } else {
                        self.lastStopTime = stamp
                    }
                    self.lastError = nil
                } else {
                    self.lastError = errMsg ?? "Shortcut failed"
                }

                // Only the most-recent task in the chain clears the UI
                // flag and the inflight pointer. If another task was
                // enqueued behind us (latestTaskId moved on), leave
                // isRunningShortcut = true and let that task be the one
                // to clear things.
                if myTaskId == self.latestTaskId {
                    self.inflight = nil
                    self.isRunningShortcut = false
                }
            }
        }

        inflight = task
    }
}
