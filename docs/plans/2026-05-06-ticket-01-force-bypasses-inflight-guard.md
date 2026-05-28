> **Status (2026-05-27):** Implemented in `fad124f` (fix: make ChargingController resilient to CoAP flakiness) — serial `inflight` chain with `latestTaskId` bookkeeping; force calls enqueue rather than drop. See `ChargingController.swift`.

# Ticket 01 — `force: true` must bypass the in-flight guard

**Severity:** Critical (safety)
**File:** `BurnCycle/BurnCycle/Services/ChargingController.swift`
**Related:** Tickets 02 and 03 also touch this file. Implement 01 → 02 → 03 in order; the same agent owns all three so there are no merge conflicts.

## Problem

`runShortcut` blocks every concurrent call, including safety-critical force calls:

```swift
private func runShortcut(name: String, action: String, skipCooldown: Bool) {
    let now = Date()
    if !skipCooldown { /* cooldown check */ }
    guard !isRunningShortcut else { return }   // ← drops force calls too
    ...
}
```

The `force: true` argument exposed by `startCharging` is passed through as `skipCooldown`, which only bypasses the cooldown check — **not** the in-flight guard. The result:

- Battery hits 3% → `CycleEngine.onBatteryChanged` calls `startCharging(force: true)`.
- A previous shortcut is still in flight (HomeKit is slow / retrying CoAP).
- The emergency call hits the `guard !isRunningShortcut` line and silently `return`s.
- Nothing requeues it. The laptop can keep draining past 3%.

## Fix

Replace the in-flight gate with a serial async chain so calls are **queued**, not dropped, when forced. Non-force calls within the cooldown window should continue to return early as today.

### Concrete design

1. Remove `var isRunningShortcut: Bool` as a *gate*; keep it as a UI signal only.
2. Add a private serial chain:
   ```swift
   private var inflight: Task<Void, Never>?
   ```
3. Restructure `runShortcut(name:action:skipCooldown:force:)` so that:
   - Non-force calls still respect cooldown and may early-return.
   - Non-force calls also early-return if `inflight != nil` (avoid stacking redundant work).
   - Force calls always enqueue: capture the previous `inflight`, await it, then run.
   - The published `isRunningShortcut` is set true at task start and false at task end (on the main actor).
4. Add an explicit `force: Bool` parameter to `runShortcut`; `skipCooldown` becomes a derived value (`force || skipCooldown`). Update the four wrapper functions (`startCharging`, `stopCharging`, `testStartCharging`, `testStopCharging`) accordingly. `stopCharging` gains a `force: Bool = false` parameter for symmetry, even if no caller uses it yet.

### Pseudocode

```swift
private func runShortcut(name: String, action: String, force: Bool) {
    let now = Date()
    if !force {
        // cooldown check (note: ticket 03 will move the timestamp write)
        let lastTime = action == "start" ? lastStartTime : lastStopTime
        guard now.timeIntervalSince(lastTime) >= cooldown else { return }
        // also: don't stack non-force calls behind an in-flight one
        guard inflight == nil else { return }
    }

    let previous = inflight
    isRunningShortcut = true
    lastError = nil

    inflight = Task.detached { [weak self] in
        await previous?.value   // serialize behind any in-flight call
        // ... existing process run logic ...
        await MainActor.run {
            guard let self else { return }
            // only clear isRunningShortcut if we are the latest task
            if self.inflight?.isCancelled != false || self.inflight == nil {
                self.isRunningShortcut = false
            }
            // simpler & equally correct:
            // self.isRunningShortcut = (the next inflight task in chain still running)
        }
    }
}
```

> The "is this the last task in the chain?" bit is fiddly. Simpler safe version: set `isRunningShortcut = false` at the end of every task, and have callers inspect `inflight` directly. Or have each task at end clear `inflight` only if it currently equals self.

### Call sites — verify no change required

- `startCharging(shortcutName:force:)` — already passes `force` through; just rename the inner arg.
- `stopCharging(shortcutName:)` — currently no `force`; add `force: Bool = false` for symmetry.
- `testStartCharging` / `testStopCharging` — call with `force: true` (was `skipCooldown: true`).
- `CycleEngine` callers — no changes; existing `force:` arguments at `CycleEngine.swift:127, 149, 164, 232, 296` continue to work.

## Acceptance

- Calling `startCharging(force: true)` while another shortcut is in flight enqueues and runs the new shortcut after the previous completes (does **not** drop it).
- Non-force calls within the cooldown window still return without queueing.
- Non-force calls while another non-force call is in flight still return without queueing (no redundant stacking).
- `swift build -c release` from `BurnCycle/` succeeds.
- Manual smoke test (optional but recommended):
  - Replace `/usr/bin/shortcuts` arg list with `/bin/sleep 5`.
  - Call `startCharging(force: false)` then immediately `startCharging(force: true)`.
  - Observe both processes run sequentially (visible via `ps`); the second waits ~5s and then runs.

## Notes

- Ticket 02 adds a 20s timeout on the subprocess. Implement 01 first so the queueing behaviour is in place before the timeout reshapes the task body.
- Ticket 03 moves the cooldown timestamp into the success branch. Coordinate so the cooldown logic remains coherent.
