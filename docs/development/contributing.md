# Contributing

## Building from Source

```bash
git clone https://github.com/wu-hongjun/BurnCycle.git
cd BurnCycle
./build.sh
```

`build.sh` runs `swift build -c release`, lays out `BurnCycle.app`, compiles
the asset catalog with `actool`, verifies the bundled `xmrig` SHA-256, signs
inside-out (xmrig first, then the app — never `--deep`), and optionally
notarizes.

Requires:

- **Xcode 15+** (for the Swift 6.0 toolchain — strict concurrency is on)
- **macOS 14+** on Apple Silicon

### Optional environment variables

- `BURNCYCLE_SIGN_ID` — a `Developer ID Application: ...` identity. If unset,
  `build.sh` falls back to an ad-hoc signature so the app still launches
  locally (Gatekeeper will warn other users).
- `BURNCYCLE_NOTARY_PROFILE` — `notarytool` keychain profile name. When set
  together with `BURNCYCLE_SIGN_ID`, `build.sh` submits the signed app and
  staples the ticket. See the header comment in `build.sh` for the one-time
  `notarytool store-credentials` setup.

## Project Layout

- `BurnCycle/` — Swift Package Manager project (`Package.swift`, swift-tools 6.0)
- `BurnCycle/BurnCycle/` — source files
- `BurnCycle/BurnCycle/Resources/xmrig` — bundled mining binary
- `BurnCycle/BurnCycle/Resources/xmrig.sha256` — recorded post-sign hash, sealed into the app signature and re-verified at runtime
- `BurnCycle/BurnCycle/BurnCycle.entitlements` — hardened-runtime entitlements (App Sandbox intentionally off; see `build.sh` header)
- `BurnCycle/BurnCycle/Assets.xcassets/` — Liquid Glass app icon
- `build.sh` — assembles, signs, and (optionally) notarizes `BurnCycle.app`
- `docs/` — MkDocs documentation
- `mkdocs.yml` — MkDocs configuration

## Development Workflow

1. Make changes to source files in `BurnCycle/BurnCycle/`
2. Build: `./build.sh`
3. Test: `open BurnCycle.app`
4. Install: `cp -r BurnCycle.app /Applications/`

There is currently no test target and no separate lint step — `swift build`
under Swift 6 strict concurrency is the de facto gate. Builds should be clean
(zero warnings) before opening a PR.

## Swift 6 Concurrency

The package opts into the Swift 6 language mode (`swift-tools-version: 6.0`),
so the compiler enforces strict data-isolation. A few rules worth knowing:

- Most stateful services (`CycleEngine`, `BatteryMonitor`, `SystemMonitor`,
  `ChargingController`, `HistoryRecorder`, `StressManager`, `MiningManager`)
  are `@MainActor`. Cross-actor work hops back to the main actor explicitly.
- For properties that are written only on the main actor but touched from
  `deinit` (which Swift 6 treats as `nonisolated`), we use
  `nonisolated(unsafe)`. Examples live in `Services/CycleEngine.swift` and
  `Services/SystemMonitor.swift` — `Timer`, `Task`, `AnyCancellable`, and
  NSWorkspace observer tokens are all stored this way so `deinit` can
  invalidate timers, cancel tasks, and remove observers without compiler
  complaints. Keep the contract: write only on the main actor, read only in
  `deinit`.
- Long-running subprocess work (xmrig, `shortcuts`) runs in detached tasks;
  result handles are kept as properties so `stop()`/`deinit` can cancel them.

When you add a new long-lived resource that needs cleanup in `deinit`, follow
the same `nonisolated(unsafe)` pattern instead of marking the whole type
`nonisolated` or weakening actor isolation.

## Updating Bundled xmrig

`xmrig` is verified twice: `build.sh` checks the SHA-256 of
`BurnCycle/Resources/xmrig` against `BurnCycle/Resources/xmrig.sha256` before
bundling, and `MiningManager` re-verifies the in-bundle binary against a
post-sign hash at runtime (fails closed). When you replace the bundled
binary, both checks have to be re-pointed.

1. Drop the new `xmrig` into `BurnCycle/BurnCycle/Resources/xmrig` and make
   sure it is executable (`chmod +x`).
2. Regenerate the build-time source hash:

   ```bash
   shasum -a 256 BurnCycle/BurnCycle/Resources/xmrig \
       | awk '{print $1"  xmrig"}' \
       > BurnCycle/BurnCycle/Resources/xmrig.sha256
   ```

3. Run `./build.sh`. The script verifies the source hash, copies the binary
   into the bundle, code-signs it inside-out, then **overwrites**
   `Resources/xmrig.sha256` in the built `.app` with the post-sign hash that
   `MiningManager` checks at launch. (The source hash you committed only
   gates the bundling step; the post-sign hash is what ships.)
4. Commit the updated source `xmrig` and `xmrig.sha256` together.

Do not edit `xmrig.sha256` by hand and do not add `--deep` to the codesign
invocation — both will break the runtime check, which fails closed.

## Key Design Decisions

- **SwiftPM over Xcode project** — simpler, no xcodeproj to maintain
- **Bundled xmrig** — zero external dependencies for mining; integrity checked at build and at runtime
- **Inside-out code signing** — xmrig is signed first, its post-sign hash is recorded, then the app is signed without `--deep` so `Resources/` (including `xmrig.sha256`) is sealed into the outer signature
- **Hardened runtime, no App Sandbox** — the app spawns subprocesses (`shortcuts`, `xmrig`) and reads private IOKit/IOReport symbols, both of which a strict sandbox would block. Entitlements live in `BurnCycle.entitlements`.
- **Default to Stress Test** — works offline, no internet dependency
- **IOReport for GPU** — matches mactop's accuracy via private API, no sudo needed (linked via `.unsafeFlags(["-lIOReport"])` in `Package.swift`)
- **Reactive battery monitoring** — Combine observers for immediate threshold response, not polling delays
- **2-second / 60-second tiered polling** — fast values (battery %, charging state) every 2s; slow values (cycle count, capacities) every 60s; health detail is throttled to once per hour
- **Preflight verification** — never trust shortcut intent; always verify physical state via IOKit
- **Multi-layer safety** — multiple independent paths prevent battery death (reactive observer, safety margin, critical 3% rescue)
- **Liquid Glass icon** — generated programmatically via CoreGraphics in `/tmp/generate_icon.swift`

## Branches & Commits

- Branch from `main`. Use short, hyphenated, prefixed names that hint at the
  scope: `fix/...`, `feat/...`, `docs/...`, `chore/...`, `perf/...`,
  `design/...` (see `git log --oneline` for prior art).
- Commit subjects are lowercase, prefixed the same way (`fix:`, `feat:`,
  `docs:`, `chore:`, `perf:`, `design:`), present-tense, imperative, and
  specific. Keep them under ~72 characters; put rationale in the body.
- Group related changes per commit so `git log --oneline` stays readable.

## Filing Issues

Report bugs at [github.com/wu-hongjun/BurnCycle/issues](https://github.com/wu-hongjun/BurnCycle/issues)
