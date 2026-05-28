#!/bin/bash
set -e

cd "$(dirname "$0")/BurnCycle"

echo "Building BurnCycle..."
swift build -c release

APP_BUNDLE="../BurnCycle.app"
APP_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
ENTITLEMENTS="BurnCycle/BurnCycle.entitlements"

# Clean any stale bundle so removed/renamed files don't linger (MED-1).
rm -rf "$APP_BUNDLE"

mkdir -p "$APP_DIR"
mkdir -p "$RESOURCES_DIR"

cp .build/release/BurnCycle "$APP_DIR/BurnCycle"
cp BurnCycle/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Strip debug symbols from the distributed binary (LOW-4).
strip -rSTX "$APP_DIR/BurnCycle" 2>/dev/null || true

# Standard bundle metadata file (MED-3).
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Inject a version derived from git (LOW-1). Falls back to 1.0 outside a repo.
VERSION="$(git describe --tags --always 2>/dev/null || echo "1.0")"
# Strip a leading "v" (e.g. v1.0.0 -> 1.0.0) for the user-facing string.
SHORT_VERSION="${VERSION#v}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SHORT_VERSION" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

# Bundle xmrig binary, verifying its SHA-256 against the recorded hash (Sec H-1).
if [ -f "BurnCycle/Resources/xmrig" ]; then
    if [ -f "BurnCycle/Resources/xmrig.sha256" ]; then
        EXPECTED_HASH="$(awk '{print $1}' BurnCycle/Resources/xmrig.sha256)"
        ACTUAL_HASH="$(shasum -a 256 BurnCycle/Resources/xmrig | awk '{print $1}')"
        if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
            echo "ERROR: xmrig SHA-256 mismatch!" >&2
            echo "  expected: $EXPECTED_HASH" >&2
            echo "  actual:   $ACTUAL_HASH" >&2
            echo "  Refusing to bundle a binary that does not match the recorded hash." >&2
            exit 1
        fi
        echo "xmrig SHA-256 verified ($ACTUAL_HASH)"
    else
        echo "Warning: BurnCycle/Resources/xmrig.sha256 missing — skipping integrity check" >&2
    fi
    cp BurnCycle/Resources/xmrig "$RESOURCES_DIR/xmrig"
    chmod +x "$RESOURCES_DIR/xmrig"
fi

# Compile asset catalog (app icon). Errors are surfaced (MED-2): we do not
# discard stderr, and a hard actool failure stops the build via set -e.
if [ -d "BurnCycle/Assets.xcassets" ]; then
    echo "Compiling asset catalog..."
    actool BurnCycle/Assets.xcassets \
        --compile "$RESOURCES_DIR" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /tmp/bc_assets_info.plist
fi

# ---------------------------------------------------------------------------
# Code signing (HIGH-1 / Sec H-3).
#
# Sandbox decision: we deliberately do NOT enable the App Sandbox because the
# app spawns subprocesses (shortcuts, xmrig) and reads private IOKit/IOReport
# symbols, which a strict sandbox would block. We instead enable the hardened
# runtime (--options runtime) with the minimal entitlements in
# BurnCycle/BurnCycle.entitlements.
#
# If BURNCYCLE_SIGN_ID is set (a "Developer ID Application: ..." identity),
# we produce a properly signed, notarization-ready build. Otherwise we fall
# back to an ad-hoc signature so the app at least launches locally. We never
# hard-fail just because no Developer ID is available.
# ---------------------------------------------------------------------------
# We sign inside-out (Apple-recommended) rather than using --deep: sign the
# nested xmrig first, then sign the app itself. This settles xmrig's bytes
# before we record its hash and before the outer signature seals the bundle.
TIMESTAMP_FLAG=""
[ -n "$BURNCYCLE_SIGN_ID" ] && TIMESTAMP_FLAG="--timestamp"  # secure timestamp for notarization

