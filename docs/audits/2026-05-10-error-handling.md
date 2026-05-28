# Error handling & UX failure-surface audit

> **Remediation status (2026-05-27):** addressed on branch `fix/audit-remediation`. See [2026-05-27-remediation-report.md](2026-05-27-remediation-report.md) for the per-finding Fixed / Partial / Deferred status.

**Date:** 2026-05-10  
**Auditor:** codex-reviewer (read-only pass)  
**Scope:** ChargingController, CycleEngine, BatteryMonitor, MiningManager, StressManager, HistoryRecorder, MainView, AppSettings, BurnCycleApp

---

## Summary

| Severity | Count |
|----------|-------|
| High     | 2     |
| Medium   | 6     |
| Low      | 7     |
| **Total**| **15**|

---

## High Severity

### H1 — `system_profiler` subprocess run is silently swallowed; health always shows 0% on failure

**File:** `BurnCycle/BurnCycle/Services/BatteryMonitor.swift:193`

```swift
try? proc.run()
proc.waitUntilExit()
```

`proc.run()` can throw (executable not found, permission denied). Using `try?` means the process never starts, `waitUntilExit()` returns immediately, `healthPercent` stays `0`, and the user sees 0% battery health — identical to a genuine 0% reading — with no message anywhere. There is no UI path that surfaces a `system_profiler` failure. The fix is to `do/catch` the `proc.run()` and either surface an error message in the UI or at minimum set `healthPercent` to a sentinel value (e.g. `-1`) that the view can render as "Unknown".

**Recovery affordance:** None. User cannot distinguish "health read failed" from "battery health is 0%".

---

### H2 — `HistoryRecorder` double-silences disk write failures; data loss is invisible

**File:** `BurnCycle/BurnCycle/Services/HistoryRecorder.swift:78–79`

```swift
if let data = try? encoder.encode(entries) {
    try? data.write(to: fileURL)
}
```

Both encode and write are `try?`. If the Application Support directory is missing permissions, the volume is full, or the directory creation at line 26 (`try? FileManager.default.createDirectory(...)`) silently fails, every `save()` call succeeds from Swift's perspective. The user's history is lost across launches. No `@Published` error property exists on `HistoryRecorder`, and `MainView` never reads one. The fix is to expose a `@Published var lastSaveError: String?` and surface a warning in the History panel.

**Recovery affordance:** None. The "Clear All" button is the only interactive element in the History panel; there is no retry path.

---

## Medium Severity

### M1 — Empty `catch` in `StressManager.setupMetal()` swallows Metal compilation errors

**File:** `BurnCycle/BurnCycle/Services/StressManager.swift:47`

```swift
} catch { }
```

If `makeLibrary(source:options:)` or `makeComputePipelineState` throws (shader syntax error, unsupported GPU), `pipelineState` remains `nil`. `start()` then skips the GPU branch silently via the `if let device, let commandQueue, let pipelineState` guard — the user sees "Stressing CPU+GPU" in the status label but GPU stress is not running. No distinction is made in the status label or anywhere in the UI. At minimum, `status` should be set to "Stress (CPU only — GPU unavailable)" and the error should be logged.

---

### M2 — Empty shortcut name passes through to `shortcuts run ""`; failure message is generic

**File:** `BurnCycle/BurnCycle/Services/ChargingController.swift:67` / `AppSettings.swift`

The Settings `TextField` for shortcut names accepts empty strings. `runShortcut(name:action:force:)` performs no guard against `name.isEmpty`. The shell invokes `/usr/bin/shortcuts run ""`, which fails with a non-zero exit and an stderr message. That message is surfaced as `lastError`, but the user sees a cryptic shortcuts-CLI error rather than "Shortcut name is required — please enter a name in Settings." The validation gap also affects the "Test" buttons, which silently show a red error without hinting that the field is empty.

---

### M3 — Verify-retry loop does not clear `charging.lastError`; both error channels can be set simultaneously

**File:** `BurnCycle/BurnCycle/Services/CycleEngine.swift:370–401` / `MainView.swift:72–79`

When `verifyPowerState()` calls `setError(...)`, `engine.errorMessage` is set (orange). At the same time, if the preceding `shortcuts run` had failed, `charging.lastError` is also set (red). Both messages are rendered in `MainView` sequentially with no visual grouping. The user sees two overlapping error lines that can appear contradictory (e.g. red "Shortcut failed" + orange "Charger not detected. Check cable and outlet.") when the root cause is a single transient CoAP failure. There is no coordination between the two error channels.

