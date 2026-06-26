import Foundation

extension CycleEngine {
    // MARK: - Reactive

    func onBatteryChanged(_ pct: Int) {
        // Read the live value rather than trusting the captured argument — rapid
        // publishes can enqueue tasks out of order with stale pct values (M-5).
        let pct = battery.percentage

        // CRITICAL SAFETY (stopped case): even when not cycling, if the app is open
        // and the battery is critically low on battery power, fire one best-effort
        // emergency charge (C-1). This is a one-shot per low-battery episode (reset
        // on recovery); it is NOT a substitute for the running-state floor, since a
        // stopped engine has no tick timer to re-verify or re-attempt a failed shortcut.
        guard isRunning else {
            if pct <= criticalBattery && !battery.isPluggedIn && battery.hasBattery {
                if !firedIdleEmergencyCharge {
                    firedIdleEmergencyCharge = true
                    charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
                    setError("Emergency charge at \(pct)% — press Start to resume.")
                }
            } else if firedIdleEmergencyCharge {
                // Emergency resolved — either plugged in (even while still at/below
                // critical%) or recovered above critical. Disarm the one-shot latch
                // and clear its now-stale message; the stopped engine has no tick
                // timer, so this is the only place the idle alert gets cleared.
                firedIdleEmergencyCharge = false
                clearMessages()
            }
            return
        }
        // While running, keep the idle one-shot disarmed/recovered.
        if pct > criticalBattery { firedIdleEmergencyCharge = false }

        // Auto-clear active error/status when physical state matches expected
        if errorMessage != nil || statusMessage != nil {
            let pluggedIn = battery.isPluggedIn
            if (state == .charging && pluggedIn) || (state == .draining && !pluggedIn) {
                clearMessages()
                retryCount = 0
                verifyTicksRemaining = 0
            }
        }

        // CRITICAL SAFETY: force charge at/below critical%, regardless of state
        // (testing, charging that isn't actually delivering power, draining — all
        // covered). Re-verify the power state shortly after so a failed shortcut
        // doesn't leave us falsely believing we're charging (C-1).
        if pct <= criticalBattery {
            // If the battery jumped straight from above the lower threshold to
            // critical in one reading, the normal drain→charge branch below never
            // ran — count that completed drain here so the cycle isn't undercounted.
            let wasDraining = (state == .draining)
            stopAllLoad()
            resetThrottleHysteresis()
            charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
            if wasDraining { cycleCount += 1 }
            state = .charging
            chargingStartedAt = Date()
            chargingStallWarned = false
            verifyTicksRemaining = 2
            return
        }

        if state == .draining && pct <= Int(settings.effectiveLowerThreshold) {
            // Edge-triggered: flip state to .charging FIRST so a repeated reading at
            // the threshold (before the shortcut completes) can't re-enter this branch
            // and double-count the cycle (H-3).
            state = .charging
            cycleCount += 1
            transitionToCharging()
        } else if state == .charging && pct >= Int(settings.effectiveUpperThreshold) {
            transitionToDraining()
        }
    }

    func onSettingsChanged() {
        // Reconcile the watchdog toggle even when idle (it gates the failsafe).
        reconcileWatchdog()

        guard isRunning else { return }

        // Threshold changes mid-cycle should take effect immediately rather than
        // waiting for the next battery publish (M-1). Use effective thresholds so a
        // mis-ordered slider pair can't cause thrash.
        let pct = battery.percentage
        if state == .charging && pct >= Int(settings.effectiveUpperThreshold) {
            // Upper was lowered to at/below current charge — start draining now.
            transitionToDraining()
            return
        } else if state == .draining && pct <= Int(settings.effectiveLowerThreshold) {
            // Lower was raised to at/above current charge — start charging now.
            state = .charging
            cycleCount += 1
            transitionToCharging()
            return
        }

        guard state == .draining else { return }

        let wantLoad = settings.loadEnabled
        let wantMethod = settings.loadMethod
        let running = isLoadRunning()

        // Clear throttle state when load is disabled — it's no longer relevant
        if !wantLoad {
            loadThrottled = false
        }

        if wantLoad && !running && isExternalLoadSafe() {
            startLoad()
        } else if !wantLoad && running {
            stopAllLoad()
        } else if wantLoad && running && wantMethod != activeLoadMethod {
            // Method changed while running — switch
            stopAllLoad()
            startLoad()
        }
    }

    func tick() {
        guard isRunning else { return }
        battery.update()
        system.update()

        // Verify physical power state matches expected state
        if verifyTicksRemaining > 0 {
            verifyTicksRemaining -= 1
            if verifyTicksRemaining == 0 {
                verifyPowerState()
            }
        }

        if state == .draining {
            manageLoad()
        }

        checkChargingStall()
    }

    /// Non-fatal watchdog: macOS Optimized Battery Charging can cap charging at ~80%,
    /// so the cycle would sit in .charging waiting for upperThreshold forever (H-2).
    /// After a long interval still charging, surface a warning but keep cycling.
    private func checkChargingStall() {
        guard state == .charging, let started = chargingStartedAt else { return }
        if !chargingStallWarned,
           Date().timeIntervalSince(started) >= chargingStallWarnInterval,
           battery.percentage < Int(settings.effectiveUpperThreshold) {
            chargingStallWarned = true
            setError("Charging stalled — macOS optimized charging may cap at 80%. Disable in System Settings ▸ Battery.")
        }
    }

    /// Check that physical power state matches our cycle state
    /// Called ~20s after a transition (2 ticks at 10s) to give the shortcut time
    private func verifyPowerState() {
        let pluggedIn = battery.isPluggedIn

        if state == .charging && !pluggedIn {
            // Expected charging but not plugged in — shortcut failed or cable not connected
            if retryCount < maxRetries {
                retryCount += 1
                setStatus("Outlet not responding (retry \(retryCount)/\(maxRetries))...")
                charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
                verifyTicksRemaining = 2 // check again in ~20s
            } else {
                // Do NOT give up: a charging failure that goes unanswered drains the
                // battery toward 0%. Keep a sticky error, but reset and re-attempt on a
                // slower cadence so the engine never permanently abandons the battery
                // (C-2). Combined with the critical-battery guard this guarantees a floor.
                setError("Charger not detected. Check cable and outlet. Still retrying...")
                retryCount = 0
                // Outlet stopped responding — invalidate the preflight cache so a
                // future manual Start re-runs the test instead of skipping.
                lastSuccessfulPreflight = nil
                charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
                verifyTicksRemaining = 6 // ~60s, then check again
            }
        } else if state == .draining && pluggedIn {
            // Expected draining but still plugged in
            if retryCount < maxRetries {
                retryCount += 1
                setStatus("Outlet not responding (retry \(retryCount)/\(maxRetries))...")
                charging.stopCharging(shortcutName: settings.stopChargingShortcut, force: true)
                verifyTicksRemaining = 2
            } else {
                // Likely a second, non-controlled power source (e.g. a Thunderbolt
                // dock added mid-cycle, C-3). Our stop shortcut works but power keeps
                // flowing. Keep retrying on a slow cadence rather than abandoning (C-2).
                setError("Still charging while draining — a second power source may be connected (e.g. a Thunderbolt dock). Unplug it to continue. Still retrying...")
                retryCount = 0
                lastSuccessfulPreflight = nil
                charging.stopCharging(shortcutName: settings.stopChargingShortcut, force: true)
                verifyTicksRemaining = 6 // ~60s, then check again
            }
        } else {
            // State matches — clear messages
            clearMessages()
            retryCount = 0
        }
    }
}
