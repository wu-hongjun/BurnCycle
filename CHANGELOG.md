# Changelog

All notable changes to BurnCycle are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.2.0] — 2026-09-01

### Fixed

- Closing the main window no longer terminates BurnCycle. Cycling and safety
  monitoring remain active, and the app stays accessible from the menu bar when
  **Show in menu bar** is enabled.
- The outlet-testing state now uses an hourglass instead of a checkmark, making
  it clear that verification is still in progress.

### Added

- Battery percentage beside the menu-bar icon is now optional and hidden by
  default; it can be enabled independently in Settings.
- Added an optional **Hide Dock icon** setting for menu-bar mode. Accessory mode
  is applied only while the menu-bar item is visible, preventing an inaccessible
  background app.
- Redesigned the menu-bar popover as a compact telemetry dashboard showing CPU
  load, battery temperature, battery power, health, cycles, and an estimated
  time to the active charge or drain threshold.

- **Crash / termination failsafe.** If BurnCycle is terminated while *draining*
  (smart outlet OFF) — by the macOS memory-pressure killer (jetsam), a crash, or
  a force-quit — the battery could previously drain toward 0% with nothing to
  turn the outlet back on. A lightweight `Watchdog` LaunchAgent now relaunches
  the app within ~20s if it dies while a cycle is active, and on launch the
  engine recovers fail-safe: it forces charging ON, kills any orphaned `xmrig`,
  and resumes the cycle. A sentinel file marks "cycle active"; a clean stop/quit
  removes it (so no relaunch), while a SIGKILL cannot — a reliable
  "killed unexpectedly" signal. A crash-loop guard stops auto-resume (battery
  left safely charging) after repeated rapid failures. Toggle in Settings ▸
  Behavior ("Relaunch if killed mid-cycle"), on by default. `stop()` and clean
  quit now also restore charging when on battery, so the outlet is never left
  OFF without a live cycling app.

### Investigation

