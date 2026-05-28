# Architecture & testability audit

> **Remediation status (2026-05-27):** addressed on branch `fix/audit-remediation`. See [2026-05-27-remediation-report.md](2026-05-27-remediation-report.md) for the per-finding Fixed / Partial / Deferred status.

**Date:** 2026-05-10
**Auditor:** codex-reviewer
**Scope:** All 11 Swift source files — read-only analysis, no code changes.

---

## Module dependency map

```
BurnCycleApp.swift
├── AppServices (container)
│   ├── BatteryMonitor          (IOKit, IOPowerSources, system_profiler subprocess)
│   ├── ChargingController      (shortcuts subprocess, serial Task chain)
│   ├── MiningManager           (xmrig subprocess, log polling)
│   ├── StressManager           (GCD Tasks, Metal compute)
│   ├── SystemMonitor           (mach host_statistics, IOReport private API)
│   ├── AppSettings             (@AppStorage, UserDefaults)
│   ├── HistoryRecorder         (JSON file, ApplicationSupport)
│   └── CycleEngine ──────────► all six above (direct concrete references)
│
├── MainView ────────────────► all eight services (8 @ObservedObject params)
├── MenuBarLabel ────────────► BatteryMonitor, CycleEngine
├── MenuBarPopover ──────────► BatteryMonitor, CycleEngine, MiningManager,
│                              StressManager, AppSettings
└── AppDelegate              (NSApplicationDelegate — no service refs)
```

Key observation: `CycleEngine` has 6 hard-wired concrete dependencies. `MainView` has 8. No protocols exist anywhere in the codebase.

---

## Findings

### COUPLING-01 — CycleEngine depends on 6 concrete types; nothing is mockable
**Severity:** medium
**File:** `Services/CycleEngine.swift`

`CycleEngine` stores six concrete `let` properties: `BatteryMonitor`, `ChargingController`, `MiningManager`, `StressManager`, `SystemMonitor`, `AppSettings`. There are no protocols. You cannot substitute a fake battery at 3% to unit-test the critical-safety branch (`pct <= criticalBattery`), nor inject a no-op `ChargingController` to test the preflight state machine without actually spawning `shortcuts run`.

**Recommendation:** Introduce three protocol abstractions that unlock the highest test coverage with the least invasive change:

```swift
protocol BatteryReading: AnyObject {
    var percentage: Int { get }
    var isPluggedIn: Bool { get }
    var isCharging: Bool { get }
    func update()
    func refreshHealth()
    // publisher for reactive subscription
    var percentagePublisher: AnyPublisher<Int, Never> { get }
}

protocol ChargingControlling: AnyObject {
    func startCharging(shortcutName: String, force: Bool)
    func stopCharging(shortcutName: String, force: Bool)
}

protocol LoadGenerator: AnyObject {
    var isActive: Bool { get }
    func start()
    func stop()
}
```

`MiningManager` and `StressManager` both satisfy `LoadGenerator`. `CycleEngine` can then hold `any BatteryReading`, `any ChargingControlling`, and two `any LoadGenerator` values. No changes required to concrete types initially.

---

### COUPLING-02 — MainView receives 8 concrete @ObservedObject parameters
**Severity:** low
**File:** `Views/MainView.swift`, `BurnCycleApp.swift`

`MainView` is initialised with all 8 services individually. `BurnCycleApp` passes them out of `AppServices` one by one. If a ninth service is added, 3 call sites must be updated. It also means every preview or hypothetical test must construct 8 live objects.

**Recommendation:** Pass `AppServices` directly to `MainView` (the container already exists and is a single `@StateObject`). `MainView` destructures it internally. This does not affect testability negatively — the real fix is the protocol abstractions in COUPLING-01.

---

### COHESION-01 — BatteryMonitor has three distinct responsibilities
**Severity:** medium
**File:** `Services/BatteryMonitor.swift`

`BatteryMonitor` performs three logically separate operations at three different frequencies:
1. **Fast electrical state** (2s): `percentage`, `isPluggedIn`, `isCharging`, `chargerWatts`, `temperature`, `voltage`, `chargingWatts`, `currentCapacityMAh` — read via `IOPowerSources` + `AppleSmartBattery`.
2. **Slow registry reads** (60s): `cycleCount`, `serial`, `designCapacityMAh`, `fullChargeCapacityMAh` — read via `IORegistryEntryCreateCFProperties`.
3. **Expensive health subprocess** (1h): `healthPercent` — spawns `/usr/sbin/system_profiler`.

