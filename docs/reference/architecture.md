# Architecture

## Project Structure

```
BurnCycle/
├── BurnCycleApp.swift                  # AppServices container, AppDelegate, MenuBarExtra
├── BurnCycle.entitlements              # Hardened-runtime entitlements (sandbox off, documented)
├── Models/
│   └── AppSettings.swift               # @AppStorage settings, LoadMethod, effective-threshold clamp
├── Services/
│   ├── BatteryMonitor.swift            # IOKit: %, charging, capacities, health, hasBattery
│   ├── ChargingController.swift        # Apple Shortcuts runner with serial queue + watchdog
│   ├── CycleEngine.swift               # State machine + preflight + load + safety + sleep
│   ├── HistoryRecorder.swift           # 1000-entry capped JSON history
│   ├── MiningManager.swift             # xmrig child process with SHA-256 verification
│   ├── StressManager.swift             # Built-in CPU+GPU stress (Metal)
│   └── SystemMonitor.swift             # CPU ticks, GPU IOReport, battery W
├── Views/
│   └── MainView.swift                  # Single-view UI with Settings/Info/History panels
├── Resources/
│   ├── xmrig                           # Bundled xmrig arm64 binary
│   └── xmrig.sha256                    # Sealed post-sign hash (verified at runtime)
└── Assets.xcassets/                    # Liquid Glass app icon
```

## App container

`AppServices` (`BurnCycleApp.swift:7`) is a `@MainActor ObservableObject` that
eagerly constructs every service before any view body runs — there is no
optional engine and no splash race. It instantiates `BatteryMonitor`,
`ChargingController`, `MiningManager`, `StressManager`, `AppSettings`,
`SystemMonitor`, `HistoryRecorder`, and the `CycleEngine` that depends on
them, then starts `battery.startMonitoring()` and `system.startMonitoring()`.

`historyObserver` (`BurnCycleApp.swift:37`) is a single Combine sink that
combineLatests `$cycleCount`, `$healthPercent`, and `$fullChargeCapacityMAh`
from `BatteryMonitor`, with `removeDuplicates()` on each upstream so the 60 s
slow-tick doesn't re-fire when values are unchanged (F-03).

`BurnCycleApp` declares a `Window` scene and a `MenuBarExtra` whose
`isInserted:` is bound to an App-level `@AppStorage("showInMenuBar")` mirror
(`BurnCycleApp.swift:60`) — reading `services.settings.showInMenuBar` would not
be reactive at the `App` level because `AppServices` does not forward
`settings.objectWillChange`.

`AppDelegate.applicationShouldHandleReopen` reopens the main window on dock-icon
clicks and relaunches (`BurnCycleApp.swift:242`).

## Services

### BatteryMonitor

Three timers (`BatteryMonitor.swift:32`):

- **Fast (2 s)**: `updateFast()` — percentage, isPluggedIn, isCharging,
  charger watts, temperature, voltage, current capacity, charging watts,
  `hasBattery`.
