#!/bin/bash
# Builds Lanes.app (menu bar only, no Dock icon) into ./build/
# Usage: scripts/make-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Lanes"
EXECUTABLE="SystemMonitorApp"
BUNDLE_ID="app.lanes.menubar"   # placeholder, change if you own a domain to use
APP="build/${APP_NAME}.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/${EXECUTABLE}"

rm -rf "$APP" "build/${APP_NAME}.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/${EXECUTABLE}"

# App icon (shown in Finder and System Settings, not in the Dock: Lanes is menu bar only).
swift scripts/make-icon.swift "build/${APP_NAME}.iconset"
iconutil -c icns "build/${APP_NAME}.iconset" -o "$APP/Contents/Resources/${APP_NAME}.icns"
rm -rf "build/${APP_NAME}.iconset"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${EXECUTABLE}</string>
    <key>CFBundleIconFile</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.0.0</string>
    <key>CFBundleVersion</key><string>5</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key><string>Lanes reads the battery level of your connected Bluetooth keyboard and mouse. Nothing is sent anywhere.</string>
</dict>
</plist>
PLIST

# Signing: with an Apple Development certificate (free with any Apple ID, create it in Xcode under
# Settings > Accounts) macOS keeps the permissions you grant (Bluetooth, Input Monitoring) through every
# rebuild. Without one the app is signed ad hoc, which runs fine, but macOS forgets the permissions
# after each build. Set LANES_SIGN_IDENTITY to pick a specific certificate.
IDENTITY="${LANES_SIGN_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null | grep -m1 'Apple Development' | awk '{print $2}' || true)}"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with your Apple Development certificate."
else
    codesign --force --sign - "$APP"
    echo "No Apple Development certificate found: signed ad hoc (macOS forgets permissions after each build)."
fi
echo "Built $APP"
