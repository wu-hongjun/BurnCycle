import Foundation

/// Crash / unexpected-termination failsafe.
///
/// The hazard: if BurnCycle is killed while *draining* (smart outlet commanded
/// OFF) — by the macOS memory-pressure killer (jetsam), a crash, or a force-quit
/// — nothing turns the outlet back on, so the battery can drain toward 0%. macOS
/// jetsam kills produce no crash report and no dialog, so the app just
/// "mysteriously closes". This guards against that for *any* termination cause.
///
/// Design:
///  - While a cycle is active, a sentinel file exists. Its existence means
///    "a cycle is supposed to be running right now". A clean stop/quit removes
///    it; an unexpected SIGKILL cannot — exactly the signal we want.
///  - A lightweight LaunchAgent runs a small shell script every 20s. If the
///    sentinel exists but BurnCycle is not running, it kills any orphaned load
///    process and relaunches the app.
///  - The watchdog is a *separate periodic script*, deliberately NOT a
///    `KeepAlive` copy of the app — a KeepAlive LaunchAgent pointing at a GUI
///    app spawns a duplicate instance. A periodic "relaunch only if missing"
///    script avoids that entirely.
///  - On launch the engine checks `sentinelExists`; a stale sentinel means we
///    were killed mid-cycle, so it recovers fail-safe (charging ON, then resume).
@MainActor
final class Watchdog {
    static let label = "com.hongjunwu.BurnCycle.watchdog"

    private let appSupport: URL = AppPaths.supportDirectory

    private var sentinelURL: URL { appSupport.appendingPathComponent("cycling.active") }
    private var scriptURL: URL { appSupport.appendingPathComponent("watchdog.sh") }
    private var plistURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LaunchAgents/\(Self.label).plist")
    }

    /// True when a cycle was active and not cleanly torn down — i.e. we were
    /// terminated unexpectedly while cycling.
    var sentinelExists: Bool { FileManager.default.fileExists(atPath: sentinelURL.path) }

    /// Mark that a cycle is active (stores the current phase for diagnostics).
    func markCycling(phase: String) {
        try? phase.write(to: sentinelURL, atomically: true, encoding: .utf8)
    }

    /// Clear the active-cycle marker (clean stop / quit) so the watchdog won't
    /// relaunch and on-launch recovery won't fire. Also resets the crash-loop
    /// counter — a deliberate stop means the user is back in control.
    func clearCycling() {
        try? FileManager.default.removeItem(at: sentinelURL)
        try? FileManager.default.removeItem(at: recoveryAttemptsURL)
    }

    // MARK: - Crash-loop detection

    private var recoveryAttemptsURL: URL { appSupport.appendingPathComponent("recovery_attempts") }

    /// Record a recovery attempt and report whether we appear to be in a crash
    /// loop — more than `maxAttempts` recoveries within `window`. The caller
    /// should then stop auto-resuming (but must still leave the battery safe).
    func isRecoveryLooping(maxAttempts: Int = 3, window: TimeInterval = 300) -> Bool {
        let now = Date().timeIntervalSince1970
        var stamps = ((try? String(contentsOf: recoveryAttemptsURL, encoding: .utf8)) ?? "")
            .split(separator: "\n")
            .compactMap { Double($0) }
            .filter { now - $0 < window }
        stamps.append(now)
        try? stamps.map { String($0) }.joined(separator: "\n")
            .write(to: recoveryAttemptsURL, atomically: true, encoding: .utf8)
        return stamps.count > maxAttempts
    }

    // MARK: - LaunchAgent lifecycle

    /// Install + load the periodic watchdog LaunchAgent. Idempotent.
    func install() {
        let appPath = Bundle.main.bundlePath
        // Match the actual executable name rather than a hard-coded literal, so a
        // renamed bundle / Xcode run doesn't spuriously trip the relaunch.
        let procName = ProcessInfo.processInfo.processName
        // The script no-ops unless a cycle is active AND the app is missing.
        let script = """
        #!/bin/bash
        SENTINEL="\(sentinelURL.path)"
        [ -f "$SENTINEL" ] || exit 0
        if /usr/bin/pgrep -x "\(procName)" >/dev/null 2>&1; then exit 0; fi
        # Cycle was active but BurnCycle isn't running — it died unexpectedly.
        # Kill any orphaned load process (xmrig is a child that outlives a crash),
        # then relaunch the app, which recovers fail-safe (charging on, resume).
        /usr/bin/pkill -x xmrig 2>/dev/null
        /usr/bin/open -a "\(appPath)"
        """
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: scriptURL.path)
            let plist: [String: Any] = [
                "Label": Self.label,
                "ProgramArguments": ["/bin/bash", scriptURL.path],
                "StartInterval": 20,
                "RunAtLoad": true,
                "ProcessType": "Background",
                "LimitLoadToSessionType": "Aqua",
            ]
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL)
            reload()
        } catch {
            // Best-effort: a failed watchdog install must never crash the app.
        }
    }

    /// Unload + remove the watchdog entirely (also clears any active marker).
    func uninstall() {
        clearCycling()
        bootout()
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    private func reload() {
        bootout()
        launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    private func bootout() {
        launchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
    }

    /// Serial queue so `launchctl` invocations never block the main actor (they
    /// run from `init`/settings-toggle) yet stay ordered (bootout before bootstrap).
    private let ctlQueue = DispatchQueue(label: "\(Watchdog.label).ctl")

    private func launchctl(_ args: [String]) {
        ctlQueue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
        }
    }
}
