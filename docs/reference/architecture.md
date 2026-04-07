# Architecture

## Project Structure

```
BurnCycle/
├── BurnCycleApp.swift          # App entry point, creates services
├── Models/
│   └── AppSettings.swift       # UserDefaults persistence, LoadMethod enum
├── Services/
│   ├── BatteryMonitor.swift    # IOKit: battery %, cycles, health, temp, charger
│   ├── ChargingController.swift # Apple Shortcuts for HomeKit outlet
│   ├── CycleEngine.swift       # State machine + load management + safety
│   ├── MiningManager.swift     # xmrig process (bundled binary)
│   ├── StressManager.swift     # Built-in CPU+GPU stress test
│   └── SystemMonitor.swift     # CPU %, GPU % (IOReport), power draw
├── Views/
│   └── MainView.swift          # Single-view UI with Settings/Info panels
├── Resources/
│   └── xmrig                   # Bundled xmrig arm64 binary
└── Assets.xcassets/            # App icon
```

## Services

### BatteryMonitor

Reads battery data from IOKit every 2 seconds:

- **IOPowerSources**: percentage, charging state, power source
- **AppleSmartBattery**: cycle count, temperature, voltage, amperage, charger details, serial, capacities
- **system_profiler**: Apple's reported health percentage (run once)

### SystemMonitor

- **CPU**: `host_statistics(HOST_CPU_LOAD_INFO)` — aggregate tick counters, delta-based
- **GPU**: `IOReportCopyChannelsInGroup("GPU Stats")` — P-state residency via IOReport private API (matches mactop)
- **Power**: Battery amperage × voltage from AppleSmartBattery

### CycleEngine

State machine with three states: `IDLE`, `CHARGING`, `DRAINING`.

Safety layers:

1. **Reactive observer** on `battery.percentage` — triggers immediately on change
2. **Safety margin** — stops load 3% above drain threshold
3. **Critical safety** — force charges at 5% regardless
4. **Timer** — 10-second tick for load management
5. **Smart throttle** — pauses load when CPU/GPU >80% from external apps

### MiningManager

Launches bundled xmrig as a child process. Parses hashrate from `--log-file`. Hardcoded pool (`nanopool`) and default wallet. Supports custom wallet override.

### StressManager

- **CPU**: Spawns one `Task.detached(priority: .high)` per logical core doing trigonometric math loops
- **GPU**: Metal compute shader with 2M floats, intensive `sin/cos/tan/sqrt/fma` per element

### ChargingController

Runs `/usr/bin/shortcuts run "<name>"` via `Process`. 30-second cooldown to prevent rapid toggling. Tracks outlet state, last error, and running status.

## Data Flow

```
BatteryMonitor (2s) ──→ CycleEngine ──→ ChargingController
SystemMonitor  (3s) ──→ CycleEngine ──→ MiningManager / StressManager
AppSettings ─────────→ CycleEngine ──→ (reactive via Combine)
```
