# Quick Start

## 1. Build and Install

```bash
git clone https://github.com/wu-hongjun/BurnCycle.git
cd BurnCycle
./build.sh
cp -r BurnCycle.app /Applications/
open /Applications/BurnCycle.app
```

## 2. Configure Shortcuts

In the app, click **Settings** and verify the shortcut names match yours. Click **Test** to confirm they toggle your outlet.

## 3. Choose Load Method

Under **Load Generation** in Settings:

| Method | Internet | What it does |
|--------|----------|-------------|
| **Stress Test** (default) | Not needed | Burns CPU+GPU with native Swift/Metal |
| **Mine XMR** | Required | Mines Monero, earns crypto |

## 4. Start Cycling

Click **Start**. The app will:

1. **Run a preflight test** — toggles your outlet OFF then ON to verify it actually controls power (catches Thunderbolt docks, broken shortcuts, etc.)
2. **Charge** to your upper threshold (default 90%)
3. **Drain** with optional load until lower threshold (default 5%)
4. **Repeat** automatically

## 5. Monitor

The main window shows:

- **Row 1**: Battery %, health, cycle count
- **Row 2**: Cycle state, CPU %, GPU %, power draw
- **Row 3**: Load status (when active)

Three panels:

- **Settings** — thresholds, load method, wallet, shortcuts
- **Info** — detailed battery data (capacity, temperature, voltage, serial)
- **History** — recorded snapshots over time

## Safety

- Load stops 3% above your drain threshold (safety margin for shortcut)
- Emergency charge kicks in at 3% battery regardless of settings
- Load auto-pauses if other apps are using >80% CPU/GPU
- All physical state changes verified via IOKit, not just shortcut intent
