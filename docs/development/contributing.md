# Contributing

## Building from Source

```bash
git clone https://github.com/wu-hongjun/BurnCycle.git
cd BurnCycle
./build.sh
```

Requires:

- **Xcode 15+** (for Swift 6.0 toolchain)
- **macOS 14+** on Apple Silicon

## Project Layout

- `BurnCycle/` — Swift Package Manager project
- `BurnCycle/BurnCycle/` — Source files
- `BurnCycle/BurnCycle/Resources/xmrig` — Bundled mining binary
- `BurnCycle/BurnCycle/Assets.xcassets/` — Liquid Glass app icon
- `build.sh` — Build script that creates `BurnCycle.app` bundle and compiles asset catalog
- `docs/` — MkDocs documentation
- `mkdocs.yml` — MkDocs configuration

## Development Workflow

1. Make changes to source files in `BurnCycle/BurnCycle/`
2. Build: `./build.sh`
3. Test: `open BurnCycle.app`
4. Install: `cp -r BurnCycle.app /Applications/`

## Key Design Decisions

- **SwiftPM over Xcode project** — simpler, no xcodeproj to maintain
- **Bundled xmrig** — zero external dependencies for mining
- **Default to Stress Test** — works offline, no internet dependency
- **IOReport for GPU** — matches mactop's accuracy via private API, no sudo needed
- **Reactive battery monitoring** — Combine observers for immediate threshold response, not polling delays
- **2-second / 60-second tiered polling** — fast values (battery %, charging state) every 2s; slow values (cycle count, health, capacities) every 60s
- **Preflight verification** — never trust shortcut intent; always verify physical state via IOKit
- **Multi-layer safety** — multiple independent paths prevent battery death (reactive observer, safety margin, critical 3% rescue)
- **Liquid Glass icon** — generated programmatically via CoreGraphics in `/tmp/generate_icon.swift`

## Filing Issues

Report bugs at [github.com/wu-hongjun/BurnCycle/issues](https://github.com/wu-hongjun/BurnCycle/issues)
