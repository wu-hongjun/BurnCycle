# Code quality & Swift idioms audit

> **Remediation status (2026-05-27):** addressed on branch `fix/audit-remediation`. See [2026-05-27-remediation-report.md](2026-05-27-remediation-report.md) for the per-finding Fixed / Partial / Deferred status.

**Date:** 2026-05-10  
**Scope:** `BurnCycle/BurnCycle/` — 10 Swift files, ~2 000 lines  
**Swift tools version:** 6.0 · Target: macOS 14  
**Auditor:** automated read-only pass

---

## 1. Force-unwrap `!` audit

| # | File | Line | Expression | Can it crash? |
|---|------|------|------------|---------------|
| 1 | `HistoryRecorder.swift` | 24 | `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!` | **Extremely unlikely but theoretically yes.** The docs say the array "contains at least one object" for `.applicationSupportDirectory` with `.userDomainMask`, but `first` on an empty array returns `nil` and the force-unwrap would crash. In practice this never happens on a normal macOS installation, but it is the only force-unwrap in the codebase. Prefer `guard let dir = … .first else { return }` and surface the error through the existing `@Published` pattern or a log. |

**Verdict:** One low-risk force-unwrap. Not a production hazard, but easy to fix.

---

## 2. `try?` swallowing

There are 12 `try?` sites. They fall into three categories:

### 2a. Intentionally silent — appropriate
| File | Lines | Rationale |
|------|-------|-----------|
| `CycleEngine.swift` | 128, 194, 202, 227, 235, 241 | `Task.sleep` cancellation is the only throw; isCancelled is already checked immediately after. `try?` here is idiomatic. |
| `ChargingController.swift` | 125 | Same — watchdog sleep cancellation. |
| `MiningManager.swift` | 102 | Same — graceful-exit poll sleep. |

### 2b. Suppressed I/O errors — worth noting
| File | Line | Issue |
|------|------|-------|
| `BatteryMonitor.swift` | 193 | `try? proc.run()` — if `system_profiler` can't launch (wrong path, permissions), `healthPercent` silently stays 0 with no user-visible feedback. A `do/catch` writing to a `@Published var healthError: String?` would be more informative. |
| `MiningManager.swift` | 35 | `try? "".write(toFile:…)` — log truncation failure is silent. Low-stakes but worth at least an `assertionFailure` in debug builds. |
| `HistoryRecorder.swift` | 26, 79 | `try? createDirectory` and `try? data.write(to:)` — persistence failures are invisible to the user. The recorder has no error surface. At minimum, a `print`/`os_log` would help diagnose "where did my history go?" reports. |
| `HistoryRecorder.swift` | 65, 68, 78 | Load/decode/encode — silent corruption recovery is fine for decode (correct), but encode failure drops history on the floor with no signal. |

**Opinion:** For a hobby project `try?` is acceptable in persistence code, but the `proc.run()` suppression in `BatteryMonitor` is the weakest spot — it masks a real launch failure.

---

## 3. Reference cycles

No strong-capture cycles were found. All closure sites that capture `self` inside `ObservableObject` classes use `[weak self]` correctly:

- `BatteryMonitor` timer closures: `[weak self]` ✓  
- `CycleEngine` `settingsObserver`, `batteryObserver`, sleep/wake observers: `[weak self]` ✓  
- `ChargingController.runShortcut` outer `Task.detached`: `[weak self]` ✓  
- `MiningManager` `terminationHandler`, log timer: `[weak self]` ✓  
- `AppServices.historyObserver`: `[weak self]` ✓  

One pattern worth watching: `CycleEngine` registers `NSWorkspace` notification observers in `init` (`sleepObserver`, `wakeObserver`) but never removes them explicitly. `NSWorkspace.notificationCenter` holds the observer token as a strong reference. Because `CycleEngine` is owned by `AppServices` for the app lifetime this is harmless today, but if `CycleEngine` were ever short-lived the observers would survive it. Consider removing them in a `deinit` or using `withObservationTracking`.

---

## 4. Naming

