# Audit Remediation Report — 2026-05-27

This report tracks remediation of the ten audits dated **2026-05-10**. On the
`fix/audit-remediation` branch the findings were implemented by five parallel
agents (partitioned by file), reviewed by two independent reviewers, polished,
and verified to build cleanly (`swift build` — no errors, no warnings; full
`build.sh` packaging exercised).

**Legend:** ✅ Fixed · 🟡 Partial / documented as accepted · ⏭️ Deferred (deliberate)

## Why some items were deferred

A class of findings was intentionally **not** implemented because the change
carries more regression risk than user value for a single-purpose personal app:

- **Architecture/testability rewrites** (protocol extraction, `decideCycleAction`
  pure functions, `PreflightSequencer`, splitting `MainView`/`BurnCycleApp`) —
  there is no test target, so the abstractions buy nothing today.
- **`@Observable` migration**, **full localization**, **central `Constants.swift`** —
  broad mechanical churn across every file; deferred to avoid destabilizing the
  safety logic in the same pass.
- **`LSUIElement = true`** (perf F-08) — would hide the Dock icon and break the
  windowed UX. Left `false` deliberately.

---

## safety-state-machine
| ID | Status | Note |
|----|--------|------|
| C-1 | ✅ | Emergency charge fires regardless of state while running + one-shot idle safeguard when stopped; re-verifies via `verifyTicksRemaining`. |
| C-2 | ✅ | Retry no longer abandons; re-attempts on ~60s cadence forever while running. |
| C-3 | ✅ | Persistent retry + message explicitly names a second power source / Thunderbolt dock. |
| H-1 | ✅ | `beginCycling()` guards `isRunning` + battery presence; preflight guards every `await`. |
| H-2 | ✅ | Charging-stall watchdog warns (non-fatal) after 90 min stuck below upper threshold (macOS 80% cap). |
| H-3 | ✅ | Edge-triggered count (state flips first) + `removeDuplicates()`; drain→critical jump now counted in the critical branch. |
| H-4 | ✅ | Refuses to start when `!battery.hasBattery` (desktop Mac). |
| M-1 | ✅ | `onSettingsChanged` now handles `.charging` (threshold lowered ≤ pct → drain). |
| M-2 | ✅ | `handleWake` invalidates the preflight cache so a manual Start re-tests. |
| M-3 | ✅ | `state` set before issuing shortcut; `transitionToDraining` uses `stopCharging(force:true)`. |
| M-4 | ✅ | `handleSleep` only arms resume when actually cycling (not during `.testing`). |
| M-5 | ✅ | `onBatteryChanged` reads live `battery.percentage` instead of the captured arg. |
| L-1 | 🟡 | Hourly health timer bypassing the throttle is intended; documented. |
| L-2 | 🟡 | `startAfterWake` 2s `await` suspends (does not block) the actor; left. |
| L-3 | ✅ | `AppSettings.effectiveLower/UpperThreshold` clamp guarantees a ≥5% gap; engine uses effective values everywhere. |
| L-4 | ✅ | Non-force drop fixed by the serial queue; drain now uses `force:true`. |

## error-handling
| ID | Status | Note |
|----|--------|------|
| H1 | ✅ | `BatteryMonitor.healthReadFailed` published; `do/catch` around `system_profiler`. |
| H2 | ✅ | `HistoryRecorder.lastError` set on encode/write failure. |
| M1 | ✅ | `StressManager.lastError` + honest status ("CPU only" when GPU unavailable). |
| M2 | ✅ | Empty/whitespace shortcut name rejected before spawning. |
| M3 | ✅ | `clearMessages()`/`stop()` clear `charging.lastError`; MainView shows one error line. |
| M4 | ✅ | Stale shortcut error cleared on state-match / resume. |
| M5 | 🟡 | xmrig crash mid-drain still not auto-restarted (stress test is the default load); accepted. |
| M6 | ✅ | Threshold overlap eliminated via effective-threshold clamp. |
| L1 | 🟡 | Stale-on-failure IOPowerSources read documented as intentional. |
| L2 | ⏭️ | `applicationSupportDirectory.first!` left (always resolvable on macOS). |
| L3 | 🟡 | Log truncation still best-effort `try?`; path now per-launch + `0600`. |
| L4 | ✅ | Menu bar popover now surfaces `engine.errorMessage`. |
| L5 | 🟡 | `handleWake` message clear ordering left (cosmetic). |
| L6 | ✅ | Covered by `StressManager.lastError`. |
| L7 | ✅ | Error display deduped (engine error preferred over charging error). |

