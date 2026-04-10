# BurnCycle

A macOS app that automatically cycles your MacBook battery between configurable thresholds using a HomeKit smart outlet. Optionally mines Monero (XMR) during discharge to generate load and earn crypto from energy that would otherwise be wasted.

<img width="597" height="417" alt="image" src="https://github.com/user-attachments/assets/39ae44d2-a1c9-4b4f-b886-68bf4a08c78e" />


## How It Works

1. **Charge phase**: Outlet turns ON, battery charges up to the upper threshold (default 95%)
2. **Drain phase**: Outlet turns OFF, battery drains down to the lower threshold (default 10%)
3. **Repeat**: The cycle continues automatically

When the "Load" toggle is enabled, the app runs xmrig (bundled) during the drain phase to maximize power draw and mine XMR. Mining is smart — it checks CPU/GPU utilization and defers if the system is already under heavy load (>80%) from other applications.

## Features

- **Automatic battery cycling** via HomeKit smart outlet (Apple Shortcuts)
- **Optional XMR mining** during discharge (CPU + GPU via OpenCL)
- **Smart load detection** — mining auto-throttles when system is busy
- **System monitoring** — battery %, cycle count, health %, charger wattage, CPU/GPU usage, power draw
- **Compact UI** — two status lines, start/stop/pause controls, load toggle
- **Zero config** — wallet and pool hardcoded, xmrig bundled in app
- **Custom wallet** — optionally override the default wallet in settings

## Prerequisites

1. **macOS 14+** on Apple Silicon
2. **HomeKit smart outlet** connected to your charger
3. **Two Apple Shortcuts** configured in the Shortcuts app:
   - **"Start Charging"** — turns your smart outlet ON
   - **"Stop Charging"** — turns your smart outlet OFF

## Build & Install

```bash
./build.sh
cp -r BurnCycle.app /Applications/
open /Applications/BurnCycle.app
```

## Usage

1. Launch the app
2. Expand **Settings** and verify your shortcut names match (default: "Start Charging" / "Stop Charging")
3. Use the **Test** buttons to verify your shortcuts toggle the outlet
4. Toggle **Load** on if you want XMR mining during drain
5. Click **Start** — the app will begin cycling your battery automatically

## Architecture

```
BurnCycle/
├── BurnCycleApp.swift       # App entry point
├── Models/
│   └── AppSettings.swift        # UserDefaults persistence
├── Services/
│   ├── BatteryMonitor.swift     # IOKit battery %, cycles, health, charger W
│   ├── ChargingController.swift # Apple Shortcuts for HomeKit outlet
│   ├── CycleEngine.swift        # State machine + smart load management
│   ├── MiningManager.swift      # xmrig process (CPU+GPU, bundled binary)
│   └── SystemMonitor.swift      # CPU %, GPU %, battery power draw
├── Views/
│   └── MainView.swift           # Compact single-view UI
├── Resources/
│   └── xmrig                    # Bundled xmrig arm64 binary
└── Assets.xcassets/             # App icon
```

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Charge to | 95% | Upper threshold — stop charging |
| Drain to | 10% | Lower threshold — start charging |
| Load | ON | Mine XMR during drain phase |
| Wallet | (built-in) | XMR wallet address (leave empty for default) |
| Start/Stop Shortcuts | "Start Charging" / "Stop Charging" | HomeKit shortcut names |

## License

MIT
