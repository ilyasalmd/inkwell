#!/usr/bin/env bash
# Writes dist/apps.json, an AltStore/SideStore source that points at the .ipa in your latest GitHub release.
# Usage: scripts/make-altstore-source.sh OWNER/REPO   (run after scripts/build-ipa.sh, upload apps.json with the release)
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${1:?usage: make-altstore-source.sh OWNER/REPO}"
IPA=dist/Inkwell.ipa
[ -f "$IPA" ] || { echo "Run scripts/build-ipa.sh first." >&2; exit 1; }
VERSION=$(plutil -extract CFBundleShortVersionString raw build-ipa/Build/Products/Open-iphoneos/Inkwell.app/Info.plist)
SIZE=$(stat -f%z "$IPA")
DATE=$(date -u +%Y-%m-%d)
REL="https://github.com/$REPO/releases/latest/download"
cat > dist/apps.json <<JSON
{
  "name": "Inkwell",
  "identifier": "com.ilyas.inkwell.source",
  "apps": [
    {
      "name": "Inkwell",
      "bundleIdentifier": "com.ilyas.inkwell",
      "developerName": "Ilyas",
      "subtitle": "Handwriting notes for Apple Pencil",
      "localizedDescription": "A free, open source handwriting notes app with folders, notebook covers, templates and weekly schedules.",
      "iconURL": "$REL/icon.png",
      "tintColor": "1F3A5F",
      "versions": [
        {
          "version": "$VERSION",
          "date": "$DATE",
          "size": $SIZE,
          "downloadURL": "$REL/Inkwell.ipa",
          "minOSVersion": "18.0"
        }
      ]
    }
  ],
  "news": []
}
JSON
python3 -m json.tool dist/apps.json >/dev/null && echo "Wrote dist/apps.json for $REPO (v$VERSION)"