- **Slow (60 s)**: `updateSlow()` — cycle count, serial, design capacity, full
  charge capacity (full IORegistry dict, but cheap because it's only every 60 s).
- **Health (1 h)**: `refreshHealthDetail()` — spawns `/usr/sbin/system_profiler
  SPPowerDataType` to read Apple's "Maximum Capacity %". The timer interval *is*
  the throttle; on-demand `refreshHealth()` calls additionally gate on
  `lastHealthRead` (`BatteryMonitor.swift:87`).

The fast path reads only the keys it needs via `IORegistryEntryCreateCFProperty`
(`fastProperty`, `BatteryMonitor.swift:186`) instead of dumping the full
`AppleSmartBattery` dictionary every 2 s (F-01).

Two extra published signals support honest UX:

- `hasBattery` (`BatteryMonitor.swift:26`) — `false` once we positively confirm
  no internal battery (desktop Mac, or no `AppleSmartBattery` service);
  `CycleEngine.hasUsableBattery()` reads this to refuse cycling (H-4).
- `healthReadFailed` (`BatteryMonitor.swift:30`) — set when `system_profiler`
  fails to launch or its output can't be parsed, so the UI can distinguish a
  failed read from a genuine 0 % reading (H1).

`system_profiler` output is capped at 256 KB defensively (L-4).

Sources used:

- **IOPowerSources** — percentage, AC status, internal-battery presence
- **AppleSmartBattery** (IOKit) — charger details, temperature, voltage,
  amperage, capacities, serial
- **system_profiler SPPowerDataType** — Apple's reported "Maximum Capacity %"

### SystemMonitor

- **CPU**: `host_statistics(HOST_CPU_LOAD_INFO)` against a cached
  `mach_host_self()` port. `deinit` calls `mach_port_deallocate` to release the
  Mach send right that `mach_host_self()` adds (`SystemMonitor.swift:59`, M1).
- **GPU**: `IOReportCopyChannelsInGroup("GPU Stats")` private API (matches
  mactop). Each tick takes a delta sample against the prior one and computes
  active-vs-total residency over the `GPUPH` channel's P-states, treating
  `OFF`/`IDLE`/`DOWN` as inactive. Falls back to `AGXAccelerator`'s
  `PerformanceStatistics.Device Utilization %` if IOReport isn't available
  (`updateGPUFallback`).
- **Power**: targeted `Voltage` + `Amperage` reads from `AppleSmartBattery`
  (`updatePower`, `SystemMonitor.swift:231`) — no full-dictionary copy (F-02).

Refresh interval: 3 s (`startMonitoring`, `SystemMonitor.swift:74`).

### CycleEngine

State machine with four states (`CycleEngine.swift:5`): `.idle`, `.testing`,
`.charging`, `.draining`. State backing fields touched from `deinit` are marked
`nonisolated(unsafe)` (`timer`, `preflightTask`, `wakeResumeTask`,
`settingsObserver`, `batteryObserver`, `sleepObserver`, `wakeObserver`) because
they are only written on the main actor and read once when no other reference
exists.

**Reactive observers (in `init`):**

- `settingsObserver` — `settings.objectWillChange` debounced 500 ms then routed
  to `onSettingsChanged()` (`CycleEngine.swift:81`). Debounce coalesces slider
  drags into a single decision.
- `batteryObserver` — `battery.$percentage.removeDuplicates()` to
  `onBatteryChanged(_:)` (`CycleEngine.swift:89`, F-04).
- `sleepObserver` / `wakeObserver` — `NSWorkspace.willSleepNotification` /
  `didWakeNotification` (`CycleEngine.swift:99`). `deinit` explicitly removes
  both because `NotificationCenter` retains the block independently of the
  token (`CycleEngine.swift:109`, H2).

**Preflight & cache:**

`start()` either runs `runPreflightTest()` (`CycleEngine.swift:247`) or
short-circuits if `lastSuccessfulPreflight` is within `preflightCacheTTL`
(30 min). Preflight toggles the outlet through both states and verifies AC
status changes within 8 s, raising specific errors on failure (e.g. *"still
charging after 'Stop' shortcut. Check for multiple power sources (e.g.
Thunderbolt dock)."*). On success it stores `lastSuccessfulPreflight = Date()`.

`invalidatePreflightCache()` (`CycleEngine.swift:237`) backs the **Re-test
outlet on next Start** button; `hasCachedPreflight` drives its enabled state.

**Critical-battery branch:**

`onBatteryChanged` fires regardless of state when `pct <= criticalBattery` (3 %):
it issues `startCharging(force: true)`, sets `verifyTicksRemaining = 2`, and
increments `cycleCount` if it was draining when the jump happened
(`CycleEngine.swift:407`, H-3). When the engine is *not* running, a one-shot
`firedIdleEmergencyCharge` fires a single best-effort emergency charge per
low-battery episode (resets above critical, C-1).

**verifyPowerState retry forever:**

After a transition, the engine schedules `verifyTicksRemaining = 2` (~20 s) and
on tick fires `verifyPowerState()` (`CycleEngine.swift:511`). The first three
mismatches retry on a ~20 s cadence with a transient status. On the 4th
attempt the engine surfaces a sticky error, invalidates the preflight cache,
and keeps retrying forever on a ~60 s cadence (`verifyTicksRemaining = 6`,
C-2/C-3) — it never permanently abandons the battery.

**Charging-stall watchdog:**

`checkChargingStall()` (`CycleEngine.swift:499`) fires from each tick. If the
engine has been in `.charging` for `chargingStallWarnInterval` (90 min) and
percentage is still below the effective upper threshold, it surfaces a
non-fatal "Charging stalled — macOS optimized charging may cap at 80%." error
once per charge phase. `chargingStartedAt` and `chargingStallWarned` reset on
every `transitionToCharging` and on `stop()` (H-2).

**Sleep / wake:**

`handleSleep` (`CycleEngine.swift:148`) records `wasRunningBeforeSleep` only
when `state == .charging || .draining` — preflight (`.testing`) is treated as
unsafe-to-resume because the outlet contract was never confirmed (M-4).

`handleWake` (`CycleEngine.swift:161`) invalidates the preflight cache (so a
manual Start re-tests, M-2) and, if appropriate, stores a `wakeResumeTask` that
sleeps 2 s before calling `startAfterWake()` — which intentionally bypasses
preflight. `stop()` and `deinit` cancel `wakeResumeTask` so pressing Stop
during the delay can't silently restart cycling (concurrency M2).

**Effective thresholds:**

The engine never compares against the raw slider values. Every comparison goes
through `settings.effectiveLowerThreshold` / `effectiveUpperThreshold`, which
clamp to a ≥5 % gap so a mis-ordered slider pair can't cause thrash
(`AppSettings.swift:33`, L-3/M6). The drain safety margin is
`effectiveLowerThreshold + 3` (`CycleEngine.swift:592`).

**Throttle hysteresis:**

`manageLoad()` requires three consecutive "too hot" ticks (~30 s) before
stopping load, and six consecutive "cool" ticks (~60 s) before resuming
(`CycleEngine.swift:54`). When BurnCycle's own load is running, the "external
load" threshold is raised to 95 % to avoid self-oscillation
(`isExternalLoadSafe`, `CycleEngine.swift:630`).

**Message routing:**

`setStatus` (gray, transient), `setError` (orange, sticky), and `clearMessages`
(`CycleEngine.swift:130`) are the only paths that mutate `statusMessage` /
`errorMessage`. `clearMessages` also clears `charging.lastError` so a stale
stderr from `shortcuts` doesn't linger (M3/M4/L5/L7).

### ChargingController

Runs `/usr/bin/shortcuts run "<name>"` via `Process`. Three correctness
properties matter:

1. **Serial queue** (`inflight` chain): each new task awaits
   `await previous?.value` before running, so force calls are queued, never
   dropped (`ChargingController.swift:117`).
2. **`latestTaskId`**: only the most-recent task in the chain clears the UI
   spinner and `inflight` pointer (`ChargingController.swift:222`), so a stale
   earlier task can't reset state under a fresh one.
3. **Non-force respects cooldown + inflight**: 30 s per-action cooldown
   (separate for start/stop), and non-force calls bail if anything is
   in-flight; force calls bypass both (`ChargingController.swift:91`).

**Per-task watchdog** (`ChargingController.swift:157`): a detached task sleeps
for `shortcutTimeoutSeconds` (20 s); if the process is still running it sets
the locked `TimeoutFlag` and calls `process.terminate()`. The flag (not the
unrelated `terminate()` no-op race) is the authoritative "we timed out" signal
(M5/M1).

**stderr handling**: drained *before* `waitUntilExit()` to avoid deadlock on
large output; the read handle is closed via `defer` on every exit path (H3,
`ChargingController.swift:134`). Output is sanitized through
`sanitizeErrorMessage` (newlines collapsed, capped at 200 chars, L-2).

**Validation**: empty/whitespace shortcut names are rejected before spawning
(M2); control characters / null bytes are rejected defensively even though the
name is passed as an argv element (M-4).

**Cooldown is only recorded on success** (`ChargingController.swift:205`): a
failed call doesn't burn the retry window.

### MiningManager

Launches the bundled xmrig as a child process. Pool is hardcoded
(`xmr-us-east1.nanopool.org:14433`); wallet defaults to the developer donation
address when the user hasn't configured one (`MiningManager.swift:24`, M-1).

**Runtime SHA-256 verification** (`verifyXmrigIntegrity`,
`MiningManager.swift:52`): on every `start()`, when running from the bundled
path, the binary is hashed via CryptoKit and compared to the contents of the
sealed `xmrig.sha256` resource (`expectedBundledXmrigHash`,
`MiningManager.swift:39`). Fails closed — an unverifiable bundled binary is
refused with status `"xmrig integrity check failed"`. The `/opt/homebrew`
fallback is intentionally not hash-pinned (developer convenience).

**Per-launch UUID log** (`MiningManager.swift:19`): the log path is
`burn_cycle_xmrig-<UUID>.log` in `NSTemporaryDirectory()`, created and then
chmod'd `0600` so no other same-user process can read the wallet xmrig echoes
into it (M-3).

**Scrubbed environment** (`MiningManager.swift:124`): xmrig is launched with
only `PATH`, `HOME`, and `TMPDIR` (the latter two are needed for `--opencl`'s
GPU kernel cache). The rest of the parent environment is dropped (L-1).

**Termination & reaping**: `stop()` sends SIGTERM, polls 100 ms × 30 times
(~3 s), then `kill(pid, SIGKILL)` (a real force-kill, not SIGINT — n3) and
`waitUntilExit()` to reap the child so it doesn't linger as a zombie (H1/L8,
`MiningManager.swift:175`).

**Termination handler** captures the terminated process's pid (not the
non-Sendable `Process`) and only clears `self.process` when the pids match —
so a self-exit doesn't clobber a freshly-started one (m3,
`MiningManager.swift:130`).

