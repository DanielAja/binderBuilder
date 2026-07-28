# Binder Builder

A 3D Pokémon TCG binder simulator and full collection tracker for iOS. Flip
through a real page-curl binder rendered in RealityKit — holo cards catch the
light as you tilt your phone — while a full GRDB-backed catalog underneath
tracks what you own, what it's worth, and who you're trading it to.

## Features

- **3D page-flipping binder** — a real page-curl animation (custom Metal
  shaders), holo foil that reacts to device tilt, and a pull-to-inspect
  floating card with haptics.
- **Collection & wishlist tracking** — per-copy tracking with condition and
  grade, set-completion progress, groups, and a wishlist with target prices.
- **Live prices** — current market prices pulled from
  [TCGdex](https://tcgdex.dev) (TCGplayer USD / Cardmarket EUR), with
  optional eBay sold-listing lookups if you supply your own eBay API keys.
- **Fast camera scanner** — point your camera at a card for on-device
  perceptual-hash recognition, then add it straight to your collection or
  wishlist.
- **Trade tracking** — a "for trade" list, a trade log with a fairness
  meter, and target values for wishlist items, for tracking convention/
  meetup trades.
- **iCloud backup** — optional, opt-in backup of your collection to your own
  private iCloud database, plus manual JSON export/import.

## Screenshots

_TODO: add screenshots of the shelf, open binder, card detail, and fast
scanner._

## Requirements

- Xcode (current stable release)
- iOS 18.0+ deployment target (iOS 26.5 SDK used by the test target)
- The Metal toolchain, which Xcode does not always install by default:

  ```sh
  xcodebuild -downloadComponent MetalToolchain
  ```

  Without it, builds fail with `cannot execute tool 'metal' due to missing
  Metal Toolchain` (the app has two custom `.metal` shaders for the card
  holo effect and the page curl).

## Building & verifying

Use the helper script rather than invoking `xcodebuild` directly:

```sh
tools/verify.sh build                      # build for the simulator
tools/verify.sh test                       # run the test suite
tools/verify.sh screenshot /tmp/shot.png   # install, launch, and screenshot
```

All three target an iOS Simulator device named `Shots-iPhone16ProMax` by
default; override with the `SIM_NAME` environment variable.

## Architecture

The app is SwiftUI on top of a RealityKit 3D scene (`Scene3D/`): a
`SceneModel` builds the shelf/binder/desk environment and drives per-frame
card placement and page-turn systems, with custom Metal shaders for holo
card surfaces and the page-curl deformation. Below the 3D layer, `AppEnvironment`
is the composition root wiring together a GRDB (`Collection/UserDatabase.swift`)
on-device SQLite store for the user's collection, wishlist, groups, binders,
trades, and price alerts, plus a bundled read-only card catalog
(`binderBuilder/Resources/catalog.sqlite`) built from the free TCGdex API by
`tools/build_catalog.py`. `Catalog/`, `Collection/`, `Pricing/`, `Trade/`,
`Scanner/`, and `Sync/` provide the data and services layer; `UI/` is the
SwiftUI presentation layer.

See `tools/README.md` for details on rebuilding the catalog and the test
fixture.

## Disclaimer

Unofficial fan-made app. Pokémon and Pokémon character names are trademarks
of Nintendo, Creatures Inc., and GAME FREAK inc. This app is not affiliated
with, endorsed, sponsored, or approved by them. Card data and images from
[TCGdex](https://tcgdex.dev) (MIT).
