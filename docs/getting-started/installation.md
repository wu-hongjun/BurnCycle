# Installation

## Prerequisites

- **macOS 14+** on Apple Silicon (M1/M2/M3/M4)
- **HomeKit smart outlet** connected to your MacBook charger
- **Apple Shortcuts app** with two shortcuts configured

## Setting Up Shortcuts

BurnCycle controls your charger by running Apple Shortcuts that toggle a HomeKit smart outlet.

### 1. Create "Start Charging" Shortcut

1. Open **Shortcuts.app**
2. Create a new shortcut named **"Start Charging"**
3. Add action: **Control [Your Outlet Name]** → **Turn On**
4. Save

### 2. Create "Stop Charging" Shortcut

1. Create a new shortcut named **"Stop Charging"**
2. Add action: **Control [Your Outlet Name]** → **Turn Off**
3. Save

!!! tip
    Test both shortcuts manually first to make sure they toggle your outlet correctly. BurnCycle will also run a preflight test on every Start to verify the shortcuts actually work.

!!! warning "Single Power Source Required"
    Make sure your charger is the **only** power source connected. If you have a Thunderbolt dock, USB-C hub with PD passthrough, or other power adapter plugged in, the preflight test will fail because turning off the controlled outlet won't actually disconnect AC.

## Building the App

```bash
git clone https://github.com/wu-hongjun/BurnCycle.git
cd BurnCycle
./build.sh
```

The build script compiles the Swift Package Manager target, bundles the included `xmrig` arm64 binary, compiles the Liquid Glass app icon asset catalog, and produces `BurnCycle.app` at the repo root.

## Installing

```bash
cp -r BurnCycle.app /Applications/
open /Applications/BurnCycle.app
```

## First Launch

1. Click **Settings**
2. Verify shortcut names match yours (default: "Start Charging" / "Stop Charging")
3. Use the **Test** buttons to confirm your outlet toggles
4. Adjust thresholds if desired (default: charge to 90%, drain to 5%)
5. Pick a load method (default: Stress Test, works offline)
6. Click **Start** — BurnCycle runs a preflight test and begins cycling
