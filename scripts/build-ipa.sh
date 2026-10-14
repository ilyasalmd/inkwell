#!/usr/bin/env bash
# Builds an unsigned Inkwell.ipa for sideloading (AltStore, SideStore, Sideloadly).
# The sideloading tool signs it with the user's own Apple ID, so nothing here needs a certificate.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null && xcodegen generate >/dev/null
rm -rf build-ipa dist/Inkwell.ipa
xcodebuild -project Inkwell.xcodeproj -scheme Inkwell -configuration Open \
  -destination 'generic/platform=iOS' -derivedDataPath build-ipa \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build | tail -3

APP="build-ipa/Build/Products/Open-iphoneos/Inkwell.app"
[ -d "$APP" ] || { echo "Build did not produce $APP" >&2; exit 1; }

mkdir -p dist
STAGE="$(mktemp -d)"
mkdir "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry "$OLDPWD/dist/Inkwell.ipa" Payload)
rm -rf "$STAGE"
echo "Built dist/Inkwell.ipa ($(du -h dist/Inkwell.ipa | cut -f1))"