**Recovery affordance:** "Charger not detected" offers no in-UI action beyond Stop+Start. A "Retry Now" button that calls `verifyPowerState()` or re-runs the shortcut would reduce friction.

---

### M4 — `charging.lastError` is never cleared when cycling resumes normally; stale red text persists

**File:** `BurnCycle/BurnCycle/Services/ChargingController.swift:87, 169`

`lastError` is cleared at two points: (a) at the start of each `runShortcut` call (`lastError = nil`), and (b) on success. However, `CycleEngine` never explicitly resets `charging.lastError` during `clearMessages()`, `stop()`, or `onBatteryChanged()`. If a shortcut fails, sets `lastError`, but then the outlet recovers and the next automatic shortcut call happens to succeed, `lastError` is correctly cleared — but only after the next invocation. During the verify-retry window (up to ~60s), the stale red error remains visible even though the engine's `errorMessage` may have already been cleared by `onBatteryChanged`. From the user's perspective the error appears stuck.

---

### M5 — `xmrig` crash mid-drain: `terminationHandler` sets `isMining = false` but `CycleEngine` never notices or restarts

**File:** `BurnCycle/BurnCycle/Services/MiningManager.swift:54–61`

The `terminationHandler` sets `isMining = false` and `status = "Stopped"`. `CycleEngine.isLoadRunning()` checks `mining.isMining`, so on the next `manageLoad()` tick (up to 10s later), it detects the load has stopped. However, `loadThrottled` is `false` at this point and the engine only restarts load when `loadThrottled == true` in the `else if loadThrottled` branch. A spontaneous xmrig crash therefore permanently kills load for the remainder of the drain phase with no restart attempt and no user-visible notification beyond the status line in the Load row (which is only visible in `MainView` when `mining.isMining` is true — which it isn't). The user sees no indication that drain load silently stopped.

---

### M6 — Settings validation: `upperThreshold` and `lowerThreshold` sliders have disjoint ranges but no relationship enforcement

**File:** `BurnCycle/BurnCycle/Views/MainView.swift:121–126` / `AppSettings.swift`

`upperThreshold` is constrained to `50...100` and `lowerThreshold` to `5...50`. The ranges share the boundary at 50, making it possible to set `upperThreshold = 50` and `lowerThreshold = 50`. In `beginCycling()`:

```swift
if pct >= Int(settings.upperThreshold) {
    transitionToDraining()
} else {
    transitionToCharging()
}
```

With both at 50 and the battery exactly at 50%, this would flip states every tick. `onBatteryChanged` then triggers `transitionToCharging` or `transitionToDraining` in rapid succession, firing shortcuts every 30s (cooldown floor). There is no guard ensuring `upperThreshold > lowerThreshold` and no UI warning about overlapping thresholds.

---

## Low Severity

### L1 — `BatteryMonitor.updateFast()`: IOPowerSources block is silently skipped on failure; `percentage` stays stale

**File:** `BurnCycle/BurnCycle/Services/BatteryMonitor.swift:88–102`

If `IOPSCopyPowerSourcesInfo()` or `sources.first` returns nil (possible in sandboxed or VM environments), all three published values (`percentage`, `isPluggedIn`, `isCharging`) are not updated. They silently retain their previous values. For `isPluggedIn` especially, a stale read can cause `CycleEngine` to make wrong transition decisions. A debug-level log or a `healthPercent = 0` sentinel would help diagnosis.

---

### L2 — Force unwrap `first!` in `HistoryRecorder` file URL initializer

**File:** `BurnCycle/BurnCycle/Services/HistoryRecorder.swift:24`

```swift
FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
```

`urls(for:in:)` is documented to always return at least one element for `.userDomainMask` on macOS, so this is safe in practice. However, if the sandbox entitlements are misconfigured, it returns an empty array and the app crashes at launch before any UI appears. Use `guard let` with a fallback to a temp directory and surface an alert.

---

### L3 — `MiningManager.readLog()`: log truncation `try?` silently fails; stale hashrate shown after restart

**File:** `BurnCycle/BurnCycle/Services/MiningManager.swift:35`

```swift
try? "".write(toFile: logPath, atomically: true, encoding: .utf8)
```

If the truncation fails (e.g. disk full), the old log is parsed on the next `readLog()` call and the displayed hashrate reflects the previous run rather than the current one. This is cosmetic but confusing.

---

### L4 — Menu bar popover does not display `engine.errorMessage` or `charging.lastError`

**File:** `BurnCycle/BurnCycle/BurnCycleApp.swift:108–204`

The `MenuBarPopover` shows battery %, health, cycles, and load status, but does not show `engine.errorMessage` or `charging.lastError`. A user running with the window closed and menu bar active will see no indication of a "Charger not detected" error.

---

### L5 — `handleWake()` clears messages before `startAfterWake()` runs; race window

**File:** `BurnCycle/BurnCycle/Services/CycleEngine.swift:127–143`

`clearMessages()` is called inside the `Task` before `startAfterWake()`. If the 2-second sleep is still in flight and another message arrives (e.g. battery observer fires), that message is cleared again unconditionally on wake completion. This is a narrow window but could suppress a legitimate post-wake error.

---

### L6 — `StressManager` has no error-surfacing property; `MainView` cannot show GPU-unavailable state

**File:** `BurnCycle/BurnCycle/Services/StressManager.swift`

`StressManager` exposes only `isRunning: Bool` and `status: String`. There is no `lastError` or similar. If Metal initialisation fails entirely (no GPU, entitlement missing), `start()` only starts CPU tasks with no way for `MainView` to distinguish "stress running (CPU+GPU)" from "stress running (CPU only)" beyond reading the status string — which is set to "Stressing CPU+GPU" regardless (line 53).

---

### L7 — Preflight test races against `charging.lastError` display in the Testing state

**File:** `BurnCycle/BurnCycle/Services/CycleEngine.swift:184–260`

During preflight, `runPreflightTest()` fires shortcut calls that may fail and set `charging.lastError` (red). At the same time, `engine.statusMessage` (gray) is showing "Testing: turning outlet OFF...". Both are shown in `MainView`. If the shortcut fails during preflight but the outlet state changes anyway (flaky HomeKit), the user sees a red error and a gray status simultaneously with no explanation of which is authoritative. The preflight path should reset `charging.lastError` at entry and after each shortcut call completes.

---

## Cross-Cutting Observations

### Error channel architecture

The app has three independent error channels rendered unconditionally in `MainView`:

1. `charging.lastError` — red, from subprocess stderr
2. `engine.errorMessage` — orange, from engine logic
3. `engine.statusMessage` — gray, transient

There is no coordination or precedence rule between channels 1 and 2. Both can be set simultaneously (M3, L7). Consider a unified `engine.activeAlert` that folds `charging.lastError` into the engine's error model so there is a single source of truth.

### Recovery affordances

"Charger not detected" (H2, M3) and history save failure (H2) have no in-UI recovery actions. The pattern of showing an error with a co-located "Retry" or "Fix" button (e.g. opening Settings) would improve recoverability significantly.

### Stale error persistence

`charging.lastError` has no TTL or explicit cross-engine clear. Combined with the verify-retry window (~60s), users can see a red error for a full minute after the condition has resolved (M4).

---

## Files Audited

- `/Users/hongjunwu/Documents/Git/battery-burner/BurnCycle/BurnCycle/Services/ChargingController.swift`
- `/Users/hongjunwu/Documents/Git/battery-burner/BurnCycle/BurnCycle/Services/CycleEngine.swift`
- `/Users/hongjunwu/Documents/Git/battery-burner/BurnCycle/BurnCycle/Services/BatteryMonitor.swift`
- `/Users/hongjunwu/Documents/Git/battery-burner/BurnCycle/BurnCycle/Services/MiningManager.swift`
- `/Users/hongjunwu/Documents/Git/battery-burner/BurnCycle/BurnCycle/Services/StressManager.swift`
- `/Users/hongjunwu/Documents/Git/battery-burner/BurnCycle/BurnCycle/Services/HistoryRecorder.swift`
- `/Users/hongjunwu/Documents/Git/battery-burner/BurnCycle/BurnCycle/Views/MainView.swift`
- `/Users/hongjunwu/Documents/Git/battery-burner/BurnCycle/BurnCycle/Models/AppSettings.swift`
- `/Users/hongjunwu/Documents/Git/battery-burner/BurnCycle/BurnCycle/BurnCycleApp.swift`
