---

> **Remediation status (2026-05-27):** addressed on branch `fix/audit-remediation`. See [2026-05-27-remediation-report.md](2026-05-27-remediation-report.md) for the per-finding Fixed / Partial / Deferred status.
date: 2026-05-10
title: "Concurrency audit"
---

# Concurrency Audit — BurnCycle (Swift 6, macOS 14)

Reviewed commits `fad124f`, `c5fc84a`, `be58516` (CoAP-resilience + throttle changes).  
Build confirmed clean under `-strict-concurrency=complete -warn-concurrency`.

---

## Critical

_(none)_

---

## Major

### M1 — `process.waitUntilExit()` blocks cooperative executor thread with no cancellation path
**Location:** `ChargingController.swift:132`

`waitUntilExit()` is a blocking POSIX call issued inside `Task.detached`. Swift's cooperative thread pool has a bounded number of threads. Blocking one for up to 20 s (the shortcut timeout) under heavy call rates can starve all concurrent tasks in the app. More critically, the call does not respond to task cancellation: if the outer `Task` is cancelled (e.g. on app quit while `inflight` is set), the `shortcuts` subprocess continues running, the watchdog continues sleeping, and the chain of awaiting force-calls remains blocked until the process exits on its own.

**Recommendation:** Replace `waitUntilExit()` with an `async` bridge via `Process.terminationHandler` + `CheckedContinuation`, and wrap the whole subprocess lifetime in `withTaskCancellationHandler { process.terminate(); watchdog.cancel() }`. This makes the task cooperatively cancellable and eliminates the thread-pool blockage.

---

### M2 — Unmanaged wake-resume `Task` can restart the engine after `stop()`
**Location:** `CycleEngine.swift:127–132`

`handleWake()` creates an anonymous `Task { @MainActor in … }` that sleeps for 2 s and then calls `startAfterWake()`. The task is neither stored nor cancelled. If the user calls `stop()` during those 2 s, `stop()` cancels `preflightTask` and invalidates the timer, but the anonymous wake task is invisible to `stop()` — it will fire after the sleep, pass the `guard !isRunning` check (which is now `false`), and silently restart the engine. This is a user-visible safety bug: the user presses Stop, sees it stop, then the machine starts cycling again.

**Recommendation:** Store the wake-resume task in `private var wakeResumeTask: Task<Void, Never>?`, cancel it in `stop()` and any future `deinit`, and capture `[weak self]` + check `Task.isCancelled` after the sleep before calling `startAfterWake()`.

---

### M3 — `NSWorkspace` sleep/wake observers are never removed
**Location:** `CycleEngine.swift:83–90`

`CycleEngine` stores `sleepObserver` and `wakeObserver` as `NSObjectProtocol?` but never calls `NSWorkspace.shared.notificationCenter.removeObserver(_:)` in a `deinit`. In the current app architecture `CycleEngine` is a singleton and never deinits, but if ever reconstructed (e.g. after a settings reset or in tests), the old block-based observers remain registered in the `NSWorkspace` notification center, hold a weak-self capture, and will fire spurious `Task { @MainActor in … }` calls on every subsequent sleep/wake event. The `NSWorkspace` notification center retains the block object independently of the token stored in the property.

**Recommendation:** Add `deinit` to `CycleEngine` that calls `nc.removeObserver(sleepObserver!)` and `nc.removeObserver(wakeObserver!)` (guard for nil), invalidates `timer`, cancels `preflightTask` and `wakeResumeTask`, and nils the Combine cancellables.

---

### M4 — `refreshHealthDetail()` detached task is untracked and uncancellable
**Location:** `BatteryMonitor.swift:187–206`

`refreshHealthDetail()` spawns a `Task.detached` for the `system_profiler` subprocess but the task handle is discarded. `stopMonitoring()` only invalidates timers; it has no way to cancel or terminate an in-flight health read. On app quit (which calls `NSApplication.terminate(nil)` synchronously), a slow `system_profiler` subprocess (typically 1–2 s, up to several seconds on a loaded machine) can outlive the app's cleanup phase and then call `await MainActor.run { self?.healthPercent = value }` against an already-deallocated object (because `weak self` becomes nil safely, but the subprocess thread may still be running when the process exits). Additionally, `proc.waitUntilExit()` inside the detached task blocks a cooperative thread with no timeout.

