# Safety state machine audit

> **Remediation status (2026-05-27):** addressed on branch `fix/audit-remediation`. See [2026-05-27-remediation-report.md](2026-05-27-remediation-report.md) for the per-finding Fixed / Partial / Deferred status.

**Date:** 2026-05-10
**Auditor:** codex-reviewer (Claude Sonnet 4.6 + Codex gpt-5.5)
**Scope:** Full read-only audit of the battery-cycle safety state machine.
**Files reviewed:**
- `BurnCycle/BurnCycle/Services/CycleEngine.swift`
- `BurnCycle/BurnCycle/Services/ChargingController.swift`
- `BurnCycle/BurnCycle/Services/BatteryMonitor.swift`
- `BurnCycle/BurnCycle/Models/AppSettings.swift`

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 3     |
| High     | 4     |
| Medium   | 5     |
| Low      | 4     |
| **Total**| **16**|

---

## Critical

---

### C-1: Critical safety branch only guards `.draining` — battery can hit 3% during `.testing` with no emergency charge

**Location:** `CycleEngine.swift` line 310

**Issue:**
```swift
if pct <= criticalBattery && state == .draining {
```
The emergency-charge guard is conditioned on `state == .draining`. During preflight (`state == .testing`), the machine runs an 8-second sleep twice while battery could be draining (outlet is turned OFF in Case A of the preflight test). If the battery is already low when preflight starts and the preflight sleeps push it to ≤ 3%, the safety branch never fires. The battery can reach 0% and force-shutdown with no emergency charge attempted.

Furthermore, when the cycle is stopped (`isRunning = false`) and the machine is on battery, `onBatteryChanged` returns immediately at `guard isRunning else { return }` (line 297), so a critically-low battery is entirely ignored by the app — even though the app is still open and could trigger an emergency charge.

**Recommendation:**
1. Remove the `state == .draining` guard from the critical-battery check. Emergency charge should fire regardless of state whenever `pct <= criticalBattery` and `isRunning`.
2. Add a second, unconditional check outside the `guard isRunning` block that triggers an emergency charge (with a distinct `errorMessage`) if `pct <= criticalBattery` even when the cycle is stopped.

---

### C-2: Verify-retry exhaustion on charging failure leaves battery draining indefinitely with no cycle stop

**Location:** `CycleEngine.swift` lines 379–384

**Issue:**
After 3 failed retries to start charging (`retryCount >= maxRetries`), the engine sets an error message and resets `retryCount = 0`, but does **not** stop the cycle. The state remains `.charging`, yet the outlet is not responding. Because the battery is still discharging (no actual charger), it will continue to drain toward 0% while the cycle "thinks" it is in `.charging` state. The critical-safety branch at line 310 only guards `.draining`, so even C-1 does not save this scenario — the battery drains to 0% through the `.charging` state with no intervention.

**Recommendation:**
After retry exhaustion on a charging failure, call `stop()` and surface a blocking error. Draining to 0% is more damaging than stopping the cycle. Alternatively, if the intent is to keep cycling, re-enter the `.draining` state so the critical-battery guard at least applies.

---

### C-3: Thunderbolt dock added mid-cycle bypasses all power-control — cycle becomes stuck or unsafe

**Location:** `CycleEngine.swift` lines 385–395 (`verifyPowerState`)

**Issue:**
Preflight catches the case where a second power source is already present at start-up (it detects "still charging after 'Stop' shortcut"). However, if a Thunderbolt dock (or any second AC source) is connected **after** the cycle starts and while in `.draining` state, the app's `stopCharging` shortcut will successfully turn off the HomeKit outlet but the dock continues supplying power. The battery will never drain. `verifyPowerState` will detect `pluggedIn == true` while `state == .draining` and retry `stopCharging` up to 3 times — none of which disconnect the dock. After exhaustion, the engine sets an error and invalidates the preflight cache, but keeps cycling. The battery stays at 100% (or wherever it stalled) indefinitely, and the user has no automated recovery path.

**Recommendation:**
After `verifyPowerState` retry exhaustion in the draining direction, call `stop()` and surface an actionable error: "Second power source detected — unplug non-controlled charger to continue." Do not continue cycling while power-state control is known to be ineffective.

---

## High

---

