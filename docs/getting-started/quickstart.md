# Quick Start

## 1. Build and Install

```bash
git clone https://github.com/wu-hongjun/burn-cycle.git
cd burn-cycle
./build.sh
cp -r BurnCycle.app /Applications/
open /Applications/BurnCycle.app
```

## 2. Configure Shortcuts

In the app, click **Settings** and verify the shortcut names match yours. Click **Test** to confirm they work.

## 3. Choose Load Method

Under **Load Generation** in Settings:

| Method | Internet | What it does |
|--------|----------|-------------|
| **Stress Test** | Not needed | Burns CPU+GPU with native Swift/Metal |
| **Mine XMR** | Required | Mines Monero, earns crypto |

## 4. Start Cycling

Click **Start**. The app will:

- Charge to your upper threshold (default 95%)
- Turn off the outlet and drain (with optional load)
- Turn on the outlet when it hits the lower threshold (default 10%)
- Repeat

## 5. Monitor

The main window shows:

- **Row 1**: Battery %, health, cycle count
- **Row 2**: Cycle state, CPU %, GPU %, power draw
- **Row 3**: Load status (when active)

Click **Info** for detailed battery data (capacity, temperature, voltage, serial).

## Safety

- Mining/stress stops 3% above your drain threshold
- Emergency charge kicks in at 5% regardless
- Load auto-pauses if other apps are using >80% CPU/GPU
