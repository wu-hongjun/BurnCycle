# Ticket 09 — Stop spawning `system_profiler` every 60s

**Severity:** Minor (perf)
**File:** `BurnCycle/BurnCycle/Services/BatteryMonitor.swift`

## Problem

`updateSlow()` runs every 60 seconds. Inside it, `Task.detached` spawns `/usr/sbin/system_profiler SPPowerDataType` — a process that takes ~1-2 seconds and ~50MB of RAM — every minute, just to read the "Maximum Capacity" health value. Battery health changes at most once per week, often slower.

Energy/perf cost: the app spawns ~60 subprocesses per hour. Most return the same value. The IORegistry reads in the same method (`CycleCount`, `Serial`, `DesignCapacity`, `AppleRawMaxCapacity`) are cheap and should keep their 60s cadence.

## Fix

Split the slow path. Keep IORegistry reads on 60s. Move the `system_profiler` health read to:

1. **Once at app launch** (existing call from `init` / `startMonitoring` happens to cover this — verify path).
2. **Once per hour** while running.
3. **On demand** via a public `refreshHealth()` method that the cycle engine can call when a charge/drain transition completes (a meaningful moment to update reported capacity).

### Implementation

Refactor `BatteryMonitor.swift`:

```swift
private var slowTimer: Timer?
private var healthTimer: Timer?
private var lastHealthRead: Date = .distantPast
private let healthMinInterval: TimeInterval = 60 * 60   // 1 hour
```

Move the `system_profiler` block out of `updateSlow()` into its own private method:

```swift
private func refreshHealthDetail() {
    lastHealthRead = Date()
    Task.detached { [weak self] in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPPowerDataType"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8),
           let range = output.range(of: #"Maximum Capacity:\s+(\d+)%"#, options: .regularExpression) {
            let match = output[range]
            if let numRange = match.range(of: #"\d+"#, options: .regularExpression),
               let value = Int(match[numRange]) {
                await MainActor.run {
                    self?.healthPercent = value
                }
            }
        }
    }
}
```

Add a public on-demand method, gated by a minimum interval to avoid stampeding:

```swift
/// Trigger a fresh health read. No-op if a read happened recently
/// (within `healthMinInterval`) — caller doesn't need to throttle.
func refreshHealth() {
    if Date().timeIntervalSince(lastHealthRead) < healthMinInterval { return }
    refreshHealthDetail()
}
```

Wire up the cadence:

- In `init()`: call `refreshHealthDetail()` once unconditionally so cold launch shows a value immediately. Set `lastHealthRead = Date()`.
- In `startMonitoring()`: schedule a separate hourly timer that calls `refreshHealthDetail()`.
- Remove the `system_profiler` block from `updateSlow()` entirely.

```swift
healthTimer = Timer.scheduledTimer(withTimeInterval: healthMinInterval, repeats: true) { [weak self] _ in
    Task { @MainActor in
        self?.refreshHealthDetail()
    }
}
```

Don't forget to invalidate `healthTimer` in `stopMonitoring()`.

### CycleEngine integration (optional but recommended)

In `CycleEngine.swift`, after a successful `transitionToDraining()` (a cycle just completed), call `battery.refreshHealth()`. This gives the user a fresh health reading at the moment they care about it. The `refreshHealth` method will skip if it's been called within the hour, so this is safe.

```swift
private func transitionToDraining() {
    charging.stopCharging(shortcutName: settings.stopChargingShortcut)
    if settings.loadEnabled { /* ... */ }
    state = .draining
    verifyTicksRemaining = 2
    battery.refreshHealth()        // ← add this
    // mismatchWarning = nil  (or whatever Ticket 07 has done to it)
}
```

(Same for `transitionToCharging()` if you prefer marking both ends. Once per cycle is plenty.)

## Acceptance

- Launching the app → `healthPercent` is populated within ~3s (one `system_profiler` call at launch).
- Running `ps aux | grep system_profiler` repeatedly over 5 minutes → at most 1 process visible during initial read; never 5+ as before.
- After 1 hour the timer fires → one new `system_profiler` call.
- Manually trigger a charge/drain transition (or wait for one) → `refreshHealth()` fires; `system_profiler` runs once and updates the published value.
- `swift build -c release` succeeds.

## Notes

- The 1-hour cadence is conservative. If you'd rather only read on-demand and at launch, drop the hourly timer entirely and let `CycleEngine` pull. But the timer is cheap and gives a sane fallback for users who never complete a cycle.
- Do not move IORegistry reads out of `updateSlow`. They are fast and need to stay on 60s.