| Location | Name | Issue |
|----------|------|-------|
| `BatteryMonitor` line 73 | `func update()` | Documented as "immediate refresh" but delegates to `updateFast()`, skipping cycle count and health. The name implies a full refresh. `refreshFastMetrics()` or `updatePowerState()` would be clearer. |
| `CycleEngine` line 433 | `manageLoad()` | Does three distinct things: enforces a safety-margin early stop, checks the hysteresis counters, and potentially starts/stops load. A name like `tickLoadPolicy()` or decomposing into `enforceLoadSafetyMargin()` + `tickLoadHysteresis()` would be clearer. |
| `ChargingController` line 59/63 | `testStartCharging` / `testStopCharging` | The word "test" is ambiguous — could mean unit-test or preflight test. Since these are shortcut invocations with `force: true`, `forceStartCharging` / `forceStopCharging` or `runStartShortcutForced` would remove the ambiguity. |
| `CycleEngine` line 180 | `var hasCachedPreflight: Bool` | The property is a read-only view computed from `lastSuccessfulPreflight != nil`. Fine name, but it should be explicitly `private(set)` to prevent external mutation; currently it's a `var` computed property, so external write is impossible, but a `let`-style computed property makes intent clearer. |
| `MiningManager` line 14 | `static let defaultWallet` | "default" implies it's configurable and this is the fallback. That's accurate, but the wallet address is the developer's personal XMR address. A comment explaining that `walletOverride` takes precedence and this is the built-in fallback would prevent future confusion. |

---

## 5. Boolean parameter pollution

Two call-site families use `force: Bool = false`:

### `ChargingController.startCharging/stopCharging(shortcutName:force:)`

Call sites:
| File | Line | `force` value | Context |
|------|------|---------------|---------|
| `CycleEngine.swift` | 192 | `false` (default) | Normal stop during preflight |
| `CycleEngine.swift` | 200 | `true` | Restore after preflight OFF test |
| `CycleEngine.swift` | 225, 232, 240 | `true` | Preflight case B |
| `CycleEngine.swift` | 312 | `true` | Critical battery emergency |
| `CycleEngine.swift` | 376, 389 | `true` | Retry after verify failure |
| `CycleEngine.swift` | 488, 500 | `false` (default) | Normal transitions |
| `ChargingController.swift` | 52, 56 | forwarded | Public entry points |

**Recommendation:** Replace `force: Bool` with a typed enum:

```swift
enum ShortcutUrgency {
    /// Respects cooldown and in-flight guard. Used for normal cycle transitions.
    case normal
    /// Bypasses cooldown and queues behind in-flight tasks. Used for safety-critical
    /// actions (critical battery, preflight verification, forced retries).
    case force
}
```

This makes call sites self-documenting:
```swift
charging.startCharging(shortcutName: …, urgency: .force)   // clear intent
charging.stopCharging(shortcutName: …, urgency: .normal)    // clear intent
```

Bonus: a third case `.test` could replace `testStartCharging`/`testStopCharging`.

---

## 6. Magic numbers

All numbers that should be in a central `Constants` or `BurnCycleConstants` struct:

| File | Line | Value | Meaning |
|------|------|-------|---------|
| `BatteryMonitor.swift` | 44 | `2` | Fast poll interval (seconds) |
| `BatteryMonitor.swift` | 49 | `60` | Slow poll interval (seconds) |
| `BatteryMonitor.swift` | 56 | `healthMinInterval` (already a `let`) | Good — already named |
| `BatteryMonitor.swift` | 143 | `1_000_000` | mV·mA → W divisor — a comment explains it but a named constant (`milliVoltMilliAmpToWatts`) would be explicit |
| `ChargingController.swift` | 34 | `30` | Cooldown between non-forced shortcut calls (seconds) |
| `ChargingController.swift` | 38 | `20` | Per-invocation subprocess timeout (seconds) |
| `CycleEngine.swift` | 37 | `3` (`criticalBattery`) | Already a `let` — good, but not in a shared Constants |
| `CycleEngine.swift` | 38 | `30 * 60` (`preflightCacheTTL`) | Already a `let` — good |
| `CycleEngine.swift` | 36 | `80` (`externalLoadThreshold`) | Already a `let` — good |
| `CycleEngine.swift` | 51, 52 | `3`, `6` (`highLoadStopThreshold`, `lowLoadResumeThreshold`) | Already `let`s — good |
| `CycleEngine.swift` | 273 | `10` | Cycle timer interval (seconds) |
| `CycleEngine.swift` | 391, 490, 509 | `2` | Verify ticks before checking power state (implies ~20s) |
| `CycleEngine.swift` | 437 | `3` | Safety margin above lower threshold (%) — **distinct from `criticalBattery`**, but looks identical |
| `CycleEngine.swift` | 478 | `95` | "Our load running + CPU/GPU near 100%" threshold — documented only in a comment |
| `SystemMonitor.swift` | 65 | `3` | System monitor poll interval (seconds) |
| `MiningManager.swift` | 73 | `1024 * 1024 * 2` | Metal buffer size (2M floats for GPU stress) |
| `MainView.swift` | 309 | `18` | History row height (points) |
| `MainView.swift` | 310 | `5` | Max visible history rows before scroll |