These could be three separate types: `BatteryElectricalMonitor`, `BatteryRegistryMonitor`, `BatteryHealthReader`. For now the single class is manageable because the responsibilities are well-separated internally by the `// MARK:` sections. The main risk is that `updateFast()` (152 lines of `CFTypeRef` bridging) is already large and will resist testing. Extracting a pure `func parseFastProps(_ dict: [String: Any]) -> BatteryElectricalState` struct would allow unit testing of the IOKit key parsing logic without hardware.

---

### TESTABILITY-01 — Cycle-state-transition logic is embedded in reactive callbacks; cannot be unit-tested
**Severity:** medium
**File:** `Services/CycleEngine.swift`, lines 296–323

`onBatteryChanged(_:)` combines side-effects (calling `transitionToCharging()`, `transitionToDraining()`, mutating `cycleCount`) with decision logic. The decision is a pure function of `(state, pct, lowerThreshold, upperThreshold, criticalBattery)` but is not expressed that way.

**Recommendation:** Extract a pure decision type:

```swift
enum CycleAction {
    case none
    case transitionToCharging
    case transitionToDraining
    case emergencyCharge        // criticalBattery path
}

func decideCycleAction(
    state: CycleState,
    pct: Int,
    lower: Int,
    upper: Int,
    critical: Int
) -> CycleAction { ... }
```

This function is a struct-level pure function (no `self`, no `@MainActor`). It can be tested exhaustively: boundary values, off-by-one at threshold, critical override. The 20 most important branches of `CycleEngine` become testable without any DI change.

---

### TESTABILITY-02 — Hysteresis logic in manageLoad() is also extractable
**Severity:** low
**File:** `Services/CycleEngine.swift`, lines 433–470

`manageLoad()` implements a two-sided hysteresis counter (3 ticks to stop, 6 ticks to resume). The tick counts are private instance state. A bug in the counter logic (e.g. a counter not being reset on the right branch) is impossible to catch without a running engine and real-time observation.

**Recommendation:** Extract a pure `ThrottleHysteresis` struct:

```swift
struct ThrottleHysteresis {
    var consecutiveHighTicks: Int = 0
    var consecutiveLowTicks: Int = 0
    let stopThreshold: Int
    let resumeThreshold: Int

    enum Decision { case none, stop, resume }

    mutating func tick(isLoadRunning: Bool, externalSafe: Bool) -> Decision { ... }
}
```

The struct holds no async state and can be driven entirely by unit tests.

---

### TESTABILITY-03 — Preflight state machine is an 80-line async Task with no observable intermediate states
**Severity:** medium
**File:** `Services/CycleEngine.swift`, lines 184–261

`runPreflightTest()` is a monolithic `Task` with two branches (Case A / Case B), each containing two sequential 8-second `Task.sleep` calls and inline success/failure decisions. There is no way to inject a fast clock or a fake power-state observer. Testing the "outlet turned off but start shortcut failed to restore it" branch requires either 16 real seconds or a rewrite.

**Recommendation:** Extract a `PreflightSequencer` type that accepts injectable `(CharginControlling, BatteryReading, Clock)`. Even without a formal `Clock` protocol, making the sleep duration a parameter (defaulting to 8s, overridable in tests to 0) unlocks deterministic testing of all four terminal states.

---

### PUBLIC-SURFACE-01 — @Published properties that should be read-only externally are fully writable
**Severity:** low
**File:** Multiple service files

All `@Published` properties across all service classes are publicly mutable (`var`, no `private(set)`). For example, `CycleEngine.state`, `CycleEngine.cycleCount`, `BatteryMonitor.percentage`, `MiningManager.isMining` can all be set by any code holding a reference. This is a correctness risk: a view accidentally writing `engine.state = .charging` would corrupt the state machine without triggering any transition logic.

**Recommendation:** Use `private(set)` on all `@Published` properties that are not intentionally two-way bound. For properties that views only read:

```swift
@Published private(set) var state: CycleState = .idle
@Published private(set) var cycleCount: Int = 0
@Published private(set) var isRunning: Bool = false
```

`AppSettings` properties are legitimately two-way (bound to `$settings.upperThreshold` sliders) so they correctly remain public.

---

