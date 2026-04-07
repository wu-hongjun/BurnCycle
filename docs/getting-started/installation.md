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
    Test both shortcuts manually first to make sure they toggle your outlet correctly.

## Building the App

```bash
git clone https://github.com/wu-hongjun/BurnCycle.git
cd BurnCycle
./build.sh
```

## Installing

```bash
cp -r BurnCycle.app /Applications/
open /Applications/BurnCycle.app
```

## First Launch

1. Click **Settings**
2. Verify shortcut names match yours (default: "Start Charging" / "Stop Charging")
3. Use the **Test** buttons to confirm your outlet toggles
4. Adjust thresholds if desired (default: charge to 95%, drain to 10%)
5. Click **Start**