## concurrency
| ID | Status | Note |
|----|--------|------|
| M1 | 🟡 | Blocking `waitUntilExit()` is acceptable inside the detached task; watchdog cancelled after wait. |
| M2 | ✅ | Wake-resume `Task` stored in `wakeResumeTask`, cancelled in `stop()` + `deinit`. |
| M3 | ✅ | `deinit` removes NSWorkspace observers. |
| M4 | 🟡 | Health task still detached/uncancellable but now error-handled; runs <2s. |
| M5 | ✅ | Watchdog/`Process` race documented benign; `TimeoutFlag` (locked) is authoritative. |
| m1 | 🟡 | `&+=` wrap documented harmless. |
| m2 | ⏭️ | Redundant `Task { @MainActor }` hop left (low value). |
| m3 | ✅ | `terminationHandler` no longer captures `Process` across the actor (compares pid). |
| m4 | 🟡 | Combine sinks already held as properties; documented. |
| m5 | 🟡 | Metal-object capture into detached task left (functions correctly). |
| n1 | ✅ | Health-read throttle semantics preserved; failure now surfaced. |
| n2 | ✅ | `deinit` added to `CycleEngine`. |
| n3 | ✅ | Real `kill(pid, SIGKILL)` escalation (was `interrupt()`/SIGINT). |

## memory-lifecycles
| ID | Status | Note |
|----|--------|------|
| H1 / L8 | ✅ | `stop()` reaps xmrig via `waitUntilExit()` after SIGKILL. |
| H2 | ✅ | Sleep/wake observers removed in `deinit`. |
| H3 | ✅ | Error `Pipe` read handle closed via `defer`; read moved before `waitUntilExit()` (no deadlock). |
| M1 | ✅ | `SystemMonitor` `deinit` calls `mach_port_deallocate`. |
| M2 | ✅ | `refreshHealthDetail` closes the pipe read handle. |
| M3 | ✅ | `logTimer` invalidated on the main actor in the termination path. |
| L1–L7 | — | Were PASS confirmations; remain correct. |

## performance
| ID | Status | Note |
|----|--------|------|
| F-01 | ✅ | `BatteryMonitor.updateFast` uses targeted `IORegistryEntryCreateCFProperty` reads (no full-dict dump every 2s). |
| F-02 | ✅ | `SystemMonitor.updatePower` reads only Voltage+Amperage. |
| F-03 | ✅ | History observer `removeDuplicates()` before `combineLatest`. |
| F-04 | ✅ | `$percentage` sink `removeDuplicates()`. |
| F-05 | ⏭️ | Mining log timer (2s) only runs while mining; left. |
| F-06 | ⏭️ | Batched `@Published` skipped (SwiftUI coalesces per runloop). |
| F-07 | ⏭️ | Idle `SystemMonitor` timer left (engine reads CPU/GPU for throttle). |
| F-08 | ⏭️ | `LSUIElement` left `false` deliberately (windowed UX). |

## security
| ID | Status | Note |
|----|--------|------|
| H-1 | ✅ | Build-time source check + **runtime pre-exec verification** in `MiningManager` (CryptoKit SHA-256 vs the post-sign hash recorded in the sealed `xmrig.sha256` resource; fails closed). Build signs inside-out (no `--deep`) so the hash file is sealed into the app signature. |
| H-2 | ✅ | Hardened-runtime entitlements file; App Sandbox intentionally off (subprocess + private IOKit), documented. |
| H-3 | ✅ | `codesign` step in `build.sh` (Developer ID if `$BURNCYCLE_SIGN_ID`, else ad-hoc). |
| M-1 | ✅ | Default donation wallet now shown in status + disclosed in README. |
| M-2 | 🟡 | TLS kept; cert pinning documented as not configured (no shipped fingerprint). |
| M-3 | ✅ | Per-launch UUID log filename, `0600` permissions. |
| M-4 | ✅ | Shortcut name control-character rejection. |
| M-5 | ✅ | `.unsafeFlags(["-lIOReport"])` explained. |
| L-1 | ✅ | xmrig launched with scrubbed env (PATH + HOME/TMPDIR only). |
| L-2 | ✅ | `shortcuts` stderr sanitized + truncated to 200 chars. |
| L-3 | ⏭️ | xmrig auto-update mechanism out of scope. |
| L-4 | ✅ | `system_profiler` read capped at 256 KB. |
| L-5 | ✅ | Health-read failure surfaced. |
| L-6 | ✅ | README "Privacy & Mining" section. |

