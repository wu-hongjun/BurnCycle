import Foundation

extension CycleEngine {
    // MARK: - Load management

    func startLoad() {
        loadThrottled = false
        activeLoadMethod = settings.loadMethod
        switch settings.selectedLoadMethod {
        case .mine:
            mining.start(walletOverride: settings.walletAddress)
        case .stress:
            stress.start()
        }
    }

    func stopAllLoad() {
        mining.stop()
        stress.stop()
        loadThrottled = false
        activeLoadMethod = nil
    }

    func isLoadRunning() -> Bool {
        mining.isMining || stress.isRunning
    }

    func resetThrottleHysteresis() {
        consecutiveHighLoadTicks = 0
        consecutiveLowLoadTicks = 0
    }

    func manageLoad() {
        guard settings.loadEnabled else { return }

        // Safety margin: stop load 3% above threshold (use effective lower so a
        // mis-ordered slider pair can't drive this above the upper threshold).
        let safetyMargin = Int(settings.effectiveLowerThreshold) + 3
        if battery.percentage <= safetyMargin && isLoadRunning() {
            stopAllLoad()
            resetThrottleHysteresis()
            return
        }

        let externalSafe = isExternalLoadSafe()

        if isLoadRunning() {
            if !externalSafe {
                consecutiveHighLoadTicks += 1
                consecutiveLowLoadTicks = 0
                if consecutiveHighLoadTicks >= highLoadStopThreshold {
                    stopAllLoad()
                    loadThrottled = true
                    consecutiveHighLoadTicks = 0
                }
            } else {
                consecutiveHighLoadTicks = 0
            }
        } else if loadThrottled {
            if externalSafe && battery.percentage > safetyMargin {
                consecutiveLowLoadTicks += 1
                consecutiveHighLoadTicks = 0
                if consecutiveLowLoadTicks >= lowLoadResumeThreshold {
                    startLoad()
                    consecutiveLowLoadTicks = 0
                }
            } else {
                consecutiveLowLoadTicks = 0
            }
        }
    }

    /// Check if external (non-BurnCycle) load is below threshold
    /// When our load is running, we check if usage is excessively high (>95%)
    /// which suggests external apps are also consuming heavily
    func isExternalLoadSafe() -> Bool {
        if isLoadRunning() {
            // If we're running and CPU/GPU is near 100%, external apps are also heavy
            return system.cpuUsage < 95 && system.gpuUsage < 95
        }
        // If we're not running, check the raw threshold
        return system.cpuUsage < externalLoadThreshold && system.gpuUsage < externalLoadThreshold
    }
}