### SETTINGS-01 — loadMethod stored as String instead of enum
**Severity:** low
**File:** `Models/AppSettings.swift`, line 14

`loadMethod` is stored as `String` and a computed `selectedLoadMethod: LoadMethod` wrapper bridges it. The computed property is already correct, but the raw `String` is also `@Published` and used directly in `CycleEngine.onSettingsChanged()` (`wantMethod != activeLoadMethod` — a `String` comparison). If a third `LoadMethod` case is added, the `Picker` tag, the equality check in `CycleEngine`, and the `activeLoadMethod: String?` tracking variable must all be updated manually.

**Recommendation:** `LoadMethod` already conforms to `RawRepresentable` with `String` raw value. Swift 5.9+ `@AppStorage` accepts any `RawRepresentable` type whose `RawValue` is a supported storage type directly:

```swift
@AppStorage("loadMethod") var loadMethod: LoadMethod = .stress
```

Remove the `selectedLoadMethod` computed property and update `activeLoadMethod` to `LoadMethod?`. The `Picker` tag becomes `.tag(method)` instead of `.tag(method.rawValue)`.

---

### ERROR-TYPES-01 — Errors represented as String literals scattered across CycleEngine and ChargingController
**Severity:** low
**File:** `Services/CycleEngine.swift`, `Services/ChargingController.swift`

Error conditions are reported as ad-hoc `String` values assigned to `errorMessage` or `lastError`. There is no `Error` type hierarchy. This makes it impossible to programmatically respond to specific error categories (e.g. retry only on `.shortcutTimeout`, show a different UI for `.cableNotDetected`).

**Recommendation:** Define an error enum:

```swift
enum CycleError: Error, LocalizedError {
    case preflightStopFailed
    case preflightStartFailed
    case chargerNotDetected(retries: Int)
    case outletNotResponding(retries: Int)
    case shortcutTimeout(name: String, seconds: Int)

    var errorDescription: String? { ... }
}
```

`CycleEngine.errorMessage` becomes `CycleEngine.error: CycleError?`. Views call `.localizedDescription` for display and can also pattern-match for recovery actions.

---

### APPSERVICES-01 — Container is slightly overpowered: owns observer wiring that belongs to participants
**Severity:** low
**File:** `BurnCycleApp.swift`, lines 35–44

`AppServices.init()` wires the `historyObserver` Combine pipeline that watches `battery.$cycleCount`, `battery.$healthPercent`, `battery.$fullChargeCapacityMAh` and drives `HistoryRecorder.observe(...)`. This cross-service wiring inside the container works, but it means `AppServices` must know the internal publication shape of `BatteryMonitor` to decide when to record history. If `BatteryMonitor`'s slow-update keys change, the container must be updated too.

No circular dependency exists: `engine` is built last and only reads from the others. `HistoryRecorder` does not reference `BatteryMonitor` or `CycleEngine`, which is correct.

**Recommendation:** The wiring is acceptable at current scale. If the project grows, move the Combine chain into `HistoryRecorder.attach(to battery: BatteryMonitor)` so the recorder owns its own subscription logic.

---

### MAINVIEW-01 — MainView is a 440-line monolithic View with three inline panels
**Severity:** low
**File:** `Views/MainView.swift`

`MainView` contains the status header, controls row, Settings panel, Info panel, and History panel (including a `Chart`) all in one `body`. The three panels are toggled by `@State private var show{Settings,Info,History}`. Adding a fourth panel requires editing this single file and adding mutual-exclusion logic to the toggle buttons.

**Recommendation:** Extract each panel to its own `View` struct in separate files:

- `Views/SettingsPanel.swift` — `struct SettingsPanel: View`
- `Views/InfoPanel.swift` — `struct InfoPanel: View`
- `Views/HistoryPanel.swift` — `struct HistoryPanel: View`

`MainView` becomes a coordinator of ~80 lines. Each panel can be previewed independently with `#Preview`.

---

### BURNAPP-01 — BurnCycleApp.swift mixes four distinct concerns
**Severity:** low
**File:** `BurnCycleApp.swift`

The file contains: (1) `AppServices` container class, (2) `BurnCycleApp` app entry point with `MenuBarExtra` scene, (3) `MenuBarLabel` View, (4) `MenuBarPopover` View, (5) `AppDelegate`. These are five separate abstractions in 218 lines.

