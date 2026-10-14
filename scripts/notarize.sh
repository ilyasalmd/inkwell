#!/usr/bin/env bash
# Sends dist/Inkwell.dmg to Apple for notarization (an automated malware scan) and staples the ticket.
# One-time setup, using an app-specific password from appleid.apple.com:
#   xcrun notarytool store-credentials inkwell-notary --apple-id YOU@EXAMPLE.COM --team-id J7AX8JXB5B
set -euo pipefail
cd "$(dirname "$0")/.."
PROFILE="${1:-inkwell-notary}"
xcrun notarytool submit dist/Inkwell.dmg --keychain-profile "$PROFILE" --wait
xcrun stapler staple dist/Inkwell.dmg
spctl --assess --type open --context context:primary-signature -v dist/Inkwell.dmg