### H-1: `isRunning = true` set before preflight — spamming Stop/Start during preflight leaves engine in inconsistent state

**Location:** `CycleEngine.swift` lines 160–168

**Issue:**
`isRunning = true` is set at the top of `start()`, before `runPreflightTest()` creates the `preflightTask`. If the user calls `stop()` immediately after `start()`, `stop()` sets `isRunning = false`, cancels `preflightTask` (which is still `nil` at that instant on the first call), and sets `state = .idle`. The `preflightTask` is then assigned a live `Task` milliseconds later. Because `preflightTask` was `nil` when `stop()` ran, `preflightTask?.cancel()` was a no-op; the task runs to completion and may call `beginCycling()` after the user has stopped the engine.

**Recommendation:**
Create the preflight `Task` before setting `isRunning = true`, or check `isRunning` at the very start of `beginCycling()` before starting the timer.

---

### H-2: Apple Smart Charging (80% cap) can cause the cycle to wait for 90% forever

**Location:** `CycleEngine.swift` line 320

**Issue:**
On Macs with Optimized Battery Charging enabled, macOS can cap charging at ~80% (or some other limit below `upperThreshold`). The cycle will be in `.charging` state indefinitely: `verifyPowerState` confirms plugged in (no error), but `pct >= Int(settings.upperThreshold)` (90%) never triggers. The cycle is silently stuck — no error, no timeout, no transition to draining.

**Recommendation:**
Add a charging-timeout watchdog: if the engine has been in `.charging` state for more than N minutes (e.g. 90) and `pct` has not increased in the last M minutes, surface a warning and optionally transition to draining. Also document this as a known limitation and recommend users disable Optimized Battery Charging.

---

### H-3: `cycleCount` incremented in `onBatteryChanged` — a single sustained battery reading at `lowerThreshold` causes double-increment

**Location:** `CycleEngine.swift` lines 317–319

