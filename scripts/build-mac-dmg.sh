#!/usr/bin/env bash
# Builds Inkwell.dmg for the Mac (Mac Catalyst), signed with a Developer ID certificate.
# Usage: scripts/build-mac-dmg.sh [signing identity]
# Default identity is the first "Developer ID Application" certificate in your keychain.
# Without notarization other Macs show a Gatekeeper warning on first launch; run scripts/notarize.sh to remove it.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[ -n "$IDENTITY" ] || { echo "No Developer ID Application certificate found." >&2; exit 1; }
echo "Signing with: $IDENTITY"

command -v xcodegen >/dev/null && xcodegen generate >/dev/null
rm -rf build-dmg dist/Inkwell.dmg
xcodebuild -project Inkwell.xcodeproj -scheme Inkwell -configuration Open \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath build-dmg \
  CODE_SIGNING_ALLOWED=NO build | tail -3

APP="build-dmg/Build/Products/Open-maccatalyst/Inkwell.app"
[ -d "$APP" ] || { echo "Build did not produce $APP" >&2; exit 1; }

codesign --force --deep --options runtime --timestamp \
  --entitlements Inkwell/InkwellOpen.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p dist
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Inkwell -srcfolder "$STAGE" -ov -format UDZO dist/Inkwell.dmg >/dev/null
codesign --force --sign "$IDENTITY" dist/Inkwell.dmg
rm -rf "$STAGE"
echo "Built dist/Inkwell.dmg ($(du -h dist/Inkwell.dmg | cut -f1))"
