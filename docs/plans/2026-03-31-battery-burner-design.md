# Battery Burner - Design Document

## Overview

A macOS menubar app that automatically cycles MacBook battery between configurable thresholds by controlling a HomeKit smart outlet (via Apple Shortcuts) and running Monero mining (via xmrig) to drain the battery during discharge phases.

## Architecture

```
┌─────────────────────────────────────┐
│         BatteryBurnerApp            │
│  (MenuBarExtra + Popover)           │
├─────────────────────────────────────┤
│                                     │
│  BatteryMonitor ──── IOKit/IOPSLib  │
│  (polls battery % every 30s)        │
│                                     │
│  ChargingController ── Shortcuts    │
│  (runs "Start Charging" /           │
│   "Stop Charging" shortcuts)        │
│                                     │
│  MiningManager ──── XMRig process   │
│  (spawns/kills xmrig subprocess)    │
│                                     │
│  CycleEngine (state machine)        │
│  ties the three above together:     │
│                                     │
│  CHARGING ──(≥upper)──► DRAINING    │
│  DRAINING ──(≤lower)──► CHARGING    │
│                                     │
└─────────────────────────────────────┘
```

## Components

### 1. BatteryMonitor

- Uses `IOPSCopyPowerSourcesInfo()` / `IOPSCopyPowerSourcesList()` from IOKit
- Reads: charge percentage, power source (AC/Battery), charging state
- Polls every 30 seconds via Timer
- Publishes `@Published var percentage: Int`, `isPluggedIn: Bool`, `isCharging: Bool`
- No special entitlements needed

### 2. ChargingController

- Toggles HomeKit smart outlet via Apple Shortcuts
- User creates two Shortcuts in Shortcuts.app beforehand:
  - "Start Charging" — turns on outlet
  - "Stop Charging" — turns off outlet
- Invokes via `Process()` running `/usr/bin/shortcuts run "<name>"`
- Shortcut names configurable in GUI
- 30s cooldown to prevent rapid toggling near thresholds

### 3. MiningManager

- Prerequisite: `brew install xmrig`
- Detects xmrig at `/opt/homebrew/bin/xmrig` or custom path
- Spawns xmrig as child Process with CLI args:
  - `--url pool.address:port`
  - `--user wallet-address`
  - `--threads N`
- Parses stdout for hashrate display
- Kills process cleanly on stop (`process.terminate()`)
- Termination handler ensures cleanup on app quit/crash

### 4. CycleEngine (State Machine)

- Two states: CHARGING, DRAINING
- On 30s poll:
  - CHARGING + battery >= upper threshold → stop charging, start mining → DRAINING
  - DRAINING + battery <= lower threshold → stop mining, start charging → CHARGING
- Manual override: pause cycle (stops mining, starts charging, holds)
- Startup: reads battery level to determine initial state (defaults to CHARGING if between thresholds)
- Tracks cycle count per session

## Persistence

All user settings stored via UserDefaults:
- Wallet address
- Pool URL
- Upper/lower thresholds
- Thread count
- Shortcut names
- XMRig path

## GUI (Menubar + Popover)

Menubar icon (battery icon) with popover on click:

**Status Section (top)**
- Battery percentage with progress bar
- State indicator: DRAINING / CHARGING / PAUSED (color-coded)
- Hashrate (when mining)
- Cycles completed

**Controls Section (middle)**
- Start/Stop toggle (master on/off)
- Pause button

**Settings Section (bottom, collapsible)**
- Upper threshold slider
- Lower threshold slider
- Wallet address text field
- Pool URL text field (with default)
- Thread count slider (1 to max cores)
- Start/Stop Charging shortcut name fields
- XMRig path with browse button

## Prerequisites

- macOS (Apple Silicon)
- `xmrig` installed via Homebrew
- Two Apple Shortcuts configured for HomeKit outlet control
- A Monero (XMR) wallet address

## Tech Stack

- Swift + SwiftUI
- IOKit framework (battery monitoring)
- Foundation Process (shortcuts + xmrig subprocess management)
- UserDefaults (persistence)
