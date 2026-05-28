# SwiftUI / UX Audit

> **Remediation status (2026-05-27):** addressed on branch `fix/audit-remediation`. See [2026-05-27-remediation-report.md](2026-05-27-remediation-report.md) for the per-finding Fixed / Partial / Deferred status.

**Date:** 2026-05-10
**Auditor:** codex-reviewer (read-only)
**Scope:** SwiftUI views, state ownership, accessibility, layout, dark mode, dynamic type, UX edge cases

---

## Summary

| Severity | Count |
|----------|-------|
| High     | 2     |
| Medium   | 7     |
| Low      | 9     |
| **Total**| **18**|

---

## High Severity

### H1 — Destructive "Clear All" history with no confirmation
**File:** `BurnCycle/BurnCycle/Views/MainView.swift` line 336–339
**Category:** UX / Data loss

The "Clear All" button in the History panel calls `history.clearAll()` immediately with no alert or confirmation sheet. History is persisted to disk in Application Support and is the only record of battery health trends over time. A single misclick destroys all data permanently. macOS HIG requires confirmation for irreversible destructive actions. A `confirmationDialog` or `Alert` with a secondary "Delete All Entries" action is the standard pattern.

**Suggestion:** Wrap the action in `.confirmationDialog("Delete all history?", isPresented: $showClearConfirm)` with a destructive-role "Delete All" button and a "Cancel" default.

---

### H2 — Fixed `.frame(width: 320)` on `MainView` fights `.windowResizability(.contentSize)`
**File:** `BurnCycle/BurnCycle/Views/MainView.swift` line 348; `BurnCycleApp.swift` line 65
**Category:** Layout fragility

`MainView` sets a hard `.frame(width: 320)` and the app scene declares `.windowResizability(.contentSize)`. This prevents horizontal resizing entirely. When the Settings panel is open, shortcut name TextFields (`startChargingShortcut`, `stopChargingShortcut`) truncate long names at ~230 pt of usable width (320 minus 16+16 padding). On the menu bar popover, `.frame(width: 260)` similarly hard-codes width, leaving no breathing room for future content additions. The stated intent of `.contentSize` is to let the window grow with its content — that only works vertically here.

**Suggestion:** Remove the hard width constraint from `MainView` body. Set a `minWidth` via `.frame(minWidth: 320)` or use the scene-level `.defaultSize` modifier. For the popover, prefer `.frame(minWidth: 240, maxWidth: 300)`.

---

## Medium Severity

### M1 — No `accessibilityLabel` on SF Symbol-only views in `MenuBarLabel`
**File:** `BurnCycleApp.swift` lines 88–104
**Category:** Accessibility

`MenuBarLabel` renders an `Image(systemName:)` and a battery percentage `Text`. The image has no `accessibilityLabel`. VoiceOver will read a raw system symbol name (e.g. "bolt.fill") instead of a meaningful description. Same pattern applies to all `Label(_, systemImage:)` uses in `MainView` rows 1–3 where the text portion is a number or a raw status string — semantically unclear without context.

**Suggestion:** Add `.accessibilityLabel("Charging")` / `.accessibilityLabel("Draining")` etc. on the icon image, or compose the `Label` with a string that reads well spoken aloud. Consider `.accessibilityElement(children: .combine)` on the battery `HStack`.

---

### M2 — Color-only signaling for battery health and state
**File:** `MainView.swift` lines 27, 324; `BurnCycleApp.swift` lines 134, 168–169
**Category:** Accessibility / Dark mode

Health percent is communicated exclusively via `.green / .yellow / .red` foreground color. The Stop button uses `.tint(.red)` vs `.tint(.green)` as the sole differentiator between "Stop" and "Start". Users with deuteranopia (red-green color blindness, ~8% of males) cannot distinguish these states. macOS Accessibility guidelines require a secondary non-color cue (icon, label, shape).

**Suggestion:** For the Start/Stop button, use an SF Symbol prefix (e.g. `stop.fill` / `play.fill`) inside the label. For health rows, add a suffix indicator (e.g. "80% (Good)") or use `accessibilityValue`.

---

### M3 — Fixed `.font(.system(size: 28, ...))` does not scale with Dynamic Type
**File:** `BurnCycleApp.swift` line 121 (MenuBarPopover battery percentage label)
**Category:** Dynamic Type

`.font(.system(size: 28, weight: .semibold, design: .rounded))` is a fixed pixel size. When the user increases system font size via Accessibility > Display > Large Text, this label stays at 28 pt while the surrounding `.caption` text grows, producing an inconsistent hierarchy. macOS semantic font styles (`Font.largeTitle`, `.title`, `.title2`) automatically scale.

