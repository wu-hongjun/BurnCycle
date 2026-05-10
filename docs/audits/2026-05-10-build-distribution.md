# Build & Distribution Audit

**Date:** 2026-05-10
**App:** BurnCycle
**Auditor:** Automated build/packaging review
**Scope:** build.sh, Package.swift, Info.plist, Assets.xcassets, bundle structure, .gitignore, README.md

---

## Summary

| Severity | Count |
|----------|-------|
| High     | 3     |
| Medium   | 5     |
| Low      | 4     |
| **Total**| **12**|

---

## Findings

### HIGH — No code signing in build.sh

**File:** `build.sh`

No `codesign` invocation anywhere in the build script. The resulting `BurnCycle.app` is distributed completely unsigned.

Consequences:
- macOS Gatekeeper blocks first launch with "unidentified developer" dialog.
- After download via Safari (or any browser), the quarantine extended attribute is attached. Without a valid signature, macOS 14+ shows **"BurnCycle is damaged and can't be opened"** — not just a warning, an outright block.
- The bundled `xmrig` binary is also unsigned. Spawning an unsigned child process from an unsigned parent raises additional Gatekeeper scrutiny.
- Zipping and unzipping a signed-but-not-hardened app strips `_CodeSignature`; since signing never happens here this is moot, but confirms the app cannot be verified at any point.

**Recommendation:** Add a `codesign` step at the end of `build.sh`:
```bash
codesign --deep --force --options runtime \
  --sign "Developer ID Application: <Your Name> (<Team ID>)" \
  ../BurnCycle.app
```
A free Apple Developer account with `codesign -s -` (ad-hoc) is sufficient for local use but will still trigger Gatekeeper for other users. A paid Developer ID is required for distribution.

---

### HIGH — No notarization and no hardened runtime

**File:** `build.sh`

Notarization is absent. Apple requires notarization for any software distributed outside the Mac App Store on macOS 10.15+. Without it:
- Users on macOS 14 cannot open the app at all after download without manually removing the quarantine flag.
- The `--options runtime` flag (hardened runtime) is a prerequisite for notarization and is not configured.

No `.entitlements` file exists in the repository. Hardened runtime with any dynamic behavior (e.g., spawning child processes like `xmrig`, JIT, or custom memory mappings) requires explicit entitlements. Spawning `xmrig` as a subprocess from a hardened-runtime binary without `com.apple.security.cs.allow-unsigned-executable-memory` or similar entitlements may be blocked by the OS.

**Recommendation:**
1. Create a `BurnCycle.entitlements` file with at minimum `com.apple.security.cs.disable-library-validation` (if needed for xmrig) or appropriate process-spawn entitlements.
2. Enable hardened runtime via `--options runtime` in `codesign`.
3. Submit to Apple notary service via `notarytool` after signing.

---

### HIGH — README omits quarantine removal step; users will hit "damaged" error

**File:** `README.md`, Build & Install section

The install instructions are:
```bash
./build.sh
cp -r BurnCycle.app /Applications/
open /Applications/BurnCycle.app
```

There is no mention of the quarantine extended attribute. Any user who downloads a pre-built `BurnCycle.zip` via Safari will have `com.apple.quarantine` applied. Without a valid Developer ID signature + notarization, macOS will display "BurnCycle is damaged and can't be opened. You should move it to the Trash." This is a hard block, not a dismissible warning.

**Recommendation:** Add a prominent note in README.md:
```bash
# If downloaded as a zip (not self-built):
xattr -d com.apple.quarantine /Applications/BurnCycle.app
```
Also note that the `xmrig` binary inside Resources will inherit the quarantine flag and must be cleared as well (the `--deep` flag on `xattr` handles this: `xattr -rd com.apple.quarantine /Applications/BurnCycle.app`).

---

### MEDIUM — build.sh does not clean stale bundle before rebuilding

**File:** `build.sh`

`mkdir -p` is used to create `BurnCycle.app/Contents/MacOS` and `Contents/Resources`, but the existing bundle is never removed before the build. Stale files from a previous build (old binary, old `Info.plist`, old `xmrig`, old `Assets.car`) persist if their source is removed or renamed. This can produce a silently broken or inconsistent app bundle — especially dangerous if `Info.plist` keys are removed or the xmrig binary is updated to a different name.

**Recommendation:** Add at the top of `build.sh` before `mkdir -p`:
```bash
rm -rf "../BurnCycle.app"
```

---

### MEDIUM — actool errors silently suppressed; broken icon goes undetected

**File:** `build.sh`, line 33

```bash
actool ... 2>/dev/null || echo "Warning: actool failed, icon may not appear"
```

Stderr is discarded entirely. If `actool` fails for any reason (missing image sizes, malformed JSON, wrong platform), the build continues and produces an app with no icon or a corrupt `Assets.car`. The `|| echo` message only fires on non-zero exit; `actool` frequently exits 0 while emitting errors on stderr that indicate partial failure.

