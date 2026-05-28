# BurnCycle

A macOS app that automatically cycles your MacBook battery between configurable thresholds using a HomeKit smart outlet.

<img width="597" height="417" alt="image" src="https://github.com/user-attachments/assets/39ae44d2-a1c9-4b4f-b886-68bf4a08c78e" />

## How It Works

1. **Charge phase**: Outlet turns ON, battery charges up to the upper threshold (default 90%)
2. **Drain phase**: Outlet turns OFF, battery drains down to the lower threshold (default 5%)
3. **Repeat**: The cycle continues automatically

When the **Generate load** toggle is enabled, the app generates load during the drain phase to maximize power draw. Two methods are available:

- **Stress Test** (default) — built-in CPU + GPU stress via native Swift/Metal, works offline
- **Mine XMR** — bundled xmrig mines Monero (CPU + GPU via OpenCL), needs internet

Load is smart — it auto-throttles when system is already under heavy load (>80% CPU/GPU) from other applications.

## Features

- **Automatic battery cycling** via HomeKit smart outlet (Apple Shortcuts)
- **Two load methods**: built-in offline stress test, or XMR mining
- **Preflight outlet test** on every Start — verifies shortcut actually controls the only AC source (catches Thunderbolt docks, broken shortcuts, missing cable)
- **Smart load detection** — auto-throttles when other apps are heavy
- **Multi-layer safety** — emergency charge at 3%, safety margin stops load 3% above threshold, reactive battery observer
- **Detailed battery info** — capacity (mAh), Real vs Apple-reported health, serial, voltage, temperature, charger wattage
- **History tab** — persistent log of cycle count, capacity, and health over time
- **Real-time monitoring** — battery %, CPU %, GPU % (via IOReport, matches mactop), power draw
- **Liquid Glass icon** — refined for macOS 26 aesthetic
- **Zero config** — wallet, pool, and xmrig binary all bundled

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

### Signing & Gatekeeper

`build.sh` applies an **ad-hoc signature** by default, which is fine for an app
you build and run on your own Mac. It does **not** enable the App Sandbox: the
app spawns subprocesses (Shortcuts, the bundled `xmrig`) and reads private
IOKit/IOReport symbols for battery and GPU stats, all of which a strict sandbox
would block. It is instead signed with the **hardened runtime** plus the minimal
entitlements in `BurnCycle/BurnCycle/BurnCycle.entitlements`.

If you **download a prebuilt `BurnCycle.zip`** (rather than building it
yourself), macOS attaches the `com.apple.quarantine` attribute. Because the app
is not signed with a paid Developer ID and notarized, Gatekeeper will block it
with *"BurnCycle is damaged and can't be opened."* Remove the quarantine flag
recursively (this also clears it from the bundled `xmrig` binary):

```bash
xattr -dr com.apple.quarantine /Applications/BurnCycle.app
```

To distribute to others without this step, build with a Developer ID and
notarize:

```bash
# Sign with your Developer ID (enables the hardened runtime + entitlements)
BURNCYCLE_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh

# Sign AND notarize (requires a stored notarytool keychain profile)
BURNCYCLE_SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
BURNCYCLE_NOTARY_PROFILE="BurnCycleNotary" ./build.sh
```

See the comments in `build.sh` for the one-time `notarytool store-credentials`
setup.

## Usage

1. Launch the app
2. Click **Settings** and verify your shortcut names match (default: "Start Charging" / "Stop Charging")
3. Use the **Test** buttons to verify your shortcuts toggle the outlet
4. Choose load method (default: Stress Test) and toggle on if desired
5. Click **Start** — the app runs a preflight test and begins cycling

Click **Info** for detailed battery data, or **History** to view recorded snapshots over time.

## Architecture

```
BurnCycle/
├── BurnCycleApp.swift              # App entry point, wires services
├── Models/
│   └── AppSettings.swift           # UserDefaults persistence, LoadMethod enum
├── Services/
│   ├── BatteryMonitor.swift        # IOKit battery %, cycles, health, charger, etc.
│   ├── ChargingController.swift    # Apple Shortcuts for HomeKit outlet
│   ├── CycleEngine.swift           # State machine + load management + safety + preflight
│   ├── HistoryRecorder.swift       # Persistent JSON history of cycle/capacity/health
│   ├── MiningManager.swift         # xmrig process (bundled binary)
│   ├── StressManager.swift         # Built-in CPU+GPU stress test
│   └── SystemMonitor.swift         # CPU %, GPU % (IOReport), power draw
├── Views/
│   └── MainView.swift              # Single-view UI with Settings/Info/History panels
├── Resources/
│   └── xmrig                       # Bundled xmrig arm64 binary
└── Assets.xcassets/                # Liquid Glass app icon
```

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Charge to | 90% | Upper threshold — stop charging |
| Drain to | 5% | Lower threshold — start charging |
| Generate load | ON | Enable load during drain phase |
| Method | Stress Test | Stress Test or Mine XMR |
| Wallet | (built-in) | Custom XMR wallet (empty = developer's wallet, supports development) |
| Start/Stop Shortcuts | "Start Charging" / "Stop Charging" | HomeKit shortcut names |

## Privacy & Mining

BurnCycle is a local app and does not phone home. However, the **Mine XMR** load
method has privacy implications you should understand:

- **Mining is opt-in.** It only runs when you enable the **Generate load** toggle
  *and* select the **Mine XMR** method. With the default **Stress Test** method,
  nothing leaves your device. Mining is off unless you turn it on.
- **What leaves your device when mining:** your configured XMR wallet address and
  your hashrate are sent to the mining pool (`nanopool.org`) over TLS. No other
  personal data is transmitted.
- **The default wallet is the developer's.** If you leave the **Wallet** field
  empty, mining proceeds to the developer's Monero donation wallet to support
  development. This means that with the default settings, enabling XMR mining
  mines **to the developer**, not to you.
- **How to mine to your own wallet:** open **Settings** and enter your own XMR
  wallet address in the **Wallet** field. Your hashrate will then credit your
  wallet instead.
- **How to opt out entirely:** leave **Generate load** off, or use the **Stress
  Test** method, which performs the same battery-draining work with zero network
  activity.

## License

MIT