**Recommendation:** Create `Sources/BurnCycle/Constants.swift` with a caseless enum:

```swift
enum Constants {
    enum Battery {
        static let fastPollInterval: TimeInterval = 2
        static let slowPollInterval: TimeInterval = 60
        static let healthPollInterval: TimeInterval = 3600
        static let criticalPercent = 3
        static let safetyMarginPercent = 3   // stop load this many % above lower threshold
    }
    enum Charging {
        static let shortcutCooldown: TimeInterval = 30
        static let shortcutTimeout: TimeInterval = 20
        static let preflightCacheTTL: TimeInterval = 30 * 60
        static let verifyTickCount = 2
    }
    enum Load {
        static let externalThresholdPercent: Double = 80
        static let runningThresholdPercent: Double = 95
        static let highLoadStopTicks = 3
        static let lowLoadResumeTicks = 6
    }
    enum UI {
        static let historyRowHeight: CGFloat = 18
        static let maxVisibleHistoryRows = 5
    }
}
```

The inline `private let` constants in `CycleEngine` and `ChargingController` are better than raw literals, but they are scattered and cannot be cross-referenced (e.g., the `safetyMargin = lowerThreshold + 3` on line 437 is a different `3` from `criticalBattery = 3` — easy to conflate).

---

## 7. Type inference ambiguity

| File | Line | Expression | Issue |
|------|------|------------|-------|
| `SystemMonitor.swift` | 49 | `private var gpuSubscription: CFTypeRef?` | The actual value stored is `Unmanaged<CFTypeRef>.takeRetainedValue()` — a `CFTypeRef`. The declared type is correct but the existential `CFTypeRef` loses the actual opaque subscription type. This is an IOReport API limitation, not a code smell, but a comment explaining why `CFTypeRef` (rather than a concrete type) is used here would prevent future confusion. |
| `BatteryMonitor.swift` | 142 | `let ampVal = Int64(bitPattern: UInt64(bitPattern: Int64(amp)))` | The sign-extension dance (`Int → Int64 → UInt64 → Int64`) is doing nothing useful: `Int64(amp)` already sign-extends correctly on a 64-bit platform. The `bitPattern` round-trip is cargo-cult code and the inferred type `Int64` is non-obvious. Same pattern recurs in `SystemMonitor.swift` line 238. Use `let ampVal = Int64(amp)` — the result is identical on macOS (LP64). |
| `CycleEngine.swift` | 67 | `settingsObserver = settings.objectWillChange.debounce(…).sink { … }` | Type inferred as `AnyCancellable` — fine, but the observer watches `objectWillChange` (fires *before* change) then reads settings inside the sink (which runs after the RunLoop tick, so the value *is* updated). This is correct but fragile; a comment noting the timing would prevent a future "why is this debounced on objectWillChange and not a specific property?" question. |

---

## 8. Modern Swift opportunities

### 8a. `@Observable` instead of `ObservableObject` + `@Published`

All eight service classes (`BatteryMonitor`, `ChargingController`, `CycleEngine`, `HistoryRecorder`, `MiningManager`, `StressManager`, `SystemMonitor`, `AppSettings`) use the `ObservableObject` + `@Published` pattern. Swift 5.9's `@Observable` macro would eliminate all `@Published` annotations and all `@ObservedObject` in views.

