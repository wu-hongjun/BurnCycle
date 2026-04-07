# BurnCycle

A macOS app that automatically cycles your MacBook battery between configurable thresholds using a HomeKit smart outlet.

## What It Does

1. **Charges** your MacBook to an upper threshold (default 95%)
2. **Drains** to a lower threshold (default 10%) — optionally generating load to drain faster
3. **Repeats** the cycle automatically

## Why?

MacBook batteries degrade over time, especially when kept at 100% charge constantly. Cycling the battery between thresholds can help maintain battery health. BurnCycle automates this entirely.

## Features

- **Automatic battery cycling** via HomeKit smart outlet (Apple Shortcuts)
- **Two load methods** during discharge:
    - **Mine XMR** — earn Monero crypto (needs internet)
    - **Stress Test** — built-in CPU+GPU stress (works offline)
- **Smart load management** — auto-throttles when system is busy (>80% CPU/GPU)
- **Safety protection** — critical charge at 5%, safety margin stops load 3% above threshold
- **Real-time monitoring** — battery %, health, cycles, temperature, CPU/GPU usage, power draw
- **Detailed battery info** — matches coconutBattery: capacity, health (real vs Apple), serial, voltage
- **Compact UI** — three status lines, Settings/Info panels, one-click start

## Quick Start

```bash
./build.sh
cp -r BurnCycle.app /Applications/
open /Applications/BurnCycle.app
```

See [Installation](getting-started/installation.md) for full setup instructions.