## swiftui-ux
| ID | Status | Note |
|----|--------|------|
| H1 | ✅ | "Clear All" gated behind a `confirmationDialog`. |
| H2 | ✅ | Root `.frame(minWidth:320, idealWidth:320, maxWidth:420)` cooperates with `.contentSize`. |
| M1 | ✅ | Accessibility labels on icon-only views. |
| M2 / L6 | ✅ | Health/throttle use distinct SF Symbols + accessible colors (orange, not yellow). |
| M3 | ✅ | Popover uses text styles for Dynamic Type. |
| M4 | ✅ | "applies next phase" hint on shortcut fields while running. |
| M5 | ✅ | Menu-bar toggle reactive via App-level `@AppStorage` mirror. |
| M7 | ✅ | ⌘↩ keyboard shortcut on Start/Stop. |
| L3 | ✅ | Session count relabeled "Session: N". |
| L4 | ✅ | Empty Serial/adapter show "—". |
| L8 | ✅ | `HistoryRecorder.lastError`. |
| L9 | ✅ | `StressManager` honest CPU-only status. |
| M6, L2, L5, L7 | 🟡 | Cosmetic (message animation, fixed column widths, stepped menu-bar icon, popover "Stopping…") left. |
| L1 | ⏭️ | Localization deferred. |

## architecture-testability
| ID | Status | Note |
|----|--------|------|
| ONBOARDING-01 | 🟡 | `TimeoutFlag`/IOReport comments present; full version-warning not added. |
| all others | ⏭️ | Protocol abstraction, pure decision functions, file splitting deferred (no test target; high churn, low value). |

## build-distribution
| ID | Status | Note |
|----|--------|------|
| HIGH-1 | ✅ | Conditional `codesign` (Developer ID or ad-hoc). |
| HIGH-2 | ✅ | Optional env-guarded `notarytool`/`stapler` snippet. |
| HIGH-3 | ✅ | README documents `xattr -dr com.apple.quarantine` + Gatekeeper. |
| MED-1 | ✅ | `rm -rf` stale bundle before repopulating. |
| MED-2 | ✅ | actool errors surfaced (no `2>/dev/null`). |
| MED-3 | ✅ | `Contents/PkgInfo` written. |
| MED-4 | ✅ | `NSHumanReadableCopyright` + `LSApplicationCategoryType` added. |
| MED-5 | ✅ | `-lIOReport` comment. |
| LOW-1 | ✅ | Version injected from `git describe` via PlistBuddy. |
| LOW-2 | 🟡 | Icon @1x/@2x reuse noted; no new art fabricated. |
| LOW-3 | ✅ | `BurnCycle.app` already untracked (gitignore). |
| LOW-4 | ✅ | `strip -rSTX` step (non-fatal). |

---

## New files
- `BurnCycle/BurnCycle/BurnCycle.entitlements` — hardened-runtime entitlements (sandbox off, documented).
- `BurnCycle/BurnCycle/Resources/xmrig.sha256` — recorded hash `c66f9881bed79a550e18d54b9ae5cf03b91a0e881efdbf7962db2e58de0b4f7b`.

## Verification
- `swift build`: clean (no errors/warnings) before and after polish.
- Two independent code reviews: no CRITICAL/HIGH regressions; polish items (cycle-count
  undercount on drain→critical jump, `hasBattery` desktop cold-launch, trimmed shortcut
  name, xmrig `HOME`/`TMPDIR` env) applied.