**Recommendation:** Remove `2>/dev/null` so `actool` errors are visible. Treat `actool` failure as a build failure by removing `|| echo ...` and letting `set -e` stop the build.

---

### MEDIUM — `Contents/PkgInfo` is absent from the bundle

**File:** `build.sh` (bundle assembly)

A well-formed macOS application bundle should contain `Contents/PkgInfo` with the content `APPL????`. While macOS can often launch apps without it, its absence is non-standard, can confuse some tools (e.g., `lsregister`, older Finder versions), and is a red flag during any manual review or notarization pre-check.

**Recommendation:** Add to `build.sh`:
```bash
printf 'APPL????' > "../BurnCycle.app/Contents/PkgInfo"
```

---

### MEDIUM — Info.plist missing `NSHumanReadableCopyright` and `LSApplicationCategoryType`

**File:** `BurnCycle/BurnCycle/Info.plist`

The following keys are absent:
- `NSHumanReadableCopyright` — displayed in the "About" panel and required by some distribution channels.
- `LSApplicationCategoryType` — required for Mac App Store submission and recommended for Gatekeeper/Spotlight classification. For this app, `public.app-category.utilities` is appropriate.

Neither key causes a launch failure, but both are expected in a complete bundle and their absence may trigger warnings during notarization pre-flight checks.

---

### MEDIUM — `-lIOReport` uses `unsafeFlags`; breaks with non-Apple toolchains

**File:** `BurnCycle/Package.swift`, line 14

```swift
.unsafeFlags(["-lIOReport"])
```

`unsafeFlags` causes the Swift Package Manager to mark the package as unsafe and disables the ability to use this package as a dependency. More critically, `IOReport` is a private Apple framework — it is not available on non-Apple-Silicon hardware nor with third-party toolchains. The flag will produce a linker error on Intel Macs. Since the README correctly states Apple Silicon only, this is contained — but the dependency on a private, undocumented framework should be noted explicitly in README and comments, and `unsafeFlags` should carry a code comment explaining why it is necessary.

---

### LOW — `CFBundleVersion` not bumped per release

**File:** `BurnCycle/BurnCycle/Info.plist`

Both `CFBundleVersion` and `CFBundleShortVersionString` are hardcoded to `1.0`. Neither is incremented by `build.sh`. macOS uses `CFBundleVersion` for bundle identity in caches and update detection. Distributing multiple distinct builds all labeled `1.0` can cause macOS to serve a cached version rather than the new one.

**Recommendation:** Inject the version at build time from a `VERSION` file or git tag:
```bash
VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "1.0")
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "../BurnCycle.app/Contents/Info.plist"
```

---

### LOW — Asset catalog uses same PNG for @1x and @2x at 32px and 256px slots

**File:** `BurnCycle/BurnCycle/Assets.xcassets/AppIcon.appiconset/Contents.json`

`icon_32.png` is mapped to both `32x32 @1x` and `16x16 @2x`. `icon_256.png` is mapped to both `256x256 @1x` and `128x128 @2x`. This means the @2x slots receive a downscaled render rather than a purpose-made @2x asset, which can produce slightly softer icons on Retina displays at those sizes. All required slots are present so `actool` will not error, but icon fidelity is marginally reduced.

---

### LOW — `BurnCycle.app` checked into the repository (now gitignored, verify enforcement)

**File:** `.gitignore`

`BurnCycle.app/` is listed in `.gitignore`, which is correct. However the directory physically exists at the repo root. If it was committed before the gitignore rule was added, it may still be tracked by git. Run `git ls-files BurnCycle.app` to confirm it is not tracked. Tracked build artifacts inflate clone size and create noisy diffs.

---

### LOW — dSYM / debug symbol strip not addressed

**File:** `build.sh`

`swift build -c release` strips some debug info by default, but does not explicitly pass `-Xswiftc -whole-module-optimization` or confirm that dSYM bundles are absent from the distributed artifact. For a distribution build, explicitly confirm symbols are stripped:
```bash
strip -rSTX "../BurnCycle.app/Contents/MacOS/BurnCycle"
```
This is low severity since release mode provides reasonable defaults, but it is worth making the intent explicit.

---

## Positive Observations

- `LSMinimumSystemVersion 14.0` in `Info.plist` correctly matches `.macOS(.v14)` in `Package.swift`.
- `xmrig` is `chmod +x` in `build.sh` — executable bit is set correctly in the bundle.
- `CFBundleIdentifier` (`com.hongjunwu.BurnCycle`) follows reverse-DNS convention.
- Asset catalog contains all required macOS icon sizes (16, 32, 64, 128, 256, 512, 1024).
- `BurnCycle.zip` and `BurnCycle.app/` are both gitignored, keeping the repo free of large binaries (assuming not previously committed).
- README correctly states Apple Silicon / macOS 14+ requirement, matching the actual build constraints.
