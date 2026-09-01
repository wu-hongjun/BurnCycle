# Settings Reference

Every persisted setting lives in `AppSettings.swift` and is backed by
`@AppStorage` (UserDefaults). The settings panel in `MainView` is the single
UI surface; toggling **Show in menu bar** also re-evaluates the App scene live
via an App-level `@AppStorage` mirror.

## Battery Thresholds

| Setting | UserDefaults key | Default | Range / step | Description |
|---------|------------------|---------|--------------|-------------|
| Charge to | `upperThreshold` | `90` | 50–100, step 5 | Upper threshold — outlet turns off, draining begins |
| Drain to  | `lowerThreshold` | `5`  | 5–50, step 5  | Lower threshold — outlet turns on, charging begins |

### Effective thresholds (≥5 % gap clamp)

The engine never compares against the raw slider values. `AppSettings`
exposes `effectiveLowerThreshold` and `effectiveUpperThreshold` which clamp
the pair to a minimum 5 % gap (`AppSettings.minThresholdGap`), so a
mis-ordered slider drag can't drive charging and draining to the same
percentage:

- `effectiveLowerThreshold = min(lowerThreshold, upperThreshold - 5)`
- `effectiveUpperThreshold = max(upperThreshold, lowerThreshold + 5)`

`CycleEngine` uses these in every transition decision, the
`onSettingsChanged` mid-cycle re-check, and the drain safety margin
(`effectiveLowerThreshold + 3`).

## Load Generation

| Setting | UserDefaults key | Default | Options | Description |
|---------|------------------|---------|---------|-------------|
| Generate load while draining | `loadEnabled` | `true` | Toggle | Whether to run load during drain phase |
| Method | `loadMethod` | `"Stress Test"` | `"Stress Test"` / `"Mine XMR"` | How to generate load |
| XMR Wallet | `walletAddress` | `""` | Text field | Custom Monero wallet (empty → developer donation wallet) |

`LoadMethod` is a `String`-raw enum with two cases (`.stress`, `.mine`).
`selectedLoadMethod` defaults to `.stress` if the stored string fails to
parse.

### Stress Test (default)

Native CPU + GPU stress, no network, no external dependencies.

- **CPU**: one `Task.detached(priority: .high)` per logical core running tight
  `sin/cos/tan/sqrt/log2` loops.
- **GPU**: Metal compute shader processing 2M floats with
  `sin/cos/tan/sqrt/fma` per element.

`StressManager.gpuAvailable` is honest about what's actually running. When
the Metal device/queue/pipeline can't be initialized, `status` reports
`"Stressing CPU only (GPU unavailable)"` instead of falsely claiming
"CPU+GPU", and `lastError` carries the specific reason (M1/L9).

### Mine XMR

Bundled xmrig binary, hardcoded pool `xmr-us-east1.nanopool.org:14433`, `--tls`
on. Requires internet.

**Runtime integrity check**: on every start, `MiningManager` computes the
SHA-256 of the bundled binary via CryptoKit and compares it to the contents of
the sealed `xmrig.sha256` resource (which was recorded post-sign at build
time). A mismatch — or any failure to read either file — refuses to launch
with status `"xmrig integrity check failed"` (H-1, fails closed).

!!! info "Wallet & supporting development"
    Leaving the wallet field empty mines to the **developer's donation
    wallet**. This is surfaced in the live status line as `"Mining (default
    donation wallet)"` so it is never a hidden default (M-1). To mine for
    yourself, paste your own Monero (XMR) wallet address.

## Outlet Control

| Setting | UserDefaults key | Default | Description |
|---------|------------------|---------|-------------|
| Start Charging Shortcut | `startChargingShortcut` | `"Start Charging"` | Apple Shortcut that turns outlet ON |
| Stop Charging Shortcut  | `stopChargingShortcut`  | `"Stop Charging"`  | Apple Shortcut that turns outlet OFF |

Both fields have a **Test** button that runs the shortcut once (with
`force: true`). Empty / whitespace-only names are rejected before spawning;
control characters and newlines are rejected defensively (M2/M-4).

While the engine is running, a hint reads *"Shortcut name changes apply on
the next charge/drain phase."*

### Re-test outlet on next Start

A button at the bottom of the Outlet Control section calls
`engine.invalidatePreflightCache()`. It is disabled while the engine is
running and when there is no cached preflight result. The next `Start` press
will run the full preflight test instead of skipping (30 min cache TTL is
otherwise honored).

`handleWake` also invalidates the cache automatically so a manual Start after
sleep always re-tests in case hardware (e.g. a Thunderbolt dock) changed
while asleep (M-2).

