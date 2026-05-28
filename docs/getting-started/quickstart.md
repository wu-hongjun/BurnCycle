# Quick Start

## 1. Build and Install

```bash
git clone https://github.com/wu-hongjun/BurnCycle.git
cd BurnCycle
./build.sh
cp -r BurnCycle.app /Applications/
open /Applications/BurnCycle.app
```

The default build is ad-hoc signed and runs locally. For distribution and Gatekeeper notes, see [Installation](installation.md#signing).

## 2. Configure Shortcuts

In the app, click **Settings** and verify the shortcut names match yours (default: "Start Charging" / "Stop Charging"). Click **Test** next to each to confirm they actually toggle your outlet.

!!! warning "One power source only"
    Unplug Thunderbolt docks, USB-C hubs with PD passthrough, or any second adapter. If turning the controlled outlet off doesn't actually disconnect AC, the preflight test will fail.

## 3. Choose Load Method

Under **Load Generation** in Settings, leave *Generate load while draining* on (default) and pick a method:

| Method | Internet | What it does |
|--------|----------|--------------|
| **Stress Test** (default) | Not needed | Burns CPU+GPU with native Swift/Metal |
| **Mine XMR** | Required | Mines Monero via the bundled `xmrig` |

Mining is opt-in. If you switch to *Mine XMR* without pasting a wallet, the status line reads *"Mining (default donation wallet)"* and proceeds against the developer's wallet.

## 4. Start Cycling

Click **Start** (or press **⌘↩**). On the first Start the app will:

1. **Run a preflight outlet test** — toggles OFF then ON, watching IOKit to verify AC actually disconnects and reconnects (catches Thunderbolt docks, broken shortcuts, unplugged cable).
2. **Charge** to your upper threshold (default 90%).
3. **Drain** with optional load until lower threshold (default 5%).
4. **Repeat** automatically.

Thresholds are clamped to keep a minimum **5% gap** even if you drag the sliders past each other.

!!! tip "Subsequent Starts skip preflight"
    A successful preflight result is cached for **30 minutes**. Stop and re-Start within that window and cycling resumes immediately. Need a fresh test (cable moved, dock plugged in)? Hit **Re-test outlet on next Start** in Settings — the next Start runs preflight again. ⌘↩ also toggles Stop.

## 5. Monitor

The main window shows:

- **Row 1**: Battery %, health, cycle count
- **Row 2**: Cycle state, CPU %, GPU %, power draw
- **Row 3**: Load status (when active)

Three panels:

- **Settings** — thresholds, load method, wallet, shortcuts, *Re-test outlet on next Start*, menu-bar toggle
- **Info** — detailed battery data (capacity, temperature, voltage, serial)
- **History** — recorded snapshots over time

## Safety behaviors you may see

- **Stress / Mining auto-pauses** when other apps push CPU or GPU above 80%, and resumes when they drop.
- **Load stops 3% above your drain threshold** so the shortcut has time to disconnect AC before the OS triggers low-power mode.
- **Emergency charge** fires at ≤3% battery regardless of state, then re-arms.
- **Charging-stall warning** appears (non-fatal, keeps cycling) if charging hasn't crossed the upper threshold after 90 minutes — usually macOS Optimized Battery Charging capping at 80%. Disable it in *System Settings ▸ Battery* to clear.
- **Desktop Mac refusal** — without an internal battery the engine refuses to start with *"No internal battery detected — cannot cycle."*
- **State verification** — every physical transition is verified via IOKit, not just shortcut intent.

For every setting and threshold detail, see the [Settings reference](../reference/settings.md). For internals, see [Architecture](../reference/architecture.md).