**Recommendation:** Store the returned `Task` handle in `private var healthTask: Task<Void, Never>?`. Add a stored `Process?` reference for the subprocess. In `stopMonitoring()` and `deinit`, cancel the task and terminate the process. Add a 30 s timeout using the same `withTaskCancellationHandler` + `terminationHandler` pattern as M1.

---

### M5 — Watchdog `Task.detached` races on `Process` state across isolation boundaries
**Location:** `ChargingController.swift:124–133`

The watchdog task (spawned at line 124) and the owner task both access `process.isRunning` and `process.terminate()` / `process.waitUntilExit()` / `process.terminationStatus` from separate unstructured `Task.detached` contexts with no shared actor or lock. `Process` is documented as thread-safe for `terminate()`, but the compound `if process.isRunning { didTimeout.set(true); process.terminate() }` is not atomic: the process can exit between the `isRunning` check and `terminate()`, causing `terminate()` to be called on an already-exited (or a reused PID in an adversarial scenario) process. Meanwhile, `TimeoutFlag` correctly guards its own bool but does not cover the `isRunning`/`terminate` pair.

**Recommendation:** Eliminate the race by bridging the process lifetime to a single `async` continuation via `terminationHandler` (see M1). The watchdog then becomes a simple `Task.sleep` + `continuation.resume` path, removing the need for `TimeoutFlag` entirely.

---

## Minor

### m1 — `latestTaskId` wrapping overflow can spuriously clear UI state
**Location:** `ChargingController.swift:94–95`

`latestTaskId &+= 1` uses Swift's wrapping addition. At `UInt64.max` invocations the counter wraps to 0. A long-running earlier task (e.g. one stuck waiting on `previous?.value` behind a 20 s shortcut) could then find `myTaskId == self.latestTaskId` again after the wrap and incorrectly clear `isRunningShortcut` and `inflight` while a newer task is still pending. In practice this requires `2^64` calls and is not a real risk, but the sentinel value used for "no task" and "oldest task" are the same (0 after wrap).

**Recommendation:** Replace the integer counter with `UUID()` as the task token, or maintain an explicit `inFlightTaskCount: Int` and only clear UI state when it reaches zero.

---

### m2 — Timer callbacks on `RunLoop.main` dispatch redundantly through `Task { @MainActor in }`
**Location:** `BatteryMonitor.swift:44–58`, `CycleEngine.swift:273–276`, `SystemMonitor.swift:65–68`, `MiningManager.swift:70–73`

All timers are scheduled on `RunLoop.main` (the default for `Timer.scheduledTimer`). The callback closure is therefore already executing on the main thread. Wrapping the call in `Task { @MainActor in self?.method() }` creates a redundant actor hop — the closure enqueues a new task on the main executor rather than calling the method directly. This adds one scheduling round-trip per tick, and if the timer fires very frequently (e.g. `fastTimer` at 2 s), multiple tasks can queue up if the main actor is momentarily busy, causing stale reads to be processed out of order.

**Recommendation:** Either call the method directly from the timer closure (safe because `RunLoop.main` == main thread == `@MainActor`), or switch to `Timer.publish` + Combine with `.receive(on: RunLoop.main)` to eliminate the double-dispatch entirely.

---

### m3 — `MiningManager.terminationHandler` closure strong-captures `self` indirectly
**Location:** `MiningManager.swift:54–61`

The `Process.terminationHandler` closure captures `[weak self]` correctly, but the inner `Task { @MainActor in self?.… }` captures `self` with a strong reference for the duration of the task. If `MiningManager` is deallocated while the process is still running (e.g. during app teardown), the `Task` will keep `self` alive until the process exits and the task completes. This is a retain-cycle risk during shutdown rather than a memory safety issue, because `weak self` is properly used; however, the timer referenced inside (`self?.logTimer`) may have already been nilled by `stop()`, so the invalidation in the handler is a no-op that relies on `stop()` having been called first.