# Sign the bundled xmrig binary first.
if [ -f "$RESOURCES_DIR/xmrig" ]; then
    if [ -n "$BURNCYCLE_SIGN_ID" ]; then
        codesign --force --options runtime $TIMESTAMP_FLAG --sign "$BURNCYCLE_SIGN_ID" "$RESOURCES_DIR/xmrig"
    else
        codesign --force --sign - "$RESOURCES_DIR/xmrig"
    fi

    # Record the POST-SIGN hash of the bundled xmrig so the running app can verify
    # the exact binary it will exec (Sec H-1, runtime verification in MiningManager).
    # Code-signing rewrites the Mach-O, so this MUST be computed after signing and
    # before the outer app signature seals it into CodeResources.
    shasum -a 256 "$RESOURCES_DIR/xmrig" | awk '{print $1"  xmrig"}' > "$RESOURCES_DIR/xmrig.sha256"
    echo "Recorded bundled xmrig hash: $(awk '{print $1}' "$RESOURCES_DIR/xmrig.sha256")"
fi

# Sign the app itself WITHOUT --deep (xmrig is already signed above). This seals
# Resources/ — including xmrig and xmrig.sha256 — into the app's code signature,
# so tampering with either invalidates the signature.
if [ -n "$BURNCYCLE_SIGN_ID" ]; then
    echo "Signing with Developer ID: $BURNCYCLE_SIGN_ID"
    if [ -f "$ENTITLEMENTS" ]; then
        codesign --force --options runtime $TIMESTAMP_FLAG \
            --entitlements "$ENTITLEMENTS" \
            --sign "$BURNCYCLE_SIGN_ID" \
            "$APP_BUNDLE"
    else
        codesign --force --options runtime $TIMESTAMP_FLAG \
            --sign "$BURNCYCLE_SIGN_ID" \
            "$APP_BUNDLE"
    fi
else
    echo "Note: BURNCYCLE_SIGN_ID not set — applying an ad-hoc signature."
    echo "      The app will run locally but Gatekeeper will warn other users."
    echo "      See README 'Build & Install' for the quarantine workaround,"
    echo "      and set BURNCYCLE_SIGN_ID to a Developer ID for distribution."
    codesign --force --sign - "$APP_BUNDLE"
fi

# ---------------------------------------------------------------------------
# Notarization (HIGH-2) — optional, only runs when credentials are provided.
#
# Requires a Developer ID signature (BURNCYCLE_SIGN_ID above) plus an
# App Store Connect API key or app-specific password exposed via a stored
# notarytool keychain profile. Set BURNCYCLE_NOTARY_PROFILE to that profile
# name to enable. Example one-time setup:
#
#   xcrun notarytool store-credentials "BurnCycleNotary" \
#       --apple-id "you@example.com" \
#       --team-id "TEAMID1234" \
#       --password "app-specific-password"
#
# Then build with both env vars set:
#
#   BURNCYCLE_SIGN_ID="Developer ID Application: ..." \
#   BURNCYCLE_NOTARY_PROFILE="BurnCycleNotary" ./build.sh
# ---------------------------------------------------------------------------
if [ -n "$BURNCYCLE_SIGN_ID" ] && [ -n "$BURNCYCLE_NOTARY_PROFILE" ]; then
    echo "Notarizing..."
    NOTARY_ZIP="../BurnCycle-notarize.zip"
    ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --keychain-profile "$BURNCYCLE_NOTARY_PROFILE" \
        --wait
    xcrun stapler staple "$APP_BUNDLE"
    rm -f "$NOTARY_ZIP"
    echo "Notarized and stapled."
else
    echo "Note: skipping notarization (set BURNCYCLE_SIGN_ID + BURNCYCLE_NOTARY_PROFILE to enable)."
fi

echo "Built BurnCycle.app successfully!"
echo ""
echo "To run: open ../BurnCycle.app"
echo "To install: cp -r ../BurnCycle.app /Applications/"