**Suggestion:** Replace with `.font(.title.weight(.semibold))` (or `.title2`) and add `.fontDesign(.rounded)` as a separate modifier. SwiftUI will then apply the correct scaled size.

---

### M4 — `@AppStorage` TextField writes on every keystroke; no debounce visible to the engine
**File:** `AppSettings.swift` lines 15–17; `MainView.swift` lines 145, 191, 196
**Category:** Performance / UX

`walletAddress`, `startChargingShortcut`, and `stopChargingShortcut` are `@AppStorage` strings bound directly to `TextField`s. Every keystroke writes to `UserDefaults` and fires `objectWillChange` on `AppSettings`. `CycleEngine` subscribes to `settings.objectWillChange` with a 0.5 s debounce (`CycleEngine.swift` line 68), which is sufficient to avoid rapid `onSettingsChanged` calls. However, the engine's `onSettingsChanged` only guards on `state == .draining` — if a user edits the shortcut name while a cycle is running and in `.charging` state, the debounced sink fires but does nothing. This is correct behavior, but the shortcut name used by an in-flight `charging.startCharging` call is captured at call time, so a mid-cycle rename silently takes effect only on the next transition — which may surprise users. No in-UI indication that the shortcut name change won't apply until the next phase.

**Suggestion:** Add a `Text("Changes apply at next phase")` hint below the shortcut TextFields when `engine.isRunning`, or disable editing while running.

---

### M5 — `MenuBarExtra(isInserted:)` binding reads `settings.showInMenuBar` but `settings` is not `@StateObject`
**File:** `BurnCycleApp.swift` lines 68–77
**Category:** State ownership

The `MenuBarExtra(isInserted:)` binding is a manual `Binding(get:set:)` that reads and writes `services.settings.showInMenuBar`. `services` is correctly a `@StateObject`. However, `AppSettings` is not itself observed at the `App` body level — changes to `showInMenuBar` do not cause the `App.body` to re-evaluate, so the `isInserted` binding `get` closure captures the value at the last render, not reactively. In practice, toggling "Show in menu bar" in `MainView` (via the Toggle bound to `$settings.showInMenuBar`) writes to `@AppStorage`, which does trigger `objectWillChange` on `AppSettings`, which in turn triggers `MainView` to re-render (because `MainView` has `@ObservedObject var settings`). But the `App` body's `MenuBarExtra` binding won't update until the `App` struct re-renders, which requires `BurnCycleApp` to observe something that changes. `@StateObject private var services` will propagate if `AppServices` itself fires `objectWillChange` — but `AppServices` does not forward `settings.objectWillChange`. On macOS 14+ this is a known edge case with `MenuBarExtra(isInserted:)` where the toggle can appear to lag by one render cycle.

**Suggestion:** Either make `BurnCycleApp` observe `services.settings` explicitly (e.g. `@ObservedObject` reference to the settings object, or forward `settings.objectWillChange` through `AppServices`), or use a dedicated `@AppStorage("showInMenuBar")` property directly in `BurnCycleApp` to drive the binding.

---

### M6 — Sleep/wake "Paused for sleep" message has a visible flash
**File:** `CycleEngine.swift` lines 114–143
**Category:** UX / Visual

On wake, `handleWake()` calls `clearMessages()` after a 2-second `Task.sleep`, then calls `startAfterWake()` which calls `clearMessages()` again. The `statusMessage = "Paused for sleep"` set in `handleSleep()` survives across the sleep boundary and is shown in the UI for the full 2-second delay before the second `clearMessages()` in `handleWake`. This is intentional to show the user that the app resumed, but the message disappears abruptly with no animation or fade, and there is no "Resuming..." intermediate state. Users may see "Paused for sleep" linger and then vanish, which can read as a stale/stuck UI.

**Suggestion:** Add `.animation(.easeOut, value: engine.statusMessage)` on the status `Text` container in `MainView`, or use `withAnimation { clearMessages() }` inside the engine. Also consider showing "Resuming after sleep..." during the 2-second deferral window.

---

### M7 — No keyboard focus management; "Start" button has no default focus
**File:** `MainView.swift` lines 107–112
**Category:** Accessibility / Keyboard navigation

The main window has no `defaultFocus` or `.focused()` binding applied to any control. Tab order follows SwiftUI's default spatial order, which is reasonable, but the primary action ("Start" when idle, "Stop" when running) has no keyboard shortcut and is not given default focus. macOS users expect to hit Return to confirm the primary action or Space to activate a focused button. The Settings, Info, and History buttons also have no keyboard shortcuts.

**Suggestion:** Add `.keyboardShortcut(.return, modifiers: [])` to the Start/Stop button, or use `.defaultFocus(_:)` on app launch. For panel toggle buttons, consider `.keyboardShortcut("s", modifiers: .command)` etc.

