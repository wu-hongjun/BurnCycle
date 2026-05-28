> **Status (2026-05-27):** Implemented in `d6ac33f` (fix: cache preflight result and debounce settings observer) with follow-up `18b4aaa` (fix: invalidate preflight cache when verifyPowerState gives up) — 30-min cache, `startAfterWake()` skips preflight on wake, cache cleared on preflight failure and on verify exhaustion. See `CycleEngine.swift`.

# Ticket 04 — Cache preflight and skip on wake

**Severity:** Major
**File:** `BurnCycle/BurnCycle/Services/CycleEngine.swift`
**Related:** Independent of Tickets 01–03 (different file). Can be implemented in parallel by a separate agent. Pairs with Ticket 05 in the same file — same agent should own both.

## Problem

`runPreflightTest` (`CycleEngine.swift:111-182`) makes 2–3 shortcut calls every `start()` with 8s waits in between:

- Plugged-in path: stop → wait 8s → start → wait 8s → verify (2 calls).
- On-battery path: start → wait 8s → stop → wait 8s → start → wait 5s → verify (3 calls).

`handleWake` (`CycleEngine.swift:86-95`) calls `start()` on every wake-from-sleep when `pauseOnSleep` is on (default true). Every lid-open re-runs the entire preflight. With a 90% per-call CoAP success rate, the on-battery preflight succeeds only ~73% of the time, so the app refuses to start with `"Outlet test failed"` on a meaningful fraction of wake events.

The outlet was already verified at the *previous* `start()`. Re-verifying on every wake is unnecessary.

## Fix

Two complementary changes:

### A. Cache preflight result

- Add `private var lastSuccessfulPreflight: Date?` to `CycleEngine`.
- On preflight success (both Case A and Case B branches), set `lastSuccessfulPreflight = Date()`.
- On `start()`, before kicking off `runPreflightTest`, check:
  ```swift
  if let last = lastSuccessfulPreflight,
     Date().timeIntervalSince(last) < preflightCacheTTL {
      // skip preflight; jump straight to begin
      mismatchWarning = nil
      beginCycling()
      return
  }
  ```
- Add a constant near the other `private let` declarations:
  ```swift
  private let preflightCacheTTL: TimeInterval = 30 * 60   // 30 minutes
  ```
- On failure, clear `lastSuccessfulPreflight = nil` so the next `start()` retries from scratch.
- On `stop()` user action, leave the cache intact — it's still valid for ~30 min.

### B. Skip preflight on wake

- `handleWake` (`CycleEngine.swift:86-95`) currently calls `self.start()`. Change to a new internal entry point that bypasses preflight unconditionally:

  ```swift
  private func startAfterWake() {
      guard !isRunning else { return }
      isRunning = true
      mismatchWarning = nil
      battery.update()
      system.update()
      beginCycling()
  }
  ```

  Use this from `handleWake` instead of `start()`.

- Rationale: the cycle was running before sleep, which means preflight had already succeeded. macOS sleep does not move the laptop between Wi-Fi networks or unplug the smart plug; if anything has changed, the verify-power-state cycle (`verifyTicksRemaining` in `tick`) will catch it within ~20s and trigger normal retry behaviour.

### C. Optional: user-visible cache invalidation

- Not required for this ticket. Future enhancement: a "Re-test outlet" button in Settings that sets `lastSuccessfulPreflight = nil` and forces preflight on next `start()`.

## Acceptance

- Cold launch → press Start → full preflight runs.
- Press Stop, then press Start within 30 minutes → preflight is skipped, `mismatchWarning` is nil, cycling begins immediately, no `shortcuts` calls during the start.
- Press Stop, wait >30 minutes, press Start → preflight runs again.
- Sleep/wake while cycle is running with `pauseOnSleep = true` → on wake, no preflight calls; cycle resumes via `beginCycling`.
- If preflight fails, `lastSuccessfulPreflight` is cleared and the next Start retries preflight.
- `swift build -c release` succeeds.

## Smoke test

1. Launch app, press Start, wait for preflight to pass, press Stop.
2. Watch `Console.app` filtered to `shortcuts` events. Press Start. No new `shortcuts` events fire. Cycle begins.
3. Close the lid (or run `pmset sleepnow` in Terminal). Open the lid. No `shortcuts` events fire on wake; the cycle resumes.
4. Quit and relaunch the app. Press Start. Preflight runs (full set of `shortcuts` calls).

## Notes

- Do not extend the TTL beyond 30 minutes without thinking about home-network changes (e.g., user moves to a coffee shop with their MacBook — though that already breaks the use-case). 30 min is a reasonable balance.
- The cache lives in memory only. App restart re-runs preflight by design.
