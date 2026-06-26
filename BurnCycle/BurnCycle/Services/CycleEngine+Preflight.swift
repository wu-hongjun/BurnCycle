import Foundation

extension CycleEngine {
    /// Test that shortcuts can toggle power by flipping the outlet and verifying the state changes.
    /// Handles both initial states: outlet ON (plugged in) or outlet OFF (on battery).
    func runPreflightTest() {
        let wasPluggedIn = battery.isPluggedIn

        preflightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if wasPluggedIn {
                // Case A: Currently plugged in — test by turning OFF
                setStatus("Testing: turning outlet OFF...")
                charging.stopCharging(shortcutName: settings.stopChargingShortcut)

                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled || !isRunning { return }
                battery.update()

                if !battery.isPluggedIn {
                    setStatus("Testing: turning outlet ON...")
                    charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)

                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if Task.isCancelled || !isRunning { return }
                    battery.update()

                    if battery.isPluggedIn {
                        clearMessages()
                        lastSuccessfulPreflight = Date()
                        beginCycling()
                    } else {
                        setError("Outlet test failed: 'Start' shortcut didn't restore power.")
                        lastSuccessfulPreflight = nil
                        isRunning = false
                        state = .idle
                    }
                } else {
                    setError("Outlet test failed: still charging after 'Stop' shortcut. Check for multiple power sources (e.g. Thunderbolt dock).")
                    lastSuccessfulPreflight = nil
                    isRunning = false
                    state = .idle
                }
            } else {
                // Case B: Currently on battery — test by turning ON
                setStatus("Testing: turning outlet ON...")
                charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)

                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if Task.isCancelled || !isRunning { return }
                battery.update()

                if battery.isPluggedIn {
                    setStatus("Testing: turning outlet OFF...")
                    charging.stopCharging(shortcutName: settings.stopChargingShortcut)

                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if Task.isCancelled || !isRunning { return }
                    battery.update()

                    if !battery.isPluggedIn {
                        charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if Task.isCancelled || !isRunning { return }
                        battery.update()
                        clearMessages()
                        lastSuccessfulPreflight = Date()
                        beginCycling()
                    } else {
                        setError("Outlet test failed: 'Stop' shortcut didn't disconnect power.")
                        lastSuccessfulPreflight = nil
                        isRunning = false
                        state = .idle
                    }
                } else {
                    setError("Outlet test failed: no power after 'Start' shortcut. Check that the charger cable is plugged into the controlled outlet.")
                    lastSuccessfulPreflight = nil
                    isRunning = false
                    state = .idle
                }
            }
        }
    }

    /// Actually begin the charge/drain cycle after preflight passes
    func beginCycling() {
        // Defensive: never start cycling if the engine was stopped while preflight
        // (or the wake-resume delay) was still in flight (H-1).
        guard isRunning else { return }
        guard hasUsableBattery() else { return }
        battery.update()
        let pct = battery.percentage
        if pct >= Int(settings.effectiveUpperThreshold) {
            transitionToDraining()
        } else {
            transitionToCharging()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }
}
