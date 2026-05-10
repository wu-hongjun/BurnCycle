# Memory & resource lifecycle audit

**Date:** 2026-05-10  
**Scope:** BurnCycle macOS menubar app — IOKit, subprocess, Combine, NSWorkspace observer, and Timer lifecycle correctness  
**Auditor:** codex-reviewer (read-only pass)

---

## HIGH Severity

### H1 — MiningManager: xmrig zombie process after `stop()` — no `waitUntilExit()`

**Location:** `BurnCycle/BurnCycle/Services/MiningManager.swift` — `stop()`, lines 81–108

**Issue:** After calling `proc.terminate()`, the process reference is immediately nilled out (`process = nil`) and a `Task.detached` polls `isRunning` for up to 3 s before calling `interrupt()`. Neither the synchronous path nor the fallback escalation ever calls `waitUntilExit()`. POSIX requires the parent to `wait()` on a terminated child; without it the child stays in Z (zombie) state until the app exits. If xmrig is stopped and restarted repeatedly (e.g., across many battery cycles) the zombie table grows. Additionally, `interrupt()` sends `SIGINT`, not `SIGKILL` — if xmrig has already ignored SIGTERM, SIGINT is also likely to be ignored, leaving the process alive.

**Recommendation:** After `proc.terminate()`, call `proc.waitUntilExit()` (either inline or inside the detached Task, after the polling loop) to reap the zombie. For the hard-kill path, use `kill(proc.processIdentifier, SIGKILL)` via `Foundation.kill` or `process.interrupt()` only as a pre-SIGKILL step; then follow with `waitUntilExit()`.

---

### H2 — CycleEngine: `sleepObserver` / `wakeObserver` never removed — no `deinit`

**Location:** `BurnCycle/BurnCycle/Services/CycleEngine.swift` — `init`, lines 83–90; no `deinit` present

**Issue:** `NSWorkspace.shared.notificationCenter.addObserver(forName:object:queue:using:)` returns an opaque `NSObjectProtocol` token that must be passed to `removeObserver(_:)` when no longer needed. `CycleEngine` stores these tokens in `sleepObserver` and `wakeObserver` but has no `deinit` that calls `removeObserver`. While the closures use `[weak self]` (preventing a retain cycle that would keep `CycleEngine` alive indefinitely), the notification center still holds a strong reference to the observer block object itself. This means the block is retained by `NSWorkspace.notificationCenter` for the lifetime of the app, and if `CycleEngine` were ever recreated the old blocks would accumulate and fire on the deallocated instance. Even in the current single-instance design this is a latent bug that would cause issues if the architecture changes.

**Recommendation:** Add a `deinit` to `CycleEngine` that calls:
```swift
deinit {
    if let o = sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    if let o = wakeObserver  { NSWorkspace.shared.notificationCenter.removeObserver(o) }
}
```

---

### H3 — ChargingController: error `Pipe` file descriptor not closed on timeout path

**Location:** `BurnCycle/BurnCycle/Services/ChargingController.swift` — `runShortcut`, lines 107–147

**Issue:** `errPipe` is created and attached to `process.standardError`. On the timeout path (`didTimeout.get() == true`), `readDataToEndOfFile()` on `errPipe.fileHandleForReading` is never called and the pipe's file descriptors are never explicitly closed. `Process` does not automatically close attached pipe file handles when terminated; the write-end of the pipe remains open inside the terminated (but not yet reaped) process until `waitUntilExit()` clears it, and the read-end is held by `errPipe` on the Swift heap. Because `process.waitUntilExit()` IS called in this path (line 132), the write-end closes on exit, but the read-end file handle object (`errPipe.fileHandleForReading`) is never explicitly closed — it relies on ARC of the local `errPipe` to close it. This is safe only if `errPipe` is not captured elsewhere; currently it is not, but it is a fragile pattern. More critically, if `process.run()` throws (the `catch` path at line 148), `errPipe` is also left without an explicit close.

**Recommendation:** Explicitly close the pipe's read handle after consuming (or deciding not to consume) stderr data:
```swift
defer { try? errPipe.fileHandleForReading.close() }
```
Place the defer immediately after `errPipe` is created so it covers all exit paths including the throw path.

---

## MEDIUM Severity

### M1 — SystemMonitor: `mach_host_self()` port stored as a stored property — never deallocated

**Location:** `BurnCycle/BurnCycle/Services/SystemMonitor.swift` — line 46

**Issue:** `mach_host_self()` returns the host port with an added send right; the caller is responsible for calling `mach_port_deallocate(mach_task_self(), hostPort)` when finished. Storing it as `private let hostPort` with no `deinit` to release the send right leaks a Mach port for the lifetime of the app. While macOS is tolerant of this for a single port, it is technically incorrect and is a resource leak.

**Recommendation:** Add a `deinit` to `SystemMonitor` that calls `mach_port_deallocate(mach_task_self(), hostPort)`.

---

### M2 — BatteryMonitor: `refreshHealthDetail` Task.detached does not close the `Pipe` read handle

**Location:** `BurnCycle/BurnCycle/Services/BatteryMonitor.swift` — `refreshHealthDetail()`, lines 186–207

