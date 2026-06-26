import Foundation

extension CycleEngine {
    // MARK: - State transitions

    func transitionToCharging() {
        // Set state BEFORE the side-effectful shortcut call so a re-entrant
        // onBatteryChanged can't trigger a second transition in the torn window (M-3).
        state = .charging
        chargingStartedAt = Date()
        chargingStallWarned = false
        stopAllLoad()
        charging.startCharging(shortcutName: settings.startChargingShortcut, force: true)
        markCyclingActive()
        verifyTicksRemaining = 2 // verify in ~20s
        resetThrottleHysteresis()
        // A drain just finished — meaningful moment to refresh battery health.
        // The call is internally throttled to once per hour, so adding it here
        // is safe even on rapid cycles.
        battery.refreshHealth()
        clearMessages()
    }

    func transitionToDraining() {
        // Set state first (M-3), and use force:true so the stop command is never
        // silently dropped when another shortcut is in flight (consistent with
        // transitionToCharging's startCharging).
        state = .draining
        chargingStartedAt = nil
        chargingStallWarned = false
        charging.stopCharging(shortcutName: settings.stopChargingShortcut, force: true)
        markCyclingActive()
        if settings.loadEnabled {
            if isExternalLoadSafe() {
                startLoad()
            } else {
                loadThrottled = true
            }
        }
        verifyTicksRemaining = 2
        resetThrottleHysteresis()
        clearMessages()
    }
}