**Issue:**
```swift
if state == .draining && pct <= Int(settings.lowerThreshold) {
    cycleCount += 1
    transitionToCharging()
}
```
`onBatteryChanged` is called every time `battery.$percentage` emits. The `BatteryMonitor` fast timer fires every 2 seconds, and `battery.update()` is called on every engine tick (every 10 s) as well. If the battery percentage stays at exactly `lowerThreshold` for more than one publish cycle (e.g. because charging is slow to start), `onBatteryChanged` fires again with the same `pct`, `state` is still `.draining` (the shortcut hasn't completed yet), and `cycleCount` is incremented a second time and `transitionToCharging()` is called again.

**Recommendation:**
Guard the transition with a state change before incrementing: call `transitionToCharging()` first (which sets `state = .charging`), then increment `cycleCount`. Or set state to `.charging` as the very first line of the `if`-block before calling the transition function, so re-entrant calls skip the branch.

---

### H-4: No battery / desktop Mac — `beginCycling` enters infinite charge loop

**Location:** `CycleEngine.swift` lines 264–278

**Issue:**
On a desktop Mac with no battery, `battery.percentage` is 0 and `battery.isPluggedIn` is always `true` (or `false` if the IOPowerSources read fails). `beginCycling()` checks `pct >= Int(settings.upperThreshold)` — 0 < 90, so it calls `transitionToCharging()`. The cycle now sits in `.charging` forever (same as H-2 but for a different reason), repeatedly firing the verify watchdog, retrying the shortcut, and ultimately spamming errors. On desktop Macs, `IOServiceGetMatchingService("AppleSmartBattery")` returns `IO_OBJECT_NULL`, so `percentage` stays 0 permanently.

**Recommendation:**
At `start()` (or in preflight), detect the absence of a battery (`IOPSCopyPowerSourcesList` returns empty or power source type is not `kIOPSInternalBatteryType`) and abort with a clear error: "No internal battery detected."

---

## Medium

---

### M-1: Settings change mid-cycle only handled for `.draining` — threshold change while `.charging` not acted upon

**Location:** `CycleEngine.swift` lines 325–346

**Issue:**
`onSettingsChanged()` has `guard isRunning, state == .draining else { return }`. If the user lowers `upperThreshold` from 90 to 50 while the battery is at 75% in `.charging` state, the engine will continue charging to 90% (the old threshold) because `onSettingsChanged` bails out for non-draining states, and `onBatteryChanged` only checks `pct >= Int(settings.upperThreshold)` on the next battery publish — which will correctly use the new value of 50. So actually the threshold change IS picked up on the next battery event, but only because `settings.upperThreshold` is read live each time in `onBatteryChanged`. The real gap is the reverse: if the user raises `lowerThreshold` from 5 to 30 while at 20% draining, the cycle should immediately transition to charging, but it won't until the next battery event fires. The battery may continue draining below the new threshold for up to 2 seconds (fast timer interval).

This is a minor timing window but could matter if the user raises the lower threshold specifically because the battery is getting too low.

**Recommendation:**
In `onSettingsChanged`, also handle the charging state by immediately checking whether the current `pct` satisfies the (possibly new) threshold and transitioning if needed. Extend the guard to `state == .draining || state == .charging`.

---

### M-2: Preflight cache TTL (30 min) survives sleep/wake — stale cache used after hardware change

**Location:** `CycleEngine.swift` lines 150–158

**Issue:**
`startAfterWake()` unconditionally bypasses preflight (by design, per the comment). However, `start()` also skips preflight if `lastSuccessfulPreflight` is within 30 minutes. If the user wakes the Mac, manually calls `stop()`, reconnects hardware, and immediately calls `start()` within the 30-minute window, the preflight is skipped even though the hardware configuration may have changed (e.g. Thunderbolt dock added).

**Recommendation:**
Invalidate `lastSuccessfulPreflight` in `handleWake()` so that a manual `start()` after wake always re-runs preflight. Keep `startAfterWake()` bypassing it (that path is intentional for auto-resume).

---

### M-3: `transitionToDraining` sets `state = .draining` after shortcut call — creates brief window of torn state

**Location:** `CycleEngine.swift` lines 499–512

**Issue:**
```swift
private func transitionToDraining() {
    charging.stopCharging(...)   // enqueues async task
    if settings.loadEnabled { startLoad() }
    state = .draining            // set AFTER shortcut enqueue
    verifyTicksRemaining = 2
    ...
}
```
`stopCharging` is fire-and-forget (enqueues a detached Task). Between the `stopCharging` call and `state = .draining`, if `onBatteryChanged` fires (from the Combine publisher on the 2-second timer), `state` is still `.charging`, so the `pct >= upperThreshold` branch triggers again and calls `transitionToDraining()` a second time — enqueuing a second `stopCharging`. This is not catastrophic (idempotent), but it doubles shortcut calls and could confuse the verify countdown. The same issue exists in `transitionToCharging` (state set after shortcut call).

**Recommendation:**
Set `state` as the first line of each transition function, before any side-effectful calls. This is the standard state-machine pattern to prevent re-entrant transitions.

---

### M-4: Sleep during preflight — `wasRunningBeforeSleep` set to `true`, wake resumes cycling even if preflight was failing

**Location:** `CycleEngine.swift` lines 114–143

**Issue:**
If the Mac sleeps while preflight is in-flight (`state == .testing`, `isRunning == true`), `handleSleep()` calls `stop()` (which cancels the preflightTask) and sets `wasRunningBeforeSleep = true`. On wake, `startAfterWake()` calls `beginCycling()` directly — bypassing preflight entirely. But the preflight was never completed successfully; `lastSuccessfulPreflight` was not set. The outlet may not actually be under app control.

**Recommendation:**
In `handleSleep()`, if `state == .testing`, set `wasRunningBeforeSleep = false` (or a separate flag like `preflightWasInProgress = true`) so that wake triggers a full preflight rather than a bare `beginCycling()`.

---

### M-5: `onBatteryChanged` Combine sink dispatches to `@MainActor` via unstructured `Task` — ordering not guaranteed

**Location:** `CycleEngine.swift` lines 75–79

**Issue:**
```swift
batteryObserver = battery.$percentage.sink { [weak self] pct in
    Task { @MainActor in
        self?.onBatteryChanged(pct)
    }
}
```
The `sink` closure captures `pct` at publish time but the `Task { @MainActor in }` is enqueued asynchronously. If two publishes fire in rapid succession (e.g. `battery.update()` called from `tick()` while the fast timer also fires), two tasks are enqueued. They will execute in order on the main actor, but with potentially stale intermediate `pct` values that do not match the current `battery.percentage`. This can cause `onBatteryChanged(pct)` to evaluate a threshold against an old `pct` while `battery.percentage` has already moved on.

**Recommendation:**
Inside `onBatteryChanged`, read `battery.percentage` directly rather than relying on the captured `pct` argument. Or, since `BatteryMonitor` is `@MainActor`, the sink itself could be received on `RunLoop.main` using `.receive(on: RunLoop.main)` to avoid the extra async hop.

---

## Low

---

### L-1: Hourly timer calls `refreshHealthDetail()` directly, bypassing `lastHealthRead` throttle

**Location:** `BatteryMonitor.swift` line 58 (Codex finding)

**Issue:**
The hourly `healthTimer` fires `refreshHealthDetail()` directly. If `refreshHealth()` was also called shortly before the timer fires (e.g. at cycle end), two expensive `system_profiler` subprocesses can be in flight within the intended one-hour window.

**Recommendation:**
Have the timer call `refreshHealth()` instead of `refreshHealthDetail()` directly, or add a force-parameter to `refreshHealthDetail` and use it only where truly intentional.

---

### L-2: `startAfterWake` has a 2-second unconditional sleep on the main actor

**Location:** `CycleEngine.swift` lines 127–132

**Issue:**
```swift
try? await Task.sleep(nanoseconds: 2_000_000_000)
```
This suspends the main-actor task for 2 seconds. While Swift concurrency allows yielding during `await`, any `@MainActor`-bound work that arrives during this 2-second window will be queued. This is a minor UI responsiveness concern rather than a safety issue, but the comment says "defer slightly so battery state reflects wake conditions" — 2 seconds is an arbitrary heuristic with no validation.

**Recommendation:**
Instead of sleeping, wait for the first `battery.$isPluggedIn` or `battery.$percentage` publish after wake, or simply accept that the first tick (10 s) will correct any stale state.

---

### L-3: `AppSettings` has no enforced lower bound preventing `lowerThreshold >= upperThreshold`

**Location:** `AppSettings.swift` (all lines)

**Issue:**
There are no validation constraints in `AppSettings` preventing the user from setting `lowerThreshold` equal to or greater than `upperThreshold`. If `lowerThreshold == upperThreshold` (e.g. both 50%), the conditions on lines 317 and 320 of `CycleEngine.swift` are both true simultaneously at that percentage, and the engine will oscillate: drain to 50% → charge → immediately drain again at 50%.

**Recommendation:**
Add a computed validation or `didSet` in `AppSettings` (or a UI-layer guard) that enforces `lowerThreshold < upperThreshold - minimumGap` (e.g. minimum gap of 5%).

---

### L-4: `ChargingController.stopCharging` normal (non-force) call silently dropped when `inflight != nil`

**Location:** `ChargingController.swift` lines 74–78

**Issue:**
Non-force calls are silently dropped if another shortcut is already in flight (`guard inflight == nil else { return }`). `transitionToDraining()` calls `stopCharging` without `force: true`. If a prior `startCharging` is still executing (e.g. it is timing out at 20 s), the `stopCharging` is silently lost. The verify countdown starts, but the outlet was never told to stop — leading to a guaranteed verify failure and retry loop.

**Recommendation:**
`transitionToDraining()` should call `stopCharging(shortcutName:, force: true)` to ensure the stop command is always enqueued, consistent with how `transitionToCharging()` calls `startCharging` (which already uses `force: true` in the critical path).

---

## Codex CLI diff review result (last commit only)

The Codex review of the `HEAD~1` diff (`BatteryMonitor.swift` — ticket-09 throttle refactor) returned:

```json
{
  "status": "FAIL",
  "issues": [
    {
      "file": "BurnCycle/BurnCycle/Services/BatteryMonitor.swift",
      "line": 58,
      "severity": "low",
      "description": "The hourly timer calls refreshHealthDetail() directly, bypassing the lastHealthRead throttle. If refreshHealth() runs shortly before the timer fires, the app can spawn two expensive system_profiler processes within the intended one-hour window.",
      "suggestion": "Have the timer call refreshHealth() instead, or move the throttle check into refreshHealthDetail() with an explicit force option only where truly needed."
    }
  ]
}
```

This is captured as **L-1** above.