## Behavior

| Setting | UserDefaults key | Default | Description |
|---------|------------------|---------|-------------|
| Show in menu bar | `showInMenuBar` | `false` | Reactive — toggling inserts/removes `MenuBarExtra` live |
| Show battery percentage | `showBatteryPercentageInMenuBar` | `false` | Shows battery % beside the menu-bar state icon |
| Hide Dock icon | `hideDockIcon` | `false` | Uses accessory mode while the menu-bar item is enabled |
| Pause cycling when Mac sleeps | `pauseOnSleep` | `true` | Stop on sleep; auto-resume ~2 s after wake if we were cycling |

`showInMenuBar` is mirrored at the `App` level via `@AppStorage("showInMenuBar")`
so SwiftUI re-evaluates the scene when it changes — observing
`services.settings` from the App body would not be reactive because
`AppServices` does not forward `settings.objectWillChange` (M5).

`showBatteryPercentageInMenuBar` controls only the text beside the state icon.
It defaults to `false` for a compact menu-bar item and remains available in the
popover regardless of this setting.

`hideDockIcon` switches `NSApplication` to accessory activation policy, which
removes the Dock icon without terminating BurnCycle. It is applied only while
`showInMenuBar` is also `true`, ensuring the app always retains a visible entry
point. The main window can be reopened from the menu-bar popover.

`pauseOnSleep` only arms a fast-resume when the engine was actually cycling
(`.charging` or `.draining`). If sleep happens while still in preflight
(`.testing`), the engine just stops — the outlet contract was never
confirmed, so a bare resume that skips preflight would be unsafe (M-4).

## Preflight Test

When you press **Start**, `CycleEngine.start()` either runs the preflight or
short-circuits using a cached successful result (TTL: 30 minutes,
`preflightCacheTTL`).

Preflight toggles the outlet through both states and verifies AC status
changes within 8 s per leg. On any mismatch it sets a specific sticky error
and returns to `.idle`:

- *"Outlet test failed: still charging after 'Stop' shortcut. Check for
  multiple power sources (e.g. Thunderbolt dock)."*
- *"Outlet test failed: 'Start' shortcut didn't restore power."*
- *"Outlet test failed: no power after 'Start' shortcut. Check that the
  charger cable is plugged into the controlled outlet."*
- *"Outlet test failed: 'Stop' shortcut didn't disconnect power."*

`hasUsableBattery()` also gates Start: on a Mac with no internal battery
(`battery.hasBattery == false`), Start refuses with *"No internal battery
detected — cannot cycle."* (H-4).

## Keyboard

The Start/Stop button binds `⌘↩` (`.keyboardShortcut(.return, modifiers:
.command)` in `MainView.swift`), so the primary action is reachable without
the mouse.

## Smart Load Management

Load generation respects system state with hysteresis to avoid
self-oscillation:

- **Safety margin** — load stops at `effectiveLowerThreshold + 3 %`.
- **Critical safety** — at ≤3 % the engine force-charges regardless of state
  (and even fires a one-shot emergency charge when not cycling).
- **Throttle on external load** — when our own load is running, the
  "external load" threshold is bumped to 95 %; when idle, 80 %. Hysteresis
  requires 3 consecutive "too hot" ticks (~30 s) to stop and 6 consecutive
  "cool" ticks (~60 s) to resume.
- **Method switching** — changing Mine XMR ↔ Stress Test mid-drain triggers
  `stopAllLoad()` then `startLoad()` via the debounced settings observer.
- **Mid-cycle threshold change** — raising Drain above current %, or
  lowering Charge below current %, transitions immediately instead of
  waiting for the next battery publish (M-1).

## Watchdogs & retry policy

- **verifyPowerState** runs ~20 s after each transition. Up to 3 retries on
  a 20 s cadence with a transient status; on the 4th miss the engine sets a
  sticky error, invalidates the preflight cache, and keeps retrying forever
  on a 60 s cadence — it never permanently abandons the battery (C-2/C-3).
- **Charging stall** — after 90 minutes in `.charging` still below the
  effective upper threshold, the engine surfaces a non-fatal warning:
  *"Charging stalled — macOS optimized charging may cap at 80%. Disable in
  System Settings ▸ Battery."* (H-2). The flag resets on the next charge
  phase and on `stop()`.
- **Shortcut timeout** — `ChargingController` watchdogs each `shortcuts run`
  invocation at 20 s and terminates a hung process. Stderr is sanitized
  (newlines collapsed) and capped at 200 chars before being surfaced.