**Gotcha:** `AppSettings` uses `@AppStorage`, which requires `@Published` for SwiftUI observation. `@Observable` and `@AppStorage` do not compose cleanly as of Swift 5.9/6.0 — `@AppStorage` properties inside an `@Observable` class do not trigger view updates automatically. This is the hard blocker for `AppSettings`. The other seven classes have no such constraint and could migrate freely.

**Recommendation:** Migrate `BatteryMonitor`, `ChargingController`, `CycleEngine`, `HistoryRecorder`, `MiningManager`, `StressManager`, `SystemMonitor` to `@Observable`. Keep `AppSettings` as `ObservableObject`. Update view declarations from `@ObservedObject` to plain properties (no wrapper needed with `@Observable`).

### 8b. `async let` and structured concurrency vs `Task.detached`

`Task.detached` is used in five places:

1. **`BatteryMonitor.refreshHealthDetail`** — spawns a subprocess with no cancellation support and no parent task relationship. Replace with an `async` method called via a structured `Task { @MainActor in await self.refreshHealthDetail() }` where `refreshHealthDetail` is `async` and runs the `Process` work with `withCheckedContinuation`. This naturally participates in the task tree.

2. **`ChargingController.runShortcut`** — the outer task is intentionally unstructured (it outlives the calling scope and chains via `inflight`). `Task.detached` is correct here. The inner watchdog `Task.detached` should use `withTaskCancellationHandler` instead (see §8c).

3. **`MiningManager.stop` SIGKILL escalation** — a 3-second poll loop with 30 × 100ms sleeps. Replace with:
   ```swift
   Task {
       try? await Task.sleep(for: .seconds(3))
       if capturedProc.isRunning { capturedProc.interrupt() }
   }
   ```
   Simpler, and `Task` (not `Task.detached`) is sufficient since no actor isolation is needed.

4. **`StressManager` CPU tasks** — `Task.detached(priority: .high)` for CPU-bound loops is correct; these must not inherit the `@MainActor` context.

5. **`StressManager` GPU task** — same, correct.

### 8c. `withTaskCancellationHandler` for the watchdog

In `ChargingController.runShortcut`, the watchdog is:

```swift
let watchdog = Task.detached {
    try? await Task.sleep(nanoseconds: nanos)
    if process.isRunning {
        didTimeout.set(true)
        process.terminate()
    }
}
process.waitUntilExit()
watchdog.cancel()
```

The manual cancel-after-wait works, but the `TimeoutFlag` class and the shared mutable state between watchdog and parent task could be replaced entirely with `withTaskCancellationHandler`:

```swift
try await withTaskCancellationHandler {
    process.waitUntilExit()   // blocking call, runs on detached thread
} onCancel: {
    process.terminate()
}
```

Combined with a parent-task `Task.sleep` as the timeout trigger, this eliminates `TimeoutFlag`, `NSLock`, `didTimeout`, and the watchdog `Task`. The concurrency model becomes purely structured.

### 8d. `AsyncStream` for IOKit polling instead of timers

`BatteryMonitor` and `SystemMonitor` both use `Timer.scheduledTimer` with a `Task { @MainActor in … }` hop. An `AsyncStream<BatterySnapshot>` driven by `IOPSNotificationCreateRunLoopSource` (for power-source changes) would be more idiomatic and event-driven rather than polling. For `SystemMonitor`, the IOReport subscription is inherently pull-based so a timer is acceptable; but `BatteryMonitor`'s fast 2s timer for percentage/charging state could be replaced with a push notification stream.

This is a medium-effort refactor but would reduce unnecessary CPU wakeups (the 2s timer fires even when nothing has changed).

### 8e. `swift-async-algorithms` `.debounce` instead of Combine

`CycleEngine` uses:
```swift
settingsObserver = settings.objectWillChange
    .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
    .sink { … }
```

With `@Observable` + `AsyncStream`, this becomes:
```swift
for await _ in settings.changes.debounce(for: .seconds(0.5)) { … }
```

This requires adding `swift-async-algorithms` as a dependency and is only worthwhile as part of the broader `@Observable` migration. Combine can stay for now; it's not harmful.

---

## 9. Public surface / access control

All service classes are `@MainActor final class` with no `public` keyword — appropriate for an app target with no framework boundary. Within the module, several members are `internal` (the default) when they should be `private`:

