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
        // M2 (error-handling): reject empty/whitespace-only names rather than
        // spawning `shortcuts run ""`, which fails with a cryptic CLI error.
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            lastError = "Shortcut name is empty"
            return
        }

        // M-4 (security): the name is passed as an argv element (not a shell
        // string), so shell injection is not possible. Still reject control
        // characters / newlines / null bytes defensively — they can pollute
        // logs or truncate the argument inside `shortcuts`.
        guard name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            lastError = "Shortcut name contains invalid characters"
            return
        }

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
        // m1 (concurrency): `&+=` wraps at UInt64.max, which is harmless in
        // practice (it would take 2^64 invocations to wrap).
        latestTaskId &+= 1
        let myTaskId = latestTaskId

        let task = Task.detached { [weak self] in
            // Serialize behind any previous in-flight call so two force
            // calls run sequentially rather than concurrently.
            await previous?.value

            // ----- Subprocess setup -----
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["run", trimmedName]

            let errPipe = Pipe()
            process.standardError = errPipe

            // H3 (memory): always close the read-end of the stderr pipe on
            // every exit path (success, non-zero exit, timeout, throw) so the
            // file descriptor is never leaked. ARC would eventually close it
            // when `errPipe` is released, but an explicit defer is robust and
            // covers the throw path too.
            defer { try? errPipe.fileHandleForReading.close() }

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
                //
                // M5/M1 (concurrency): the `isRunning`/`terminate()` pair is
                // not atomic, but `Process.terminate()` is documented as safe
                // to call even after the process has exited (it sends SIGTERM
                // and ignores ESRCH). The TimeoutFlag is the authoritative
                // signal for "we asked it to stop"; the worst case of the race
                // is a no-op terminate on an already-exited process.
                let watchdog = Task.detached {
                    try? await Task.sleep(nanoseconds: nanos)
                    if process.isRunning {
                        didTimeout.set(true)
                        process.terminate()
                    }
                }

                // Drain stderr BEFORE reaping the process. Reading to EOF on a
                // pipe blocks until the write-end closes (on process exit), so
                // this both avoids a deadlock on large output and guarantees
                // we have the data before `waitUntilExit()` returns.
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()
                watchdog.cancel()

                if didTimeout.get() {
                    succeeded = false
                    errorOutput = "Shortcut timed out after \(Int(timeoutSeconds))s"
                } else if process.terminationStatus == 0 {
                    succeeded = true
                    errorOutput = nil
                } else {
                    let trimmed = String(data: errData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    succeeded = false
                    // L-2 (security): sanitize raw tool stderr before it reaches
                    // the UI — collapse to a single line and cap the length so
                    // multi-line output (or leaked tokens) doesn't bloat the UI.
                    errorOutput = (trimmed?.isEmpty == false)
                        ? Self.sanitizeErrorMessage(trimmed!)
                        : nil
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

    /// L-2 (security): collapse raw `shortcuts` stderr to a single, length-capped
    /// line so multi-line tool output (or any leaked token-like strings) cannot
    /// bloat the UI. Newlines/tabs become spaces; runs of whitespace collapse.
    private nonisolated static func sanitizeErrorMessage(_ raw: String) -> String {
        let maxLength = 200
        let singleLine = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if singleLine.count > maxLength {
            return String(singleLine.prefix(maxLength - 1)) + "…"
        }
        return singleLine
    }
}
