# Settings Reference

## Battery Thresholds

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| Charge to | 90% | 50–100% | Upper threshold — outlet turns off, draining begins |
| Drain to | 5% | 5–50% | Lower threshold — outlet turns on, charging begins |

## Load Generation

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| Generate load | ON | Toggle | Whether to run load during drain phase |
| Method | Stress Test | Stress Test / Mine XMR | How to generate load |
| XMR Wallet | (built-in) | Text field | Custom Monero wallet address (Mine XMR only) |

### Stress Test

Built-in CPU + GPU stress using native Swift and Metal. No internet required. No external dependencies.

- **CPU**: One `Task.detached(priority: .high)` per logical core running tight trigonometric math loops
- **GPU**: Metal compute shader processing 2M floats with `sin/cos/tan/sqrt/fma` per element

This is the default load method since it works without any network.

### Mine XMR

Uses the bundled xmrig binary to mine Monero on nanopool. Requires internet. Uses all CPU cores + GPU via OpenCL. Earns small amounts of XMR.

!!! info "Wallet & Supporting Development"
    If you leave the wallet field empty, mining proceeds to the **developer's wallet**. This is how you can support BurnCycle's development — your machine mines XMR during drain cycles, contributing a small amount to the developer at no extra cost to you (the energy would be spent draining the battery anyway).

    To mine for yourself instead, paste your own Monero (XMR) wallet address in the wallet field.

## Outlet Control

| Setting | Default | Description |
|---------|---------|-------------|
| Start Charging Shortcut | "Start Charging" | Apple Shortcut name that turns outlet ON |
| Stop Charging Shortcut | "Stop Charging" | Apple Shortcut name that turns outlet OFF |

Both have **Test** buttons to verify they work before starting the cycle.

## Preflight Test

When you click **Start**, BurnCycle runs an automatic preflight outlet test:

1. Toggles outlet OFF — verifies AC actually disconnects within 8 seconds
2. Toggles outlet ON — verifies AC reconnects within 8 seconds
3. If either fails, cycling refuses to start with a specific error:
    - **"Still charging after Stop"** — multiple power sources (e.g. Thunderbolt dock) or shortcut broken
    - **"No power after Start"** — charger cable not in the controlled outlet, or shortcut broken

This catches misconfigurations before any cycling begins.

## Smart Load Management

Load generation respects system state:

- **Throttled** if CPU or GPU usage >80% from other applications
- **Stopped** 3% above drain threshold (safety margin for shortcut execution)
- **Emergency charge** at 3% battery regardless of settings
- **Auto-resumes** when system load drops and battery is above safety margin
- **Method switching** — changing Mine XMR ↔ Stress Test mid-drain stops the active load and starts the new method
