# Ticket 06 — Manual "Re-test outlet" button

**Severity:** Minor (escape hatch)
**Files:** `BurnCycle/BurnCycle/Services/CycleEngine.swift`, `BurnCycle/BurnCycle/Views/MainView.swift`
**Related:** Pairs with Ticket 04 (preflight cache). Implement after Ticket 07 if Ticket 07 is in flight in the same agent.

## Problem

Ticket 04 added a 30-minute in-memory preflight cache. Ticket-04-followup invalidates it on verify-fail. But there is no way for the user to **manually** invalidate it — e.g., they moved the smart plug to a different outlet, or swapped the smart plug entirely, and want the next Start to re-run the preflight even though the cycle hasn't failed yet.

Workaround today: quit and relaunch the app. We should give the user a button.

## Fix

### CycleEngine.swift

Add a public method:

```swift
/// User-initiated cache invalidation. The next `start()` will re-run preflight
/// instead of skipping. No-op if no cache exists or if the engine is currently
/// running (don't disturb an active cycle).
func invalidatePreflightCache() {
    guard !isRunning else { return }
    lastSuccessfulPreflight = nil
}

/// Read-only view of the cache state for UI affordance enable/disable.
var hasCachedPreflight: Bool { lastSuccessfulPreflight != nil }
```

`lastSuccessfulPreflight` is already declared `private`; keep it private and route through the methods above.

### MainView.swift — Settings panel

Place the new button **inside** the "Outlet Control" section of the Settings panel, just below the two existing "Test" rows for Start/Stop shortcuts (around line 200, after the second `TextField`).

```swift
HStack {
    Spacer()
    Button("Re-test outlet on next Start") {
        engine.invalidatePreflightCache()
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .disabled(engine.isRunning || !engine.hasCachedPreflight)
}
```

The button is disabled when the engine is running (we shouldn't disturb an active cycle) or when there is no cache to clear.

No new error/status message wiring. The user feedback is the button toggling from enabled → disabled the moment they press it.

## Acceptance

- Cold launch (no cache yet) → button is disabled.
- Press Start → preflight passes → press Stop. Button is now enabled.
- Press the button. Button becomes disabled. Press Start. Preflight runs again (full duration, full shortcut calls).
- While `engine.isRunning == true` (cycle active or preflight in flight), the button is always disabled.
- `swift build -c release` succeeds.

## Notes

- Don't expose `lastSuccessfulPreflight` directly; keep the API surface narrow.
- Don't move the button to the main panel — it's an advanced action and belongs with the other outlet-control settings.