| File | Method/Property | Recommendation |
|------|----------------|----------------|
| `BatteryMonitor.swift` | `update()` | Used only by `CycleEngine`. Could be `internal` by necessity, but deserves a comment noting it is a package-internal API, not meant for arbitrary callers. |
| `BatteryMonitor.swift` | `stopMonitoring()` | Never called in the current codebase (only `startMonitoring` is called from `AppServices`). Either call it on app termination or document why teardown is omitted. |
| `SystemMonitor.swift` | `stopMonitoring()` | Same — never called. |
| `CycleEngine.swift` | `hasCachedPreflight` | Used only in `MainView` to enable/disable a button. Fine as `internal`; its name is clear enough. |
| `ChargingController.swift` | `testStartCharging` / `testStopCharging` | Only called from `MainView` settings panel. Could be renamed with a more precise name (see §4) but access level is fine. |
| `MiningManager.swift` | `defaultWallet`, `defaultPool` | `private static let` — already correct. |
| `StressManager.swift` | `setupMetal()` | Should be `private` — it is called only from `init`. It is already implicitly internal. Mark it `private`. |

---

## 10. Documentation comments

Coverage is uneven. The best-documented file is `ChargingController.swift` (clear, opinionated comments on the serial task chain). The worst gaps:

| Location | Gap |
|----------|-----|
| `BatteryMonitor` class-level | No `///` doc explaining the three-tier polling strategy (fast/slow/health). The MARK comments help but a class-level doc block would be the entry point for any reader. |
| `CycleEngine.runPreflightTest()` | 77-line method with no `///` at all. The state machine it implements (two cases, four terminal paths) is non-trivial. |
| `SystemMonitor` IOReport private API block | The `@_silgen_name` declarations have no comment explaining *why* this approach is used over a bridging header, or what the ABI stability guarantees are. |
| `CycleEngine.onBatteryChanged(_:)` | Contains the critical-battery emergency path (`criticalBattery` check) with only an inline comment. A `///` doc noting "this is the last-resort safety net" would make it stand out during review. |
| `AppServices.init()` | The `historyObserver` sink pattern — why `combineLatest` on three properties rather than a single publisher — is unexplained. |

---

## 11. Long methods

| File | Method | Lines (approx.) | Issue |
|------|--------|-----------------|-------|
| `CycleEngine.runPreflightTest()` | 184–261 | ~78 lines | Two completely separate code paths (plugged-in vs. on-battery) stuffed into one method. Extract `preflightFromPluggedIn()` and `preflightFromBattery()` — each is a linear sequence of await/check pairs and would be ~35 lines each. |
| `BatteryMonitor.updateFast()` | 86–152 | ~67 lines | Three distinct reads: IOPowerSources (percentage/charging), AppleSmartBattery (charger watts/adapter), and computed values (temp/voltage/amperage). Could be split into `readPowerSource()`, `readAdapterInfo()`, and `readElectricalState()`. |
| `MainView.body` | 18–349 | ~330 lines | The entire view hierarchy including settings, info, and history panels. Standard SwiftUI sprawl — extract `SettingsPanel`, `InfoPanel`, `HistoryPanel` as private sub-views. Reduces diff noise and makes the top-level `body` scannable. |
| `SystemMonitor.updateGPU()` | 130–194 | ~65 lines | The IOReport channel walk is necessarily verbose, but the inner loop (find GPUPH, sum residency) could be extracted to `parseGPUPH(from delta: CFDictionary) -> Double?`. |

---

## 12. Duplication

### Process-spawning pattern

`BatteryMonitor.refreshHealthDetail()` and `ChargingController.runShortcut()` both build a `Process`, set `executableURL`, attach a `Pipe`, call `proc.run()`, and read output. The implementations are different enough (one uses `waitUntilExit` + output parsing, the other has the watchdog chain) that a full helper isn't obvious, but a lightweight:

```swift
func runProcess(at path: String, arguments: [String]) async throws -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = arguments
    let pipe = Pipe()
    proc.standardOutput = pipe
    try proc.run()
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}
```

would at minimum de-duplicate `BatteryMonitor.refreshHealthDetail` and allow `ChargingController` to use it for the non-watchdog path. The watchdog variant stays bespoke.

### Regex parsing pattern

