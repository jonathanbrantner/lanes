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
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run on the Mac that built it.
codesign --force --sign - "$APP"
echo "Built $APP"
