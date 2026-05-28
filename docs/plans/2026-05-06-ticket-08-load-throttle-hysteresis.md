> **Status (2026-05-27):** Implemented in `c5fc84a` (fix: re-test button, status/error split, throttle hysteresis) — `consecutiveHighLoadTicks` / `consecutiveLowLoadTicks` with 3-tick stop / 6-tick resume thresholds and a `resetThrottleHysteresis()` helper called from stop/transition paths. See `CycleEngine.swift`.

# Ticket 08 — Add hysteresis to load throttling

**Severity:** Minor (UX during draining, no safety impact)
**File:** `BurnCycle/BurnCycle/Services/CycleEngine.swift`

## Problem

`isExternalLoadSafe` flips its threshold based on whether our own load is running:

```swift
private func isExternalLoadSafe() -> Bool {
    if isLoadRunning() {
        return system.cpuUsage < 95 && system.gpuUsage < 95
    }
    return system.cpuUsage < externalLoadThreshold && system.gpuUsage < externalLoadThreshold  // 80
}
```

This causes a self-oscillation:

1. Load on, our process pushes CPU to 99% → `isExternalLoadSafe()` returns false → `manageLoad()` stops load and sets `loadThrottled = true`.
2. Our load is gone, CPU drops to ~10% → `isExternalLoadSafe()` returns true → `loadThrottled` branch restarts load.
3. CPU climbs back to 99% → stop again.
4. Loop, ~10s per cycle (matches the engine tick interval).

Visible symptoms: load indicator flickers on/off; xmrig restarts repeatedly (potentially logging itself out of mining pool); stress test thrashes.

This is **not** a CoAP bug, but it makes the app feel broken in a different way and was flagged in the audit.

## Fix

Add hysteresis: require N consecutive ticks of the relevant condition before flipping.

### Implementation

Add private counter fields:

```swift
private var consecutiveHighLoadTicks: Int = 0
private var consecutiveLowLoadTicks: Int = 0
private let highLoadStopThreshold: Int = 3   // need 3 ticks (~30s) of "too hot" to stop
private let lowLoadResumeThreshold: Int = 6  // need 6 ticks (~60s) of "cool" to resume
```

Replace the body of `manageLoad()` (the throttle decision) with:

```swift
private func manageLoad() {
    guard settings.loadEnabled else { return }

    // Safety margin: stop load 3% above threshold (unchanged)
    let safetyMargin = Int(settings.lowerThreshold) + 3
    if battery.percentage <= safetyMargin && isLoadRunning() {
        stopAllLoad()
        consecutiveHighLoadTicks = 0
        consecutiveLowLoadTicks = 0
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
```

Reset both counters in:
- `stop()` — engine is being shut down, everything resets.
- `transitionToCharging()` — load was stopped on transition; counters from the previous draining state are stale.
- `transitionToDraining()` — fresh draining cycle.

Add a helper:
```swift
private func resetThrottleHysteresis() {
    consecutiveHighLoadTicks = 0
    consecutiveLowLoadTicks = 0
}
```
Call from `stop`, `transitionToCharging`, `transitionToDraining`, and the safety-margin branch above.

## Acceptance

- Start a cycle. Reach draining. Load runs.
- Open Activity Monitor. Confirm load stays running steadily (CPU near 100%) with no flicker for at least 60 seconds.
- Trigger external high CPU load (e.g. `yes > /dev/null` in 8 terminal tabs, or run a video render). After ~30 seconds (3 ticks at 10s each), load stops and `loadThrottled` is set.
- Stop the external load. After ~60 seconds (6 ticks), our load resumes.
- Cycle through charge → drain a couple of times. No oscillation observed.
- `swift build -c release` succeeds.

## Notes

- Tick interval is 10s (`CycleEngine.swift:194` — `withTimeInterval: 10`). 3 high ticks = 30s, 6 low ticks = 60s.
- Asymmetric thresholds (slow to resume, faster to stop) bias toward safety: when in doubt, leave external apps the headroom.
- Do **not** change `isExternalLoadSafe`'s threshold flip (95% when running, 80% when not). The flip is necessary because we can't measure external CPU separately from our own. Hysteresis is the right complement, not the replacement.