`BatteryMonitor.refreshHealthDetail` and `MiningManager.readLog` both use `.range(of:options: .regularExpression)` followed by a second `.range(of:options: .regularExpression)` to extract a captured group. Neither uses `NSRegularExpression` or `Regex` (Swift 5.7+). The Swift `Regex` literal syntax would be clearer and type-safe:

```swift
// BatteryMonitor — instead of two .range(of:) calls:
if let match = output.firstMatch(of: /Maximum Capacity:\s+(\d+)%/) {
    healthPercent = Int(match.1) ?? 0
}
```

---

## 13. Swift 6 strict concurrency predictions

Enabling `.enableUpcomingFeature("StrictConcurrency")` or compiling with `-strict-concurrency=complete` would likely surface:

| # | File | Line(s) | Warning |
|---|------|---------|---------|
| 1 | `ChargingController.swift` | 97–184 | `Task.detached` closure captures `action` (a `String`), `name` (a `String`), `timeoutSeconds` (a `Double`), `previous` (a `Task<Void,Never>?`), `myTaskId` (a `UInt64`) — all value types or `Sendable`, so no warning here. However `process` (`Process`) is captured across the actor boundary. `Process` does not conform to `Sendable`. **Predicted warning:** "Capture of non-Sendable type 'Process' in @Sendable closure." |
| 2 | `ChargingController.swift` | 124 | The inner watchdog `Task.detached` captures `process` (non-`Sendable`). Same warning. |
| 3 | `BatteryMonitor.swift` | 187 | `Task.detached` captures nothing from `self` directly (uses `[weak self]`), but constructs a `Process` inside and crosses actor boundaries when writing back via `MainActor.run`. `Process` itself is the non-`Sendable` concern. |
| 4 | `MiningManager.swift` | 98 | `Task.detached` captures `capturedProc` (`Process`) — same non-`Sendable` issue. |
| 5 | `StressManager.swift` | 80 | `Task.detached` captures `commandQueue` (`MTLCommandQueue`), `pipelineState` (`MTLComputePipelineState`), `buffer` (`MTLBuffer`) — Metal objects do not conform to `Sendable`. **Predicted warning** for each. |
| 6 | `StressManager.swift` | 47 | `catch { }` in `setupMetal` — this is a silent swallow of a `MTLLibrary` compilation error. Not a concurrency warning, but `-warn-unused-result` / `-strict-concurrency` combined with thorough diagnostics may surface it. |
| 7 | `SystemMonitor.swift` | 44–50 | `gpuSubscription: CFTypeRef?` and `gpuChannels: CFMutableDictionary?` are `@MainActor`-isolated properties assigned in `init` and read in `update()` which is also `@MainActor`. No crossing, so no warning — but if `update()` is ever called off-actor, these would fire. |
| 8 | `CycleEngine.swift` | 83–90 | The `NSWorkspace` notification observer closures use `queue: .main` and then hop to `MainActor` via `Task { @MainActor in … }`. Under strict concurrency the double-hop (OperationQueue.main → Task @MainActor) may produce a "redundant MainActor hop" note, not an error, but the redundancy is real. Since the observer block itself is not `@MainActor`, the `Task` hop is required — the pattern is correct but verbose. |

**Most impactful fix:** Wrap `Process` in a `@unchecked Sendable` actor-isolated helper (similar to how `TimeoutFlag` wraps `Bool`) or use `withCheckedContinuation` on a dedicated serial `DispatchQueue` so the `Process` never escapes across actors.

---

## 14. Miscellaneous / smaller findings

### `CycleEngine.cycleCount` vs `battery.cycleCount`

`CycleEngine` maintains its own `@Published var cycleCount: Int = 0` (line 15), incremented in `onBatteryChanged` when `state == .draining && pct <= lowerThreshold`. `BatteryMonitor` also publishes `@Published var cycleCount: Int` read from IORegistry. These are **different counts**: the engine count is the count of full cycles completed *during the current session*, while the battery's count is the hardware lifetime cycle count. They share the same property name. The engine property should be renamed `sessionCycleCount` to prevent any reader from conflating them. `MainView` line 65 shows "Cycles: \(engine.cycleCount)" which is the session count — fine, but the label should say "Session Cycles" for clarity.

### `ampVal` sign-extension (BatteryMonitor line 142)

