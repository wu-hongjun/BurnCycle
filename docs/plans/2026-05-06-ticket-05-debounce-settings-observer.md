> **Status (2026-05-27):** Implemented in `d6ac33f` (fix: cache preflight result and debounce settings observer) — settings observer now uses `.debounce(for: .seconds(0.5), scheduler: RunLoop.main)`. See `CycleEngine.swift`.

# Ticket 05 — Debounce settings observer

**Severity:** Minor
**File:** `BurnCycle/BurnCycle/Services/CycleEngine.swift`
**Related:** Same file as Ticket 04 — same agent owns both.

## Problem

```swift
settingsObserver = settings.objectWillChange.sink { [weak self] _ in
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_000_000); self?.onSettingsChanged()
    }
}
```

`objectWillChange` fires on every `@AppStorage` write — including every keystroke in the shortcut-name `TextField` in `MainView`. The 1ms `Task.sleep` is **not** a debounce; it just defers within the same run-loop turn. Result: typing "Start Charging" letter by letter fires `onSettingsChanged` 14+ times.

`onSettingsChanged` only takes action when the cycle is `running` and `state == .draining`, so the user-visible effect is small today. But under that condition it can stop/start the load process repeatedly, which is wasteful and can cause a brief load flicker. Future settings additions could make this worse.

## Fix

Replace the manual sink with a Combine `.debounce(for:scheduler:)` operator.

### Implementation

```swift
import Combine
// ...

settingsObserver = settings.objectWillChange
    .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
    .sink { [weak self] _ in
        Task { @MainActor in
            self?.onSettingsChanged()
        }
    }
```

Drop the `Task.sleep` — the debounce operator handles timing.

`Combine` is already imported in `CycleEngine.swift:2`.

## Acceptance

- Typing into the "Start Charging Shortcut" `TextField` letter by letter — `onSettingsChanged` fires at most once, ~500ms after the last keystroke. Verify by adding a temporary `print("settings changed")` and watching the Xcode console (remove before commit).
- Toggling "Generate load" once — `onSettingsChanged` fires exactly once, ~500ms later.
- Cycle behaviour during draining (load on/off/method-switch) still works correctly after the debounce delay.
- `swift build -c release` succeeds.

## Notes

- `RunLoop.main` is the right scheduler here because the sink callback updates `@Published` state on the main actor.
- 500ms is comfortable for typing without being noticeable for toggle switches. Don't go above 750ms — toggles will feel laggy.
