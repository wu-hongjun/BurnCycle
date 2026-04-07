# Settings Reference

## Battery Thresholds

| Setting | Default | Range | Description |
|---------|---------|-------|-------------|
| Charge to | 95% | 50–100% | Upper threshold — outlet turns off, draining begins |
| Drain to | 10% | 5–50% | Lower threshold — outlet turns on, charging begins |

## Load Generation

| Setting | Default | Options | Description |
|---------|---------|---------|-------------|
| Generate load | ON | Toggle | Whether to run load during drain phase |
| Method | Stress Test | Mine XMR / Stress Test | How to generate load |
| XMR Wallet | (built-in) | Text field | Custom Monero wallet address (Mine XMR only) |

### Mine XMR

Uses the bundled xmrig binary to mine Monero on the nanopool. Requires internet. Uses all CPU cores + GPU via OpenCL. Earns small amounts of XMR.

Default wallet is built-in. Leave the wallet field empty to use it, or paste your own.

### Stress Test

Built-in CPU + GPU stress using native Swift and Metal. No internet required. No external dependencies.

- **CPU**: One thread per logical core running intensive math
- **GPU**: Metal compute shader processing 2M floats

## Outlet Control

| Setting | Default | Description |
|---------|---------|-------------|
| Start Charging Shortcut | "Start Charging" | Apple Shortcut name that turns outlet ON |
| Stop Charging Shortcut | "Stop Charging" | Apple Shortcut name that turns outlet OFF |

Both have **Test** buttons to verify they work before starting the cycle.

## Smart Load Management

Load generation respects system state:

- **Throttled** if CPU or GPU usage >80% from other applications
- **Stopped** 3% above drain threshold (safety margin for shortcut execution)
- **Emergency charge** at 5% battery regardless of settings
- **Auto-resumes** when system load drops and battery is above safety margin
