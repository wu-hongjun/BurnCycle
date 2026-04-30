# BurnCycle

A macOS app that automatically cycles your MacBook battery between configurable thresholds using a HomeKit smart outlet.

## What It Does

1. **Charges** your MacBook to an upper threshold (default 90%)
2. **Drains** to a lower threshold (default 5%) — optionally generating load to drain faster
3. **Repeats** the cycle automatically

## Why?

Lithium-ion batteries degrade naturally over time. The rate of degradation depends heavily on usage patterns — batteries kept at 100% charge constantly degrade faster than those that are regularly cycled.

BurnCycle automates the cycling process, letting you exercise your battery without thinking about it. This is useful if you:

- Want to understand your battery's true health through regular cycling
- Run your MacBook plugged in 24/7 and want to prevent charge stagnation
- Want to accelerate natural wear to get a clearer picture of your battery's condition

!!! note "Side Effect"
    Repeated deep cycling will naturally reduce your battery's maximum capacity over time. Apple considers batteries with less than 80% maximum capacity to be consumed. If your Mac is covered by AppleCare+ and your battery drops below 80% through normal use (including automated cycling), you may be eligible for a free battery replacement.

## Features

- **Automatic battery cycling** via HomeKit smart outlet (Apple Shortcuts)
- **Two load methods** during discharge:
    - **Stress Test** (default) — built-in CPU+GPU stress (works offline)
    - **Mine XMR** — earn Monero crypto (needs internet)
- **Preflight outlet test** — verifies shortcut actually toggles power before cycling begins
- **Smart load management** — auto-throttles when system is busy (>80% CPU/GPU)
- **Multi-layer safety** — critical charge at 3%, safety margin stops load 3% above threshold, reactive battery observer
- **Real-time monitoring** — battery %, health, cycles, temperature, CPU/GPU usage, power draw, charger wattage
- **Detailed battery info** — capacity, health (Real vs Apple-reported), serial, voltage, temperature
- **History tracking** — persistent log of cycle count, capacity, and health over time
- **Liquid Glass icon** — refined for macOS 26 aesthetic
- **Compact UI** — three status lines, Settings/Info/History panels, one-click start

!!! tip "Supporting Development"
    When using "Mine XMR" mode without a custom wallet, mining proceeds to the developer's wallet. This is a free way to support BurnCycle — the energy would be spent draining the battery anyway. To mine for yourself, just paste your own XMR wallet in Settings.

## Quick Start

```bash
./build.sh
cp -r BurnCycle.app /Applications/
open /Applications/BurnCycle.app
```

See [Installation](getting-started/installation.md) for full setup instructions.