TLS is enabled (`--tls`); certificate pinning is not (M-2, documented).

### StressManager

- **CPU**: one `Task.detached(priority: .high)` per logical core running tight
  `sin/cos/tan/sqrt/log2` loops (`StressManager.swift:74`).
- **GPU**: Metal compute shader processing 2M floats with
  `sin/cos/tan/sqrt/fma` per element (`StressManager.swift:89`).

`gpuAvailable` is `true` only when device + queue + pipeline state are all
non-nil (`StressManager.swift:23`). When Metal setup fails, `lastError` is
published with a specific reason ("no Metal device", "stress kernel not
found", or the thrown error description) and `status` honestly reports
`"Stressing CPU only (GPU unavailable)"` instead of claiming "CPU+GPU"
(M1/L9, `StressManager.swift:70`).

### HistoryRecorder

JSON-encoded list of `HistoryEntry` (timestamp, cycle count, full charge
capacity mAh, Apple-reported health %) persisted to
`~/Library/Application Support/BurnCycle/history.json`.

`observe()` records when (a) the entries array is empty (first-ever
observation) or (b) the cycle count differs from the last recorded entry.
Daily-snapshot logic was dropped; cycle changes are the only signal that
matters.

**Cap at 1000 entries** (`HistoryRecorder.swift:28`): older entries are
trimmed via `removeFirst` after each append so the array and on-disk file are
bounded.

**`lastError`** (`HistoryRecorder.swift:24`): set when encode or write fails;
the History panel surfaces it as a warning label. Cleared on a successful
save (H2).

## Data flow

```
BatteryMonitor (2 s / 60 s / 1 h) ──┬─→ CycleEngine.onBatteryChanged (removeDuplicates)
                                    ├─→ AppServices.historyObserver (removeDuplicates × 3)
                                    └─→ MainView (@Published)
SystemMonitor (3 s) ────────────────→ CycleEngine.tick → manageLoad / isExternalLoadSafe
AppSettings.objectWillChange ───────→ debounce 500 ms → CycleEngine.onSettingsChanged
NSWorkspace sleep/wake ─────────────→ CycleEngine.handleSleep / handleWake
CycleEngine ──┬─→ ChargingController (serial queue + watchdog)
              ├─→ MiningManager / StressManager (only while .draining)
              └─→ statusMessage / errorMessage (MainView + MenuBarPopover)
```

## Build & signing

- **Hardened runtime** with entitlements in `BurnCycle.entitlements`. App
  Sandbox is intentionally off — BurnCycle launches `shortcuts` and `xmrig`
  subprocesses and reads private IOKit, neither of which is permitted under
  the sandbox. Documented as accepted.
- **Inside-out signing** in `build.sh` (no `--deep`): the bundled `xmrig`
  binary is signed first, its post-sign SHA-256 is recorded into
  `xmrig.sha256`, and only then is the `.app` itself signed — so the hash file
  is sealed into the app's `CodeResources`. Runtime verification reads from
  that sealed copy.
- `codesign` chooses Developer ID when `$BURNCYCLE_SIGN_ID` is set, otherwise
  ad-hoc. Optional `notarytool` / `stapler` step is env-guarded. Version is
  injected via `git describe` through `PlistBuddy`.
