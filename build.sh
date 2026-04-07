#!/bin/bash
set -e

cd "$(dirname "$0")/BurnCycle"

echo "Building BurnCycle..."
swift build -c release

APP_DIR="../BurnCycle.app/Contents/MacOS"
RESOURCES_DIR="../BurnCycle.app/Contents/Resources"

mkdir -p "$APP_DIR"
mkdir -p "$RESOURCES_DIR"

cp .build/release/BurnCycle "$APP_DIR/BurnCycle"
cp BurnCycle/Info.plist "../BurnCycle.app/Contents/Info.plist"

# Bundle xmrig binary
if [ -f "BurnCycle/Resources/xmrig" ]; then
    cp BurnCycle/Resources/xmrig "$RESOURCES_DIR/xmrig"
    chmod +x "$RESOURCES_DIR/xmrig"
fi

# Compile asset catalog (app icon)
if [ -d "BurnCycle/Assets.xcassets" ]; then
    echo "Compiling asset catalog..."
    actool BurnCycle/Assets.xcassets \
        --compile "$RESOURCES_DIR" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /tmp/bc_assets_info.plist \
        2>/dev/null || echo "Warning: actool failed, icon may not appear"
fi

echo "Built BurnCycle.app successfully!"
echo ""
echo "To run: open ../BurnCycle.app"
echo "To install: cp -r ../BurnCycle.app /Applications/"
