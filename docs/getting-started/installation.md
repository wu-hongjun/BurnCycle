# Installation

## Prerequisites

- **macOS 14+** on Apple Silicon (M1/M2/M3/M4)
- A **MacBook with an internal battery** — BurnCycle refuses to start on a desktop Mac
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

`build.sh` compiles the Swift Package Manager target in release mode, verifies the bundled `xmrig` arm64 binary against `BurnCycle/Resources/xmrig.sha256`, compiles the Liquid Glass app icon asset catalog, code-signs **inside-out** (xmrig first, then the app — the post-sign xmrig hash is sealed into the app signature), and produces `BurnCycle.app` at the repo root with this layout:

```
BurnCycle.app/Contents/
├── Info.plist                 # version injected from `git describe`
├── PkgInfo
├── MacOS/BurnCycle            # stripped release binary
└── Resources/
    ├── xmrig                  # signed bundled miner
    ├── xmrig.sha256           # post-sign hash, verified at exec time
    ├── AppIcon.icns           # compiled asset catalog
    └── Assets.car
```

### Signing

Without environment variables, `build.sh` applies an **ad-hoc signature**. The resulting app launches on the Mac that built it but Gatekeeper will warn on any other Mac. To produce a distributable build, export a Developer ID identity and (optionally) a stored notarytool keychain profile, then re-run:

```bash
# Sign with your Developer ID (hardened runtime + entitlements)
BURNCYCLE_SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./build.sh

# Sign AND notarize+staple
BURNCYCLE_SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
BURNCYCLE_NOTARY_PROFILE="BurnCycleNotary" ./build.sh
```

The App Sandbox is intentionally **off** — BurnCycle spawns `shortcuts` and `xmrig` subprocesses and reads private IOKit/IOReport symbols — but the hardened runtime is enabled via `BurnCycle/BurnCycle/BurnCycle.entitlements`. See the comments in `build.sh` for the one-time `notarytool store-credentials` setup.

## Installing

```bash
cp -r BurnCycle.app /Applications/
open /Applications/BurnCycle.app
```

!!! warning "Gatekeeper on downloaded builds"
    If you downloaded `BurnCycle.zip` (instead of building it yourself), macOS attaches `com.apple.quarantine` and Gatekeeper will block an ad-hoc-signed bundle with *"BurnCycle is damaged and can't be opened."* Clear the flag recursively (this also unquarantines the bundled `xmrig`):

    ```bash
    xattr -dr com.apple.quarantine /Applications/BurnCycle.app
    ```

## First Launch

1. Click **Settings**
2. Verify shortcut names match yours (default: "Start Charging" / "Stop Charging")
3. Use the **Test** buttons to confirm your outlet toggles
4. Adjust thresholds if desired (default: charge to 90%, drain to 5%; a ≥5% gap is enforced)
5. Pick a load method (default: **Stress Test**, offline). Mining is opt-in via the *Method* picker.
6. Click **Start** (or press **⌘↩**) — BurnCycle runs a preflight outlet test and begins cycling

See [Quick Start](quickstart.md) for the first-cycle walkthrough, or the [Settings reference](../reference/settings.md) for every option.