```swift
let ampVal = Int64(bitPattern: UInt64(bitPattern: Int64(amp)))
```
`amp` is `Int` (already sign-extended to 64 bits on macOS). `Int64(amp)` is identical. The `UInt64(bitPattern:)` / `Int64(bitPattern:)` round-trip is a no-op. Remove it. The same pattern appears in `SystemMonitor.swift` line 238 where the `Int64` branch is handled correctly but the `Int` branch replicates the same cargo-cult pattern.

### `StressManager.setupMetal` swallows compile errors

```swift
} catch { }
```
(line 47) silently discards Metal shader compilation failures. In a debug build this should at least `print("Metal pipeline failed: \(error)")`. In release it keeps `pipelineState = nil` so GPU stress simply doesn't run — that is safe, but undiagnosable.

### `HistoryRecorder` init-time `load()` on `@MainActor`

`load()` calls `Data(contentsOf: fileURL)` (synchronous file I/O) on the main actor inside `init`. The history file is small (JSON of a few hundred bytes), so this is acceptable in practice, but it violates the principle of keeping `@MainActor` work non-blocking. An `async` init or a `Task { self.load() }` in `init` using a background executor would be more correct under strict concurrency guidance.

### `MainView` panel visibility — mutual exclusion via three Booleans

```swift
@State private var showSettings = false
@State private var showInfo = false
@State private var showHistory = false
```

Each button manually resets the other two. This is a classic enum-could-replace-three-bools pattern:

```swift
enum ActivePanel { case settings, info, history }
@State private var activePanel: ActivePanel?
```

Cleaner, and impossible to accidentally leave two panels open simultaneously.

---

## Summary counts

| Category | Findings |
|----------|---------|
| Force-unwrap `!` | 1 (low risk) |
| `try?` suppressions worth reviewing | 4 |
| Reference cycles | 0 (clean) |
| Naming issues | 5 |
| Boolean parameter pollution sites | 8 call sites → 1 enum refactor |
| Magic numbers | 17 |
| Type inference / wrong pattern | 3 |
| `@Observable` migration candidates | 7 of 8 classes |
| `Task.detached` → structured concurrency | 3 sites |
| `withTaskCancellationHandler` opportunity | 1 |
| Long methods (>60 lines) | 4 |
| Duplication | 2 (Process spawning, regex parsing) |
| Predicted Swift 6 strict-concurrency warnings | 6 |
| Miscellaneous | 4 |

**Total distinct findings: 56** across 10 files.

---

## Top 3 recommendations

### 1. Extract a `Constants` enum (highest ROI, lowest risk)

Seventeen magic numbers are spread across `CycleEngine`, `ChargingController`, `BatteryMonitor`, and `SystemMonitor`. A single `Constants.swift` makes all policy thresholds (`criticalBattery`, `safetyMarginPercent`, `shortcutCooldown`, `shortcutTimeout`, `verifyTickCount`, `externalThresholdPercent`, `runningThresholdPercent`, timer intervals) visible in one place. This is a mechanical rename — zero behaviour change, high readability gain, and it exposes the subtle `criticalBattery == safetyMarginPercent == 3` coincidence that may or may not be intentional.

### 2. Replace `force: Bool` with `ShortcutUrgency` enum

Eight call sites pass `force: true` or rely on `force: false` default. The boolean conveys two orthogonal concepts: "bypass cooldown" and "bypass in-flight guard". A `ShortcutUrgency` enum makes the intent readable at every call site and opens the door to a third `.preflight` case (replacing `testStartCharging`/`testStopCharging`). This is a small, safe refactor confined to `ChargingController` and its three callers in `CycleEngine` and `MainView`.

### 3. Migrate to `@Observable` (seven classes) + rename `CycleEngine.cycleCount` → `sessionCycleCount`

The `@Observable` migration eliminates 30+ `@Published` annotations and all `@ObservedObject` wrappers in views, reducing boilerplate significantly. Combine the migration with renaming `CycleEngine.cycleCount` to `sessionCycleCount` to fix the naming collision with `BatteryMonitor.cycleCount`. Keep `AppSettings` as `ObservableObject` due to the `@AppStorage` interop constraint. This is the highest-complexity recommendation but also the most impactful for long-term maintainability.
