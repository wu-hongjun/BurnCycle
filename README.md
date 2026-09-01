# BurnCycle

A macOS app that automatically cycles your MacBook battery between configurable thresholds using a HomeKit smart outlet.

Full docs: [burncycle.hongjunwu.com](https://burncycle.hongjunwu.com/) (source under [`docs/`](docs/index.md)).

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
- **Preflight outlet test** — verifies the shortcut actually controls the only AC source (catches Thunderbolt docks, broken shortcuts, missing cable). Cached for 30 min after a successful run; a *Re-test outlet on next Start* button forces a fresh check.
- **Smart load detection** — auto-throttles when other apps are heavy (>80% CPU/GPU), with hysteresis to avoid flapping
- **Multi-layer safety**
    - Emergency charge at 3% — fires regardless of cycle state while running, with a one-shot idle safeguard even when stopped
    - Retry-forever cadence (~60s) on shortcut failure, naming a second power source / Thunderbolt dock if detected
    - Safety margin stops load 3% above the lower threshold
    - Charging-stall watchdog warns (non-fatal) after 90 min stuck below the upper threshold (macOS Optimized Battery Charging may cap at 80%)
    - Refuses to start on a desktop Mac with no internal battery
    - Threshold sliders are clamped so upper > lower with a 5% gap
- **Detailed battery info** — capacity (mAh), Real vs Apple-reported health, serial, voltage, temperature, charger wattage
- **History tab** — persistent log of cycle count, capacity, and health over time
- **Real-time monitoring** — battery %, CPU %, GPU % (via IOReport, matches mactop), power draw
- **Menu-bar mode** — optional `MenuBarExtra` with CPU load, temperature,
  battery power, phase ETA, health, cycles, and Start/Stop; battery percentage
  text can be enabled separately
- **Liquid Glass icon** — refined for macOS 26 aesthetic
- **Zero config** — wallet, pool, and xmrig binary all bundled (xmrig is SHA-256-verified at every launch)

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
5. Click **Start** (or press ⌘↩) — the app runs a preflight test and begins cycling

Click **Info** for detailed battery data, or **History** to view recorded snapshots over time. Enable **Show in menu bar** in Settings to add a `MenuBarExtra` with a state icon and inline Start/Stop button — useful when the main window is closed. Battery percentage beside the icon is optional and off by default.

After a successful preflight the result is cached for 30 minutes so subsequent Start presses skip the outlet test. Use the **Re-test outlet on next Start** button (Settings ▸ Outlet Control) to invalidate that cache — for example after swapping hubs or moving the plug.

## Architecture

```
BurnCycle/
├── BurnCycleApp.swift              # App entry point, wires services, MenuBarExtra
├── BurnCycle.entitlements          # Hardened-runtime entitlements (sandbox off, documented)
├── Info.plist                      # Bundle metadata: category, copyright, version
├── Models/
│   └── AppSettings.swift           # UserDefaults persistence, LoadMethod enum, threshold clamp
├── Services/
│   ├── BatteryMonitor.swift        # IOKit battery %, cycles, health, charger, etc.
│   ├── ChargingController.swift    # Apple Shortcuts for HomeKit outlet
│   ├── CycleEngine.swift           # State machine + load management + safety + preflight
│   ├── HistoryRecorder.swift       # Persistent JSON history of cycle/capacity/health
│   ├── MiningManager.swift         # xmrig process (bundled binary, SHA-256-verified at launch)
│   ├── StressManager.swift         # Built-in CPU+GPU stress test
│   └── SystemMonitor.swift         # CPU %, GPU % (IOReport), power draw
├── Views/
│   └── MainView.swift              # Single-view UI with Settings/Info/History panels
├── Resources/
│   ├── xmrig                       # Bundled xmrig arm64 binary
│   └── xmrig.sha256                # Post-sign hash, sealed by the outer app signature
└── Assets.xcassets/                # Liquid Glass app icon
```

## Settings

| Setting | Default | Description |
|---------|---------|-------------|
| Charge to | 90% | Upper threshold — stop charging. Clamped to at least lower + 5%. |
| Drain to | 5% | Lower threshold — start charging. Clamped to at most upper − 5%. |
| Generate load | ON | Enable load during drain phase |
| Method | Stress Test | Stress Test or Mine XMR |
| Wallet | (built-in) | Custom XMR wallet (empty = developer's donation wallet — see Privacy below) |
| Start/Stop Shortcuts | "Start Charging" / "Stop Charging" | HomeKit shortcut names |
| Show in menu bar | OFF | Adds a `MenuBarExtra` with a state icon and Start/Stop |
| Show battery percentage | OFF | Shows battery % beside the menu-bar icon when menu-bar mode is enabled |
| Hide Dock icon | OFF | Removes the Dock icon while menu-bar mode is enabled |
| Pause cycling when Mac sleeps | ON | Stops the cycle on sleep, resumes on wake (preflight is skipped on auto-resume) |

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
  mines **to the developer**, not to you. The app surfaces this explicitly in
  the status line ("Mining (default donation wallet)") so it is never silent.
- **xmrig is hash-verified at every launch.** Before exec, the app computes a
  SHA-256 of the bundled `Resources/xmrig` binary and compares it against the
  sealed `Resources/xmrig.sha256` recorded at build time. If the binary has been
  swapped or tampered with, mining fails closed with "xmrig integrity check
  failed" and the process is never spawned.
- **How to mine to your own wallet:** open **Settings** and enter your own XMR
  wallet address in the **Wallet** field. Your hashrate will then credit your
  wallet instead.
- **How to opt out entirely:** leave **Generate load** off, or use the **Stress
  Test** method, which performs the same battery-draining work with zero network
  activity.

## License

MIT
