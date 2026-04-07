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
- `build.sh` — Build script that creates `BurnCycle.app` bundle
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
- **IOReport for GPU** — matches mactop's accuracy, no sudo needed
- **Reactive battery monitoring** — Combine observers for immediate threshold response
- **2-second polling** — fast enough for responsive UI, light enough to not drain battery
- **Safety-first** — multiple layers prevent battery death

## Filing Issues

Report bugs at [github.com/wu-hongjun/BurnCycle/issues](https://github.com/wu-hongjun/BurnCycle/issues)
