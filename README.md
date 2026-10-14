# Inkwell

A free, open source handwriting notes app for iPad and Mac, built with SwiftUI and PencilKit.

Apple Pencil Pro squeeze and double-tap, pens and highlighters, Cornell/squared/lined/dotted templates, a notebook cover designer (including hand-drawn covers), Finder-style folders, weekly schedules that create notebooks for you, calendar suggestions, PDF import and linked PDF folders, and light/dark/colour themes.

## Download

Get the latest `Inkwell.dmg` (Mac) and `Inkwell.ipa` (iPad) from the Releases page, or from the download website in `docs/`.

- **Mac:** open the `.dmg`, drag Inkwell to Applications. If macOS can't verify the app, right-click it, choose Open, then Open again (only needed until a release is notarized).
- **iPad:** install [AltStore](https://altstore.io) or [SideStore](https://sidestore.io), then open `Inkwell.ipa` in it. Free Apple IDs expire apps after 7 days and AltStore renews them automatically.
- iCloud sync is not in the open download because it needs a paid developer team (see "Build from source").

## Build from source

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Inkwell.xcodeproj
```

The **Open** configuration (no iCloud, no paid account needed) is what the releases use. The **Debug** and **Release** configurations include the iCloud entitlement: change `DEVELOPMENT_TEAM` and the bundle identifier and container in `project.yml` and `Inkwell/Inkwell.entitlements` to your own to use them.

## Make a release

```bash
scripts/build-ipa.sh          # dist/Inkwell.ipa, unsigned, for AltStore/SideStore
scripts/build-mac-dmg.sh      # dist/Inkwell.dmg, signed with your Developer ID certificate
scripts/notarize.sh           # optional: Apple notarization, removes the Gatekeeper warning
scripts/make-altstore-source.sh OWNER/REPO   # dist/apps.json, lets AltStore track updates
```

Upload `Inkwell.ipa`, `Inkwell.dmg`, `apps.json` and `docs/icon.png` to a GitHub release. Publish `docs/` with GitHub Pages; the download buttons find the repository from the Pages address (or set `REPO` at the bottom of `docs/index.html` for a custom domain).

## Limits

- `.goodnotes` files can't be read. Export from Goodnotes as PDF and import that.
- Background schedule creation timing is decided by iOS; reminders fire at the time you set.

MIT licence, see `LICENSE`.
