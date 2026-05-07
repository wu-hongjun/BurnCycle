# Ticket 03 — Record cooldown only on success

**Severity:** Major
**File:** `BurnCycle/BurnCycle/Services/ChargingController.swift`
**Related:** Implement after Tickets 01 and 02.

## Problem

`runShortcut` records the cooldown timestamp **before** the shortcut runs:

```swift
if action == "start" { lastStartTime = now } else { lastStopTime = now }
isRunningShortcut = true
lastError = nil
Task.detached { ... process.run() ... }
```

A failed shortcut (e.g., CoAP error returned within 1s) burns the full 30-second cooldown window. The user sees "Shortcut failed", clicks the test button again, and is silently blocked for half a minute with no visible reason. The verify-retry path uses `force: true` so it bypasses the cooldown, but `transitionToCharging` does not, and neither do user-initiated test buttons.

## Fix

Move the cooldown timestamp assignment into the success branch, after `process.terminationStatus == 0` is observed.

### Implementation

Inside the `Task.detached` body, after determining `succeeded`:

```swift
await MainActor.run { [weak self] in
    guard let self else { return }
    self.isRunningShortcut = false
    if succeeded {
        // Record cooldown only on actual successful invocation
        if action == "start" { self.lastStartTime = Date() }
        else                 { self.lastStopTime  = Date() }
        self.lastError = nil
    } else {
        self.lastError = errMsg ?? "Shortcut failed"
    }
}
```

Remove the old pre-launch assignment from `runShortcut`'s synchronous prelude.

### Edge case: rapid double-trigger

Without the pre-launch timestamp, two calls fired in the same run-loop tick could both pass the cooldown check and both spawn a shortcut. Ticket 01's queue prevents that for non-force calls (the second is dropped because `inflight != nil`). Verify the queueing path still rejects the second call before it spawns.

## Acceptance

- A failing `startCharging(force: false)` call does **not** update `lastStartTime`. A second call within 30s runs (and may also fail) instead of being silently dropped.
- A succeeding `startCharging(force: false)` call updates `lastStartTime`; a second call within 30s is silently dropped (current behaviour preserved).
- The two cooldowns (`start` / `stop`) remain independent.
- `lastError` is cleared on success and populated on failure (no regression from Tickets 01/02).
- `swift build -c release` succeeds.

## Smoke test

1. Make `/usr/bin/shortcuts run NotARealShortcut` the test command — it exits non-zero immediately.
2. Click the "Test" button twice in quick succession.
3. Both invocations run; both produce a `lastError`. (Without this fix, only the first runs.)
4. Replace with a real shortcut name; click Test twice.
5. First runs and succeeds; second is suppressed by cooldown.
