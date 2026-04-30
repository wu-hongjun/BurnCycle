# Architecture

## Project Structure

```
BurnCycle/
├── BurnCycleApp.swift                  # App entry point, wires services
├── Models/
│   └── AppSettings.swift               # UserDefaults persistence, LoadMethod enum
├── Services/
│   ├── BatteryMonitor.swift            # IOKit: battery %, cycles, health, temp, charger, capacities
│   ├── ChargingController.swift        # Apple Shortcuts for HomeKit outlet
│   ├── CycleEngine.swift               # State machine + load management + safety + preflight
│   ├── HistoryRecorder.swift           # Persistent JSON history of cycle/capacity/health
│   ├── MiningManager.swift             # xmrig process (bundled binary)
│   ├── StressManager.swift             # Built-in CPU+GPU stress test
│   └── SystemMonitor.swift             # CPU %, GPU % (IOReport), power draw
├── Views/
│   └── MainView.swift                  # Single-view UI with Settings/Info/History panels
├── Resources/
│   └── xmrig                           # Bundled xmrig arm64 binary
└── Assets.xcassets/                    # Liquid Glass app icon
```

## Services

### BatteryMonitor

Two-tier polling for efficiency:

- **Fast tier (every 2s)**: percentage, isPluggedIn, isCharging, charger watts, temperature, voltage, current capacity, charging watts
- **Slow tier (every 60s)**: cycle count, serial, design capacity, full charge capacity, Apple-reported health (via `system_profiler SPPowerDataType`)

Sources:

- **IOPowerSources** — percentage, charging state, AC status
- **AppleSmartBattery** — cycle count, temperature, voltage, amperage, charger details, serial, capacities
- **system_profiler SPPowerDataType** — Apple's reported "Maximum Capacity %" (matches About This Mac)

### SystemMonitor

- **CPU**: `host_statistics(HOST_CPU_LOAD_INFO)` — aggregate tick counters, delta-based, host port cached to prevent leaks
- **GPU**: `IOReportCopyChannelsInGroup("GPU Stats")` — P-state residency via IOReport private API (matches mactop's exact implementation)
- **Power**: Battery amperage × voltage from AppleSmartBattery

### CycleEngine

State machine with four states: `IDLE`, `TESTING`, `CHARGING`, `DRAINING`.

Safety layers:

1. **Preflight test** — verifies outlet actually toggles power before cycling begins
2. **Reactive observer** on `battery.percentage` — triggers immediately on change (no polling delay)
3. **Safety margin** — stops load 3% above drain threshold
4. **Critical safety** — force charges at 3% regardless of state, bypasses cooldown
5. **Timer** — 10-second tick for load management
6. **Smart throttle** — pauses load when CPU/GPU >80% from external apps
7. **Method switching** — detects `loadMethod` changes via Combine observer
8. **Power state verification** — retries shortcut up to 3 times if hardware state doesn't match expected
9. **Mismatch warnings** — UI shows specific errors (e.g. "WAITING FOR AC", "Still charging")

### MiningManager

Launches bundled xmrig as a child process. Parses hashrate from `--log-file` (xmrig doesn't write to stdout). Hardcoded pool (nanopool) and default wallet. Supports custom wallet override.

Stop sequence: SIGTERM → wait 3 seconds → SIGINT escalation if still running. Log file truncated on each start to avoid stale data.

### StressManager

- **CPU**: Spawns one `Task.detached(priority: .high)` per logical core doing trigonometric math loops
- **GPU**: Metal compute shader with 2M floats, intensive `sin/cos/tan/sqrt/fma` per element
- **Graceful failure**: Metal allocation failures are guarded (no force-unwraps)

### ChargingController

Runs `/usr/bin/shortcuts run "<name>"` via `Process`. Per-action 30-second cooldown (start and stop are independent). Critical charging accepts a `force: true` flag to bypass cooldown for safety. Tracks running status and last error.

### HistoryRecorder

Persists snapshots to `~/Library/Application Support/BurnCycle/history.json` as ISO8601-encoded JSON. Records when:

- Cycle count changes (every new full cycle)
- Daily snapshot (first observation of a new day)
- First observation ever

Each entry tracks: timestamp, cycle count, full charge capacity (mAh), Apple-reported health (%).

## Data Flow

```
BatteryMonitor (2s/60s) ──┬─→ CycleEngine ──→ ChargingController ──→ Apple Shortcuts
                          ├─→ HistoryRecorder (Combine observer)
                          └─→ MainView (Published)
SystemMonitor (3s) ───────→ CycleEngine ──→ MiningManager / StressManager
AppSettings ──────────────→ CycleEngine (Combine observer for live changes)
```
