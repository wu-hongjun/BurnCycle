#!/bin/bash
set -e

cd "$(dirname "$0")/BatteryBurner"

echo "Building BatteryBurner..."
swift build -c release

APP_DIR="../BatteryBurner.app/Contents/MacOS"
RESOURCES_DIR="../BatteryBurner.app/Contents/Resources"

mkdir -p "$APP_DIR"
mkdir -p "$RESOURCES_DIR"

cp .build/release/BatteryBurner "$APP_DIR/BatteryBurner"
cp BatteryBurner/Info.plist "../BatteryBurner.app/Contents/Info.plist"

# Compile asset catalog (app icon)
if [ -d "BatteryBurner/Assets.xcassets" ]; then
    echo "Compiling asset catalog..."
    actool BatteryBurner/Assets.xcassets \
        --compile "$RESOURCES_DIR" \
        --platform macosx \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist /tmp/bb_assets_info.plist \
        2>/dev/null || echo "Warning: actool failed, icon may not appear"
fi

echo "Built BatteryBurner.app successfully!"
echo ""
echo "To run: open ../BatteryBurner.app"
echo "To install: cp -r ../BatteryBurner.app /Applications/"
