# Performance & energy audit

> **Remediation status (2026-05-27):** addressed on branch `fix/audit-remediation`. See [2026-05-27-remediation-report.md](2026-05-27-remediation-report.md) for the per-finding Fixed / Partial / Deferred status.

**Date:** 2026-05-10  
**Scope:** BurnCycle macOS app — idle-state energy cost, polling cadences, SwiftUI render pressure, disk I/O, memory  
**Auditor:** codex-reviewer (automated static analysis)  
**Status:** 8 findings (2 high, 4 medium, 2 low)

---

## Executive summary

The `system_profiler` throttle introduced in ticket-09 was the right call. The next round of wins centres on three areas: (1) the `fastTimer` doing a full `IOServiceGetMatchingService` + `IORegistryEntryCreateCFProperties` round-trip every 2 seconds even when the battery percentage hasn't changed; (2) `SystemMonitor` opening a second independent `AppleSmartBattery` handle every 3 seconds, duplicating work already done by `BatteryMonitor`; and (3) the `combineLatest` subscriber firing `history.observe` on every slow-timer tick regardless of whether any value actually changed.

---

## Findings

### F-01 — fastTimer IOKit CFDictionary allocation every 2 s (HIGH)

**File:** `BurnCycle/BurnCycle/Services/BatteryMonitor.swift`, lines 86–152  
**Category:** Performance / Energy

`updateFast()` calls `IOServiceGetMatchingService` + `IORegistryEntryCreateCFProperties` on the `AppleSmartBattery` service on every tick. This allocates and immediately releases a large `CFMutableDictionary` 30 times per minute, 1 800 times per hour, ~43 000 times per 24 h. Battery percentage changes at most once per minute; temperature and voltage drift slowly. The 2-second tick is justified only for `isPluggedIn`/`isCharging` transitions, which could be detected with a much lighter `IOPSNotificationCreateRunLoopSource` push notification instead.

**Suggestion:** Register an `IOPowerSources` change notification via `IOPSNotificationCreateRunLoopSource` for plug/unplug events. Increase the `fastTimer` interval to 5 s (or 10 s) for the remaining slow-drifting values (temperature, voltage, `chargingWatts`, `currentCapacityMAh`). At 5 s the allocation rate drops by 60 %; at 10 s by 80 %. Alternatively, cache the last-known values and skip the `IORegistryEntryCreateCFProperties` call when the power-source snapshot shows no `isPluggedIn` transition.

---

### F-02 — SystemMonitor opens a third AppleSmartBattery handle every 3 s (HIGH)

**File:** `BurnCycle/BurnCycle/Services/SystemMonitor.swift`, lines 222–245  
**Category:** Performance / Energy

`updatePower()` independently calls `IOServiceGetMatchingService("AppleSmartBattery")` + `IORegistryEntryCreateCFProperties` every 3 seconds to obtain `Voltage` and `Amperage`. `BatteryMonitor.updateFast()` already reads those exact fields (`dict["Voltage"]`, `dict["Amperage"]`) every 2 seconds and publishes the computed result as `chargingWatts`. This means the system sustains two concurrent IOKit dictionary allocations against the same service (one every 2 s from `BatteryMonitor`, one every 3 s from `SystemMonitor`), adding up to ~50 additional CFDictionary allocations per minute with no new information.

**Suggestion:** Remove `updatePower()` from `SystemMonitor`. Expose `battery.chargingWatts` (already `@Published`) directly to the views that need watt readings, or pass the `BatteryMonitor` reference into `SystemMonitor` and read the already-computed value. This eliminates ~20 IOKit allocations per minute entirely.

---

### F-03 — combineLatest fires history.observe on every slowTimer tick, not only on change (MEDIUM)

**File:** `BurnCycle/BurnCycle/BurnCycleApp.swift`, lines 35–43  
**Category:** Performance / Maintainability

`battery.$cycleCount.combineLatest(battery.$healthPercent, battery.$fullChargeCapacityMAh)` emits whenever **any** of the three publishers emits — including re-emissions of the same value. `slowTimer` fires every 60 s and calls `updateSlow()`, which assigns to `cycleCount`, `serial`, `designCapacityMAh`, and `fullChargeCapacityMAh`. Even when the values are identical to the previous tick, each `@Published` assignment calls `objectWillChange`, causing `combineLatest` to re-fire three times per 60-second cycle. `HistoryRecorder.observe` has a guard (`cycleCount != lastRecordedCycleCount`) that prevents a spurious disk write, but the upstream pipeline still wakes the Combine graph and executes the `Task { @MainActor }` dispatch on every slow tick.

**Suggestion:** Add `.removeDuplicates()` on each upstream publisher before the `combineLatest`, or use a single `objectWillChange.debounce(0.5s)` on `BatteryMonitor` and perform value equality checks in the sink. This suppresses the no-op pipeline activations entirely.

```swift
historyObserver = battery.$cycleCount.removeDuplicates()
    .combineLatest(
        battery.$healthPercent.removeDuplicates(),
        battery.$fullChargeCapacityMAh.removeDuplicates()
    )
    .sink { ... }
```

---

### F-04 — batteryObserver in CycleEngine fires on every fastTimer tick at 2 s (MEDIUM)

**File:** `BurnCycle/BurnCycle/Services/CycleEngine.swift`, lines 75–79  
**Category:** Performance

`battery.$percentage.sink` triggers `onBatteryChanged` every time `percentage` is assigned. `updateFast()` unconditionally assigns `percentage = capacity` even when the value hasn't changed, so the Combine sink fires 30 times per minute. `onBatteryChanged` contains threshold comparisons and potential `startCharging`/`stopCharging` calls — it should only run when the value meaningfully changes.