**Recommendation:** Split into:
- `AppServices.swift` — the DI container
- `BurnCycleApp.swift` — entry point only (`@main` struct + `AppDelegate`)
- `Views/MenuBarLabel.swift`
- `Views/MenuBarPopover.swift`

---

### ONBOARDING-01 — Three things a new maintainer would ask "why is this here?"

**1. `TimeoutFlag` in `ChargingController.swift` (lines 7–22)**
A hand-rolled `NSLock`-guarded boolean class exists because `Process.isRunning` is read from a `Task.detached` watchdog that crosses actor boundaries. A new maintainer unfamiliar with Swift concurrency will not immediately understand why a plain `Bool` is unsafe here. Recommendation: add a one-line comment above the class: `// Needed because Process.isRunning is read across task boundaries with no actor isolation; @unchecked Sendable + NSLock is the minimal safe wrapper.`

**2. `@_silgen_name` declarations at the top of `SystemMonitor.swift` (lines 6–32)**
Ten private IOReport C functions are declared via `@_silgen_name`, a compiler directive that bypasses Swift's normal symbol lookup. A new maintainer will likely search for these in IOKit headers, find nothing, and be confused. Recommendation: add a file-level comment: `// IOReport is a private Apple framework. These declarations mirror the C API used by tools like mactop. They are not stable across macOS versions — test on each major release.`

**3. `activeLoadMethod: String?` in `CycleEngine.swift` (line 42)**
This shadow variable tracks which load method is "currently running" as a `String?` so `onSettingsChanged()` can detect a method switch mid-drain. It is not obvious why `CycleEngine` must track this separately from `settings.loadMethod` — the answer is that `settings.loadMethod` reflects the *desired* method while `activeLoadMethod` reflects the *running* method, which may diverge when the user changes settings while load is already active. Recommendation: rename to `runningLoadMethod: LoadMethod?` (enum, not String) and add a comment: `// Tracks the method actually running, which may differ from settings.loadMethod if the user changed the setting while draining.`

---

## Summary table

| ID | Area | Severity | One-line description |
|---|---|---|---|
| COUPLING-01 | Coupling | medium | No protocols; CycleEngine's 6 deps are all concrete |
| COUPLING-02 | Coupling | low | MainView receives 8 individual concrete params |
| COHESION-01 | Cohesion | medium | BatteryMonitor has 3 distinct responsibilities at 3 frequencies |
| TESTABILITY-01 | Testability | medium | Cycle-state decisions buried in reactive callback; not extractable as pure function |
| TESTABILITY-02 | Testability | low | Hysteresis tick counters are private mutable state; extract as struct |
| TESTABILITY-03 | Testability | medium | Preflight async Task: no injectable clock, all 4 terminals untestable |
| PUBLIC-SURFACE-01 | Encapsulation | low | All @Published writable externally; none use private(set) |
| SETTINGS-01 | API design | low | loadMethod: String instead of LoadMethod enum via @AppStorage |
| ERROR-TYPES-01 | Error handling | low | Errors as String literals; no typed Error hierarchy |
| APPSERVICES-01 | Architecture | low | Container owns cross-service Combine wiring; minor but could move |
| MAINVIEW-01 | View structure | low | 440-line monolithic View; three panels should be separate structs |
| BURNAPP-01 | File organisation | low | Five concerns in one 218-line file |
| ONBOARDING-01 | Maintainability | low | Three unexplained patterns need targeted comments |

**Total findings:** 13 (4 medium, 9 low). No high-severity findings. No test target exists.

---

## Top 3 recommendations (prioritised)

### 1. Add three protocols and make CycleEngine depend on them (COUPLING-01)
`BatteryReading`, `ChargingControlling`, `LoadGenerator`. This is the single highest-leverage change: it unblocks unit tests for the state machine, preflight sequencer, and hysteresis logic simultaneously — without touching any concrete class internals.

### 2. Extract `decideCycleAction(state:pct:lower:upper:critical:)` as a pure free function (TESTABILITY-01)
Zero dependencies on protocols or DI. Can be done in one sitting. Immediately testable with XCTest. Covers the most safety-critical logic (emergency charge at 3%, threshold transitions).

### 3. Use `private(set)` on all externally-read-only @Published properties (PUBLIC-SURFACE-01)
Mechanical change, zero logic risk. Prevents accidental state corruption from views, and signals intent clearly to future contributors.