**Issue:** `pipe.fileHandleForReading.readDataToEndOfFile()` is called and the data consumed, but `pipe.fileHandleForReading` is never explicitly closed. The `Pipe` object is local to the detached task closure and will be released when the closure exits, which triggers `FileHandle.deinit` and an implicit close — so in practice there is no fd leak in steady state. However, `proc.run()` is called with `try?`, silently swallowing launch errors. If `proc.run()` fails, `proc.waitUntilExit()` on line 194 is still called on a process that never started (the call is a no-op, so no crash), but the pipe's write-end is never connected, `readDataToEndOfFile()` will block until ARC releases the pipe. This is an implicit deadlock on the detached thread if the executable is missing or permission-denied.

**Recommendation:** Guard the `proc.waitUntilExit()` and `readDataToEndOfFile()` calls behind a successful `try proc.run()` (use `do/catch` instead of `try?`). Explicitly close the read handle with `defer { try? pipe.fileHandleForReading.close() }`.

---

### M3 — MiningManager: `logTimer` not invalidated when `terminationHandler` fires on a non-main thread

**Location:** `BurnCycle/BurnCycle/Services/MiningManager.swift` — `start()`, lines 54–62 and 70–74

**Issue:** `Process.terminationHandler` is documented to fire on an arbitrary background queue. The handler dispatches a `Task { @MainActor in … }` to invalidate `logTimer`, which is correct for the `@Published` property updates but introduces a window: between when `terminationHandler` fires and when the main-actor task executes, the timer can still fire and call `readLog()`. Because `logTimer` is a `@MainActor`-isolated stored property, accessing it from the termination handler's background queue without hopping to main actor is a data race in Swift 6 strict concurrency (the `Task { @MainActor in }` wrapper only protects the body, not the closure capture of `self`). If the timer fires in this window after the process has exited, `FileHandle(forReadingAtPath:)` opens the log file on a now-complete write, which is benign, but the threading discipline is unsound.

**Recommendation:** Mark `terminationHandler` assignment with `@Sendable` awareness; use `DispatchQueue.main.async` rather than a `Task` to ensure the timer invalidation is synchronous with respect to the main run loop, or restructure so the timer is invalidated in `stop()` before `proc.terminate()` (which is already partially done — `stop()` invalidates `logTimer` — but the `terminationHandler` path runs if the process exits on its own without `stop()` being called).

---

## LOW Severity

### L1 — CycleEngine: `preflightTask` strong-captures `self` (implicit)

**Location:** `BurnCycle/BurnCycle/Services/CycleEngine.swift` — `runPreflightTest()`, line 187

**Issue:** `Task { @MainActor [weak self] in … }` correctly uses `weak self`. No issue here — flagged for completeness as the pattern is correct.

**Finding:** PASS on this point.

---

### L2 — SystemMonitor timer uses `[weak self]` correctly; `stopMonitoring` invalidates

**Location:** `BurnCycle/BurnCycle/Services/SystemMonitor.swift` — lines 65–75

**Finding:** Timer is invalidated in `stopMonitoring`. `[weak self]` present. PASS.

---

### L3 — BatteryMonitor timers: all three invalidated in `stopMonitoring`

**Location:** `BurnCycle/BurnCycle/Services/BatteryMonitor.swift` — lines 63–70

**Finding:** `fastTimer`, `slowTimer`, and `healthTimer` are all invalidated and nilled. `[weak self]` used in all three closures. PASS.

---

### L4 — CycleEngine `timer` invalidated in `stop()`

**Location:** `BurnCycle/BurnCycle/Services/CycleEngine.swift` — `stop()`, lines 281–292

**Finding:** `timer?.invalidate(); timer = nil` present. `[weak self]` used in `beginCycling`. PASS.

---

### L5 — AppServices `historyObserver` AnyCancellable held strongly

**Location:** `BurnCycle/BurnCycle/BurnCycleApp.swift` — `AppServices`, line 17

**Finding:** `private var historyObserver: AnyCancellable?` is stored strongly on the container object. The sink uses `[weak self]`. Correct pattern; no premature teardown, no retain cycle. PASS.

---

### L6 — CycleEngine Combine observers held strongly with `[weak self]` sinks

**Location:** `BurnCycle/BurnCycle/Services/CycleEngine.swift` — lines 33–34, 67–79

**Finding:** `settingsObserver` and `batteryObserver` are stored as `AnyCancellable?` properties; sinks use `[weak self]`. No retain cycle. PASS.

---

### L7 — IOKit `takeRetainedValue` vs `takeUnretainedValue` correctness

**Location:** `BatteryMonitor.swift` lines 88–91, 113–114; `SystemMonitor.swift` lines 211, 228–229

**Issue (low):** `IOPSGetPowerSourceDescription` returns an unretained reference (the caller does not own it) — `takeUnretainedValue()` on line 91 is correct. `IOPSCopyPowerSourcesInfo` and `IOPSCopyPowerSourcesList` follow Copy/Create rule — `takeRetainedValue()` on lines 88–89 is correct. `IORegistryEntryCreateCFProperties` follows the Create rule — `takeRetainedValue()` on lines 114, 163, 211, 229 is correct. All IOKit retain/release choices are correct.

**Finding:** PASS.

---

### L8 — MiningManager stop() does not call `waitUntilExit()` (zombie, see H1)

Covered under H1.

---

## Summary

| Severity | Count |
|----------|-------|
| High     | 3     |
| Medium   | 3     |
| Low      | 0 actionable (7 PASS confirmations) |
| **Total findings** | **6 (3H + 3M)** |

**Status: FAIL** — 3 high-severity and 3 medium-severity findings require remediation before this codebase can be considered resource-lifecycle correct.