**Recommendation:** This is low-risk with the current singleton architecture. If `MiningManager` gains a non-singleton lifecycle, add explicit process tracking and force-terminate in `deinit` before the handler fires.

---

### m4 — `Combine` sinks stored via field assignment without `.store(in:)`
**Location:** `CycleEngine.swift:67–79`, `BurnCycleApp.swift:35–43`

`settingsObserver`, `batteryObserver`, and `historyObserver` are assigned directly to `AnyCancellable?` properties. This is functionally correct (the field retains the cancellable, and setting it to `nil` or a new value cancels the previous subscription). However, if `onSettingsChanged` or `onBatteryChanged` are called from a scheduler that has not yet been isolated to `@MainActor` (e.g. the `debounce` scheduler fires on `RunLoop.main` which is main-thread but not guaranteed to be inside a `@MainActor` synchronous call), the inner `Task { @MainActor in … }` hop is needed for safety — which is already present. The pattern is acceptable but fragile: a future change removing the `Task` hop would introduce a `@MainActor` isolation violation.

**Recommendation:** Document in comments that the `Task { @MainActor in … }` wrapper inside each sink is load-bearing for actor isolation, not just style.

---

### m5 — `StressManager` GPU task captures `commandQueue` and `pipelineState` from `@MainActor` into `Task.detached`
**Location:** `StressManager.swift:80–92`

`commandQueue` (`MTLCommandQueue`) and `pipelineState` (`MTLComputePipelineState`) are `@MainActor`-isolated stored properties of `StressManager`. The `Task.detached` GPU loop captures them by value at the point of the `if let` binding (line 72), which occurs on `@MainActor`, so the initial capture is safe. However, both Metal objects are not `Sendable` (they are Objective-C objects bridged without `@Sendable` annotation). Swift 6 strict concurrency would normally flag this; the compiler accepts it here because `MTLCommandQueue` and `MTLComputePipelineState` gain implicit `Sendable` conformance as `AnyObject` in the current toolchain. If Metal's thread-safety guarantees change or the toolchain tightens, this pattern will break.

**Recommendation:** Explicitly annotate the capture as intentional with a `// SAFETY:` comment explaining that `MTLCommandQueue.makeCommandBuffer()` is documented as thread-safe. Consider wrapping the GPU loop in a small non-isolated actor that owns the Metal objects rather than borrowing them from a `@MainActor` class.

---

## Nitpick

### n1 — `BatteryMonitor.refreshHealthDetail()` sets `lastHealthRead` before the subprocess completes
**Location:** `BatteryMonitor.swift:186`

`lastHealthRead = Date()` is stamped synchronously before the detached task runs. If `system_profiler` fails (bad exit, parse error), `healthPercent` is not updated but `lastHealthRead` is already set, silently suppressing retries for the next hour.

**Recommendation:** Set `lastHealthRead` only inside the `MainActor.run` block on success, or reset it in the failure path.

---

### n2 — `CycleEngine` has no `deinit` — observer/timer cleanup is only reachable via `stop()`
**Location:** `CycleEngine.swift` (whole file)

As acknowledged in the audit brief, `CycleEngine` is effectively a singleton. But the absence of `deinit` means any future refactor that introduces a second instance (e.g. SwiftUI previews, unit tests) will silently leak timers and notification observers.

**Recommendation:** Add a `deinit` that calls `stop()` and removes NSWorkspace observers as a defensive measure.

---

### n3 — `MiningManager.stop()` escalates to `SIGINT` not `SIGKILL`
**Location:** `MiningManager.swift:106`

The comment says "force kill" but `process.interrupt()` sends `SIGINT`, not `SIGKILL`. `xmrig` handles `SIGINT` gracefully (same as `SIGTERM`), so this is not a kill escalation in practice.

**Recommendation:** Use `kill(proc.processIdentifier, SIGKILL)` for a true force-kill, or update the comment to say "send SIGINT as final escalation."

---

## Summary

**0 Critical, 5 Major, 5 Minor, 3 Nitpicks**
