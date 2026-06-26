import Foundation

extension CycleEngine {
    func handleSleep() {
        guard settings.pauseOnSleep else { return }
        if isRunning {
            // Only mark for fast resume if we were actually cycling. If we were still
            // in preflight (.testing), the outlet control was never confirmed, so a
            // bare resume that bypasses preflight would be unsafe (M-4). In that case
            // we just stop; the user re-presses Start and preflight runs fresh.
            wasRunningBeforeSleep = (state == .charging || state == .draining)
            pauseForSleep()
            setStatus("Paused for sleep")
        }
    }

    /// Pause for sleep WITHOUT clearing the watchdog sentinel. Unlike `stop()`
    /// (a deliberate user stop), a sleep pause must preserve the "cycle active"
    /// marker: if the app is jetsam-killed while asleep, the watchdog still
    /// recovers on wake. We also best-effort restore charging so the machine
    /// charges (safely) during sleep rather than sitting on battery.
    private func pauseForSleep() {
        let wasDraining = state == .draining
        isRunning = false
        timer?.invalidate()
        timer = nil
        preflightTask?.cancel()
        preflightTask = nil
        wakeResumeTask?.cancel()
        wakeResumeTask = nil
        stopAllLoad()
        if wasDraining || !battery.isPluggedIn {
            charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
        }
        retryCount = 0
        verifyTicksRemaining = 0
        chargingStartedAt = nil
        chargingStallWarned = false
        resetThrottleHysteresis()
        state = .idle
        // NOTE: deliberately does NOT call watchdog.clearCycling().
    }

    func handleWake() {
        // A manual start() after wake should re-run preflight in case hardware
        // changed while asleep (e.g. a dock was added) — invalidate the cache (M-2).
        // The auto-resume path below intentionally bypasses preflight.
        guard settings.pauseOnSleep, wasRunningBeforeSleep else {
            lastSuccessfulPreflight = nil
            return
        }
        wasRunningBeforeSleep = false
        lastSuccessfulPreflight = nil
        // Defer slightly so battery state reflects wake conditions. Stored so stop()
        // can cancel it — otherwise pressing Stop during the delay would silently
        // restart the engine after the sleep completes (concurrency M2).
        wakeResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.clearMessages()
            self.startAfterWake()
        }
    }

    /// Fast resume after sleep — bypasses preflight unconditionally.
    /// The cycle was running before sleep so preflight had already succeeded;
    /// any drift will be caught by `verifyPowerState` within ~20s.
    private func startAfterWake() {
        guard !isRunning else { return }
        guard hasUsableBattery() else { return }
        isRunning = true
        clearMessages()
        battery.update()
        system.update()
        beginCycling()
    }

    // MARK: - Crash / termination failsafe

    /// Record that a cycle is active so the watchdog (and on-launch recovery) can
    /// detect an unexpected death. No-op when the user has disabled the watchdog.
    func markCyclingActive() {
        guard settings.watchdogEnabled else { return }
        watchdog.markCycling(phase: state.rawValue)
    }

    /// Called once at app launch. If the sentinel survived from a previous run,
    /// we were killed mid-cycle (jetsam/crash/force-quit) — recover fail-safe:
    /// force the outlet ON immediately, clear any orphaned load, then resume the
    /// cycle so it continues unattended.
    func recoverFromUnexpectedExitIfNeeded() {
        guard !isRunning, watchdog.sentinelExists else { return }
        // If the user has since disabled the watchdog, just clear the stale marker.
        guard settings.watchdogEnabled else { watchdog.clearCycling(); return }
        guard battery.hasBattery else { watchdog.clearCycling(); return }

        // FAIL-SAFE first: charging is always the safe direction for the machine.
        charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
        // A crash can orphan the xmrig child (it outlives the parent); stop it.
        mining.stop()

        // Crash-loop guard: if we keep dying right after recovery, stop the
        // relaunch loop. The battery is already safe (charging, above); we just
        // don't resume cycling and ask the user to intervene.
        if watchdog.isRecoveryLooping() {
            watchdog.clearCycling()
            setError("Repeated unexpected exits — auto-resume paused for safety. Charging is on; press Start to resume.")
            return
        }

        isRunning = true
        clearMessages()
        setStatus("Recovered from an unexpected exit — charging restored, resuming cycle.")
        battery.update()
        system.update()
        // Resume without the disruptive preflight (it would toggle the outlet);
        // verifyPowerState re-checks the real power state within ~20s anyway.
        beginCycling()
    }

    /// Graceful-termination handler (⌘Q / logout / launchd bootout). Tear down the
    /// active-cycle marker and, if we were draining, leave the outlet ON so a
    /// closed app never sits on battery with the outlet off.
    func handleCleanQuit() {
        let wasDraining = isRunning && state == .draining
        watchdog.clearCycling()
        if wasDraining || (isRunning && !battery.isPluggedIn) {
            charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
        }
    }

    /// Apply the watchdog enable/disable setting (called from the debounced
    /// settings observer, only acting on an actual change).
    func reconcileWatchdog() {
        guard settings.watchdogEnabled != lastWatchdogEnabled else { return }
        lastWatchdogEnabled = settings.watchdogEnabled
        if settings.watchdogEnabled {
            watchdog.install()
            if isRunning { markCyclingActive() }
        } else {
            watchdog.uninstall()
        }
    }
}
