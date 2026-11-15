#!/bin/bash
# Builds Lanes.app and zips it for a GitHub Release. Does not publish anything.
# Usage: scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Public downloads are signed ad hoc, never with a personal certificate.
LANES_SIGN_IDENTITY=- scripts/make-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Lanes.app/Contents/Info.plist)"
ZIP="build/Lanes-${VERSION}.zip"

rm -f "$ZIP"
# ditto keeps the bundle structure and signature intact, unlike plain zip.
ditto -c -k --keepParent build/Lanes.app "$ZIP"
echo "Made $ZIP"
echo "To publish: gh release create v${VERSION} \"$ZIP\" --title \"Lanes ${VERSION}\" --notes-file CHANGELOG.md"