---

## Low Severity

### L1 — All UI strings are English-only literals; not wrapped in `String(localized:)`
**File:** All view files
**Category:** Localization

No strings use `String(localized:)` or `LocalizedStringKey`. This is common for developer tools, but worth noting for future localization readiness.

---

### L2 — History table header columns use fixed pixel widths that may truncate on larger type sizes
**File:** `MainView.swift` lines 291–294
**Category:** Layout fragility

`.frame(width: 45)`, `.frame(width: 90)`, `.frame(width: 50)` are used for table columns. With larger accessibility text sizes or localized strings, "Capacity (mAh)" at 90 pt fixed width will clip.

---

### L3 — `engine.cycleCount` (in-session count) is shown alongside `battery.cycleCount` (hardware count) with no disambiguation
**File:** `MainView.swift` line 65 vs line 28
**Category:** UX clarity

Row 3 shows "Cycles: \(engine.cycleCount)" (cycles completed this session) and Row 1 shows `battery.cycleCount` (total hardware cycles). Labels are similar; a user could confuse them.

**Suggestion:** Label the session count explicitly, e.g. "Session: \(engine.cycleCount)" or "Completed this session: …".

---

### L4 — `infoRow("Serial", battery.serial)` shows empty string before first battery read
**File:** `MainView.swift` line 248
**Category:** Empty state

On cold launch before `updateSlow()` completes, `battery.serial` is `""`. The Info panel shows an empty row for Serial with no placeholder. Same applies to `adapterName`.

**Suggestion:** Use `battery.serial.isEmpty ? "—" : battery.serial` or conditionally hide the row.

---

### L5 — `MenuBarLabel` icon `"battery.50"` used for all discharge levels when not running
**File:** `BurnCycleApp.swift` line 96
**Category:** UX accuracy

When the engine is not running and the battery is not plugged in, the menu bar icon is always `"battery.50"` regardless of actual charge level. The main window correctly uses a 4-step icon set (`battery.25/.50/.75/.100`).

**Suggestion:** Extract the `batteryIcon` computed property from `MainView` into a shared function or reuse the same logic in `MenuBarLabel`.

---

### L6 — `.foregroundColor(.yellow)` for throttle warning may be invisible in light mode
**File:** `MainView.swift` line 174; `MainView.swift` line 59
**Category:** Dark mode

`.foregroundColor(.yellow)` on a white/light background has poor contrast (WCAG ratio ~1.5:1 against white). `.orange` or `.primary` with a warning symbol would read better in both appearances.

---

### L7 — Stop button in `MenuBarPopover` calls `engine.stop()` with no visual feedback delay
**File:** `BurnCycleApp.swift` line 165
**Category:** UX

After tapping Stop in the popover, `engine.stop()` is synchronous and the button label immediately flips to "Start". There is no intermediate "Stopping…" state despite load teardown (mining/stress processes) taking up to 3 s (SIGTERM + 3 s SIGKILL window in `MiningManager.stop()`). The popover may stay open during this window showing a misleading "Start" state.

---

### L8 — `HistoryRecorder.save()` silently swallows write errors
**File:** `HistoryRecorder.swift` lines 74–80
**Category:** Maintainability

`try? data.write(to: fileURL)` discards errors. A full disk or permissions issue would lose history without any user notification.

---

### L9 — `StressManager.setupMetal()` catches Metal library compile errors with an empty `catch {}`
**File:** `StressManager.swift` lines 43–47
**Category:** Maintainability / Debuggability

A Metal shader compile failure is silently swallowed. The GPU stress path then quietly does nothing (no-ops through the `if let device, let commandQueue, let pipelineState` guard in `start()`), while `status` still reports "Stressing CPU+GPU". Users will see the status but get CPU-only load with no indication that GPU stress failed.

**Suggestion:** At minimum log the error (`print` or `os_log`). Optionally surface it via `status = "GPU unavailable: \(error)"`.

---

## Notes

- **`@StateObject` / `@ObservedObject` ownership** is correct throughout. `AppServices` is `@StateObject` at the `App` level; all child views receive services as `@ObservedObject`. No reversed ownership found.
- **`AppSettings` `objectWillChange` + debounce** in `CycleEngine` (0.5 s, `RunLoop.main`) is a sound pattern and will not cause publish storms from TextField keystrokes reaching the engine.
- **History empty state** is handled correctly with a descriptive message (line 302–306).
- **Info panel before first battery read**: most fields default to `0` and render as "0 mAh" / "0.0 °C" etc. Not a crash risk, just a mild cosmetic issue (see L4).