**Suggestion:** Add `.removeDuplicates()` to the `batteryObserver` subscription:

```swift
batteryObserver = battery.$percentage
    .removeDuplicates()
    .sink { [weak self] pct in ... }
```

This reduces `onBatteryChanged` invocations from 30/min to at most 1/min during normal operation.

---

### F-05 — MiningManager log-polling timer persists at 2 s even when xmrig is idle (MEDIUM)

**File:** `BurnCycle/BurnCycle/Services/MiningManager.swift`, lines 70–78  
**Category:** Performance / Energy

`logTimer` fires every 2 seconds to call `readLog()`, which opens a `FileHandle`, seeks, reads, and closes the xmrig log file. This I/O happens continuously while `isMining == true`. However, xmrig only writes a hashrate line every 5 seconds (configured via `--print-time 5`). The 2-second poll rate is therefore 2.5x faster than the data rate, performing needless file I/O on approximately 50 % of ticks.

**Suggestion:** Increase `logTimer` interval to 6 s (slightly longer than xmrig's 5 s print interval) to guarantee every hashrate line is captured while eliminating roughly 60 % of redundant file reads.

---

### F-06 — SwiftUI @Published storm: slowTimer assigns 4 fields, triggering 4 separate renders (MEDIUM)

**File:** `BurnCycle/BurnCycle/Services/BatteryMonitor.swift`, lines 156–177  
**Category:** Performance / SwiftUI

`updateSlow()` assigns to `cycleCount`, `serial`, `designCapacityMAh`, and `fullChargeCapacityMAh` as four separate `@Published` property assignments. Each assignment sends `objectWillChange` individually, which can cause SwiftUI to schedule up to four distinct re-render passes in the same run-loop turn. While SwiftUI coalesces many updates within a single run-loop, `@MainActor` assignments via `Task { @MainActor }` closures can land in separate run-loop turns depending on the Combine scheduler.

**Suggestion:** Batch slow-timer updates into a single method that assigns all fields before any `objectWillChange` notification is processed. This can be achieved by using a value-type snapshot struct and a single `@Published` property, or by temporarily suppressing `objectWillChange` with a manual `send()` at the end of the batch.

---

### F-07 — Deep-idle state: SystemMonitor timer runs at 3 s when engine is stopped (LOW)

**File:** `BurnCycle/BurnCycle/Services/SystemMonitor.swift`, lines 58–75  
**Category:** Energy

`SystemMonitor.startMonitoring()` is called once at app launch and never stopped while the app is open (`stopMonitoring()` exists but is never called in the current `AppServices.init` flow). When `engine.isRunning == false`, CPU/GPU readings are displayed in the main window but are not needed by the engine for load decisions. The IOReport GPU sampling (`IOReportCreateSamples` + `IOReportCreateSamplesDelta`) runs every 3 s regardless.

**Suggestion:** Consider pausing `SystemMonitor` (or increasing its interval to 10–15 s) when `engine.isRunning == false`. Alternatively, tie `SystemMonitor.stopMonitoring()` to `CycleEngine.stop()` and `startMonitoring()` to `CycleEngine.start()`. The UI can show stale values or a "–" placeholder when monitoring is paused.

---

### F-08 — LSUIElement = false: app appears in Dock, increasing launch footprint (LOW)

**File:** `BurnCycle/BurnCycle/Info.plist`  
**Category:** Energy / Behavior

`LSUIElement` is set to `<false/>`, making BurnCycle a regular foreground app with a Dock icon, application menu, and standard window management. The app primarily lives in the menu bar (`MenuBarExtra`) and has a single utility window. Agent/background apps (`LSUIElement = true`) have a lighter OS footprint: no Dock tile, no app-switcher entry, and reduced event-dispatch overhead. The current `AppDelegate.applicationShouldHandleReopen` logic would not be needed if the window is always accessible from the menu bar.

**Suggestion:** Evaluate setting `LSUIElement = true`. Users would open the window via the menu bar popover's "Open Window" button (already implemented). This removes Dock overhead and signals to the OS that BurnCycle is a background utility, potentially improving scheduling priority for the monitoring timers relative to foreground apps.

---

## Idle-state polling summary

| Timer | Interval | Fires when idle? | Recommendation |
|---|---|---|---|
| `BatteryMonitor.fastTimer` | 2 s | Yes | Raise to 5–10 s; use IOPSNotification for plug events |
| `BatteryMonitor.slowTimer` | 60 s | Yes | Acceptable; add `.removeDuplicates()` downstream |
| `BatteryMonitor.healthTimer` | 1 h | Yes | Acceptable (ticket-09 already addressed) |
| `SystemMonitor.timer` | 3 s | Yes | Pause when `engine.isRunning == false` |
| `MiningManager.logTimer` | 2 s | Only when mining | Raise to 6 s |
| `CycleEngine.timer` | 10 s | Only when running | Acceptable |

---

## Memory notes

- `HistoryRecorder.entries` is an unbounded `[HistoryEntry]` array. Growth rate is bounded by cycle count (at most a few hundred entries for multi-year use) so this is not a material concern today. If entries ever exceeded ~10 000 (unlikely), a cap or pagination would be warranted.
- `StressManager` allocates a 2 M-float Metal buffer (`bufSize * 4` = 8 MB) on `start()` and holds it for the lifetime of the `gpuTask`. The buffer is released when the Task completes on `stop()`. No unbounded growth.

## Build artifact note

- Bundled `xmrig` binary: **7.0 MB** (single-arch `arm64`, reasonable for a native miner binary). Not a concern.