- Diagnosed the "mysteriously closing" reports: no code-crash reports exist
  (the state machine isn't faulting); the app's resident memory grows steadily
  (~2.6× over 4 days in captured JetsamEvent snapshots), making it a jetsam
  target under memory pressure. The failsafe above makes such a kill
  non-catastrophic; the underlying leak is tracked separately.

## [1.1.0] — 2026-05-28

Remediation + History-chart release. Ten parallel audits (dated 2026-05-10) covering safety,
error handling, concurrency, memory lifecycles, performance, security,
SwiftUI UX, and build/distribution were triaged and implemented on
`fix/audit-remediation`. Build is clean under Swift 6 strict concurrency
(zero warnings) and has been packaged end-to-end via `build.sh`. See
[`docs/audits/2026-05-27-remediation-report.md`][report] for the per-finding
status table; highlights below.

### Added

- **History chart — capacity (mAh) trend.** Full-charge capacity is now plotted
  on a second (right) axis alongside Apple-reported health %, sharing one plot.
  Health is a flat integer for 100+ cycles; capacity has finer resolution and
  reveals the real degradation trend. Both render as clean overlapping lines.
- **History chart — hover readout.** Hovering the chart marks the nearest entry
  with a vertical rule and shows its exact cycle, capacity, health, and
  timestamp in a readout above the chart.
- Hardened-runtime entitlements file at `BurnCycle/BurnCycle/BurnCycle.entitlements`.
  App Sandbox stays off (subprocess + private IOKit); hardened runtime is on.
- Runtime SHA-256 verification of bundled `xmrig` in `MiningManager`, checked
  against the post-sign hash sealed into the app as
  `Resources/xmrig.sha256`. Fails closed.
- `build.sh` now signs inside-out (xmrig first, then the app without
  `--deep`), records the post-sign xmrig hash, optionally notarizes when
  `BURNCYCLE_SIGN_ID` + `BURNCYCLE_NOTARY_PROFILE` are set, strips debug
  symbols, writes `Contents/PkgInfo`, and injects a `git describe` version
  into `Info.plist`.
- Charging-stall watchdog: non-fatal warning after 90 minutes stuck below the
  upper threshold (covers the macOS 80% cap case).
- One-shot idle "emergency charge" safeguard when the engine is stopped but
  the battery is critically low.
- Persistent error surfaces: `BatteryMonitor.healthReadFailed`,
  `HistoryRecorder.lastError`, `StressManager.lastError`, plus a deduped
  error line in `MainView` and the menu-bar popover.
- `nonisolated(unsafe)` cleanup pattern for `Timer`/`Task`/`AnyCancellable`/
  observer properties touched from `deinit` under Swift 6 strict
  concurrency. Documented in `docs/development/contributing.md`.
- README "Privacy & Mining" section and disclosure of the default donation
  wallet (also shown in-app).

### Changed

- Engine now refuses to start on a desktop Mac (`!battery.hasBattery`) and
  guards every `await` boundary with a fresh preflight check.
- Cycle count is edge-triggered with `removeDuplicates()`; drain → critical
  transitions are now counted in the critical branch (no undercount on
  sharp drops).
- Effective thresholds clamp to a ≥5% gap (`AppSettings.effectiveLower/UpperThreshold`);
  drain now always uses `stopCharging(force: true)`.
- `BatteryMonitor.updateFast` uses targeted `IORegistryEntryCreateCFProperty`
  reads instead of dumping the full IORegistry every 2s; `SystemMonitor.updatePower`
  reads only Voltage + Amperage.
- `system_profiler` health read is throttled to once per hour, capped at
  256 KB, and surfaces failures instead of swallowing them.
- Retry logic on shortcut failure no longer abandons — re-attempts on a
  ~60s cadence forever while running, and the message names a second power
  source / Thunderbolt dock explicitly.
- "Clear All" history is now gated behind a `confirmationDialog`. Health
  and throttle indicators use distinct SF Symbols and accessible colors
  (orange, not yellow). Icon-only views have accessibility labels.
- ⌘↩ keyboard shortcut on Start/Stop; "applies next phase" hint on
  shortcut fields while running; Session count relabeled "Session: N";
  empty Serial/adapter fields render as "—".
- Menu-bar toggle is reactive via an App-level `@AppStorage` mirror.

### Fixed

- `deinit` paths: `CycleEngine` now has a `deinit`; `SystemMonitor` calls
  `mach_port_deallocate`; sleep/wake observers and `logTimer` are torn
  down. xmrig is reaped via `waitUntilExit()` after `SIGKILL`, and the
  error `Pipe` read handle is closed via `defer` (read moved before
  `waitUntilExit` to avoid deadlock).
- xmrig escalation now uses real `kill(pid, SIGKILL)` (was `interrupt()` /
  SIGINT). `terminationHandler` no longer captures `Process` across the
  actor — it compares pids.
- `onSettingsChanged` now handles the `.charging` state when the threshold
  is lowered at or below the current percentage (drain triggers immediately).
- `handleWake` invalidates the preflight cache so a manual Start re-tests;
  `handleSleep` only arms resume when actually cycling (not during `.testing`).
- `onBatteryChanged` reads live `battery.percentage` instead of the captured
  argument; `transitionToDraining` sets `state` before issuing the shortcut.
- `build.sh`: cleans stale bundles before repopulating, surfaces `actool`
  errors (no `2>/dev/null`), and bundles required `Contents/PkgInfo` +
  `NSHumanReadableCopyright` + `LSApplicationCategoryType` metadata.

### Security

- xmrig is launched with a scrubbed environment (`PATH`, `HOME`, `TMPDIR`
  only).
- `shortcuts` stderr is sanitized and truncated to 200 characters before
  surfacing.
- Shortcut name validation rejects empty/whitespace-only names and
  control characters before spawning.
- Per-launch UUID log filename with `0600` permissions.
- Build script signs with `--options runtime` and `--timestamp` (when a
  Developer ID is provided), with an ad-hoc fallback that does not
  hard-fail local builds.

### Deferred

A class of findings was intentionally not implemented for a single-purpose
personal app (no test target, broad mechanical churn, or UX regression).
The full list — protocol extraction, `decideCycleAction` pure functions,
`PreflightSequencer`, `@Observable` migration, full localization,
`Constants.swift`, `LSUIElement = true` — is in [the remediation report][report].

[report]: docs/audits/2026-05-27-remediation-report.md

## [1.0.0] — 2025

Initial public release.

[Unreleased]: https://github.com/wu-hongjun/BurnCycle/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/wu-hongjun/BurnCycle/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/wu-hongjun/BurnCycle/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/wu-hongjun/BurnCycle/releases/tag/v1.0.0
