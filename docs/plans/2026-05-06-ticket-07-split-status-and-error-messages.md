> **Status (2026-05-27):** Implemented in `c5fc84a` (fix: re-test button, status/error split, throttle hysteresis) — `mismatchWarning` replaced with `statusMessage` / `errorMessage` and the `setStatus` / `setError` / `clearMessages` helpers. See `CycleEngine.swift`.

# Ticket 07 — Split `mismatchWarning` into status vs error

**Severity:** Minor (UX clarity)
**Files:** `BurnCycle/BurnCycle/Services/CycleEngine.swift`, `BurnCycle/BurnCycle/Views/MainView.swift`

## Problem

`@Published var mismatchWarning: String?` on `CycleEngine` is overloaded as both a transient status channel and an error channel. Examples currently mixed into the same field:

| Kind | String |
|---|---|
| Status (transient) | `"Testing outlet control..."`, `"Testing: turning outlet OFF..."`, `"Paused for sleep"` |
| Error (sticky) | `"Outlet test failed: ..."`, `"Charger not detected. Check cable and outlet."`, `"Still charging. Check outlet and shortcut."` |
| Status with progress | `"Outlet not responding (retry 2/3)..."` (technically transient retry-progress, painted as a warning) |

Result:
- Sleep during preflight clobbers the test message; on wake the engine sets `nil` and the user never sees the original status.
- Errors and statuses share orange foreground in `MainView.swift:76`, so users can't visually distinguish "we are working on it" from "this is broken."
- Future code is forced to pick a single string when two pieces of info are relevant.

## Fix

Replace the single `mismatchWarning` field with two:

```swift
@Published var statusMessage: String?    // transient, ongoing operation. Gray.
@Published var errorMessage: String?     // problem the user should act on. Orange.
```

### Routing rules

In `CycleEngine.swift`, audit every assignment to `mismatchWarning` and route it:

| Current line(s) | Current value | Route to |
|---|---|---|
| `mismatchWarning = "Testing outlet control..."` | progress | `statusMessage` |
| `mismatchWarning = "Testing: turning outlet OFF..."` | progress | `statusMessage` |
| `mismatchWarning = "Testing: turning outlet ON..."` | progress | `statusMessage` |
| `mismatchWarning = "Outlet test failed: ..."` (4 sites) | error | `errorMessage` (and clear `statusMessage`) |
| `mismatchWarning = "Paused for sleep"` | status | `statusMessage` |
| `mismatchWarning = "Outlet not responding (retry X/Y)..."` | status | `statusMessage` |
| `mismatchWarning = "Charger not detected. Check cable and outlet."` | error | `errorMessage` (and clear `statusMessage`) |
| `mismatchWarning = "Still charging. Check outlet and shortcut."` | error | `errorMessage` |
| `mismatchWarning = nil` (clearing) | both | clear **both** unless ticket-specific |

When transitioning into a new operation (e.g., entering preflight), clear `errorMessage` and set `statusMessage`. When raising a hard error, clear `statusMessage` and set `errorMessage`. When the operation succeeds, clear both.

Helper methods recommended:

```swift
private func setStatus(_ s: String?) { statusMessage = s }
private func setError(_ e: String?) {
    errorMessage = e
    if e != nil { statusMessage = nil }
}
private func clearMessages() { statusMessage = nil; errorMessage = nil }
```

Use the helpers everywhere instead of touching the published fields directly. This makes the routing explicit and lets you grep for status/error sites later.

### MainView.swift

Replace the single `engine.mismatchWarning` block (around line 75-77):

```swift
if let error = charging.lastError {
    Text(error).font(.caption2).foregroundColor(.red)
}
if let err = engine.errorMessage {
    Text(err).font(.caption2).foregroundColor(.orange)
}
if let status = engine.statusMessage {
    Text(status).font(.caption2).foregroundColor(.secondary)
}
```

Order: shortcut error (red) → engine error (orange) → engine status (gray). Each only appears if non-nil.

## Acceptance

- `mismatchWarning` no longer exists in the codebase. Run `grep -rn "mismatchWarning" BurnCycle/` and expect zero results.
- Pressing Start (cold) shows "Testing outlet control..." in **gray** (status), then turns to "Testing: turning outlet OFF..." in gray, then clears.
- Pressing Start with a deliberately wrong shortcut name shows "Outlet test failed..." in **orange** (error). Status is cleared.
- Sleeping the Mac during a cycle shows "Paused for sleep" in **gray**.
- Verify-retry shows "Outlet not responding (retry 1/3)..." in **gray**, then "Charger not detected..." in **orange** after exhaustion.
- `swift build -c release` succeeds.

## Notes

- Do not break the public API contract for any other consumer. Audit references to `mismatchWarning` across the entire repo first: `grep -rn "mismatchWarning" .` Confirm only `CycleEngine.swift` and `MainView.swift` reference it.
- The MenuBarPopover does not currently read `mismatchWarning`; no change needed there. (Verify before declaring done.)
