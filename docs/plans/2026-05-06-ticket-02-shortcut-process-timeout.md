> **Status (2026-05-27):** Implemented in `fad124f` (fix: make ChargingController resilient to CoAP flakiness) — 20s watchdog with `TimeoutFlag` (NSLock-guarded) terminates hung `shortcuts` invocations. See `ChargingController.swift`.

# Ticket 02 — Add timeout to `shortcuts` subprocess

**Severity:** Critical
**File:** `BurnCycle/BurnCycle/Services/ChargingController.swift`
**Related:** Implement after Ticket 01 (which restructures the task body).

## Problem

`runShortcut` calls:

```swift
try process.run()
process.waitUntilExit()
```

There is no timeout. If `/usr/bin/shortcuts` ever genuinely hangs (HomeKit accessory unreachable + slow accessory-side timeout, or transient OS issue), `waitUntilExit()` blocks forever. The published `isRunningShortcut` stays `true` indefinitely. After Ticket 01, the queue stays drained but the in-flight task never finishes, so even queued force calls block. Critical safety risk.

Empirically `shortcuts run` usually fails fast with a non-zero exit, but we should not depend on that.

## Fix

Wrap process execution with a 20s watchdog. If exceeded, terminate the process and treat as failure.

### Implementation

Inside the `Task.detached` body, after `try process.run()`:

```swift
let timeoutSeconds: UInt64 = 20

let watchdog = Task.detached {
    try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
    if process.isRunning {
        process.terminate()
    }
}

process.waitUntilExit()
watchdog.cancel()

let timedOut = process.terminationReason == .uncaughtSignal && !succeededNormally
// or simpler: track a flag set by the watchdog when it actually fires
```

Recommended flag-based approach (clearer):

```swift
let didTimeout = Atomic<Bool>(false)   // or use an actor / NSLock-guarded var

let watchdog = Task.detached {
    try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
    if process.isRunning {
        didTimeout.set(true)
        process.terminate()
    }
}

process.waitUntilExit()
watchdog.cancel()

let succeeded = !didTimeout.get() && process.terminationStatus == 0
let errorOutput: String? = {
    if didTimeout.get() { return "Shortcut timed out after \(timeoutSeconds)s" }
    if !succeeded {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
}()
```

Note: Swift has no built-in `Atomic`. Use a small `final class TimeoutFlag { ... }` with a `pthread_mutex` or `NSLock`, or just an `actor` (the watchdog and main task can both `await` it). Keep it local.

### Behaviour

- On timeout: `process.terminate()` is called, `succeeded = false`, `lastError = "Shortcut timed out after 20s"`, `isRunningShortcut` clears via the existing path.
- On normal exit: watchdog is cancelled, no spurious kill.
- The watchdog Task does not retain `self`.

## Acceptance

- Force a slow shortcut (e.g., temporarily replace `executableURL` with `/bin/sleep` and arguments `["30"]`).
  - After 20s, the process is killed.
  - `lastError == "Shortcut timed out after 20s"`.
  - `isRunningShortcut == false`.
  - The next call (force or otherwise) can proceed normally.
- A normal shortcut that completes in <20s is unaffected.
- No leaked child processes after the parent app exits (test by quitting mid-call).
- `swift build -c release` succeeds.

## Notes

- 20s is chosen because `shortcuts` typically fails fast (≤5s) on CoAP errors and a successful HomeKit call rarely takes more than ~10s. Pick a configurable `let timeoutSeconds: TimeInterval = 20` constant near the top of the class so it's easy to tune.
- Do not interleave with the cooldown changes from Ticket 03; the timeout always fires regardless of whether the call eventually counts toward cooldown.
