# Binder Builder

A 3D Pokémon TCG binder simulator and full collection tracker for iOS. Flip
through a real page-curl binder rendered in RealityKit — holo cards catch the
light as you tilt your phone — while a full GRDB-backed catalog underneath
tracks what you own, what it's worth, and who you're trading it to.

## Features

- **3D page-flipping binder** — a real page-curl animation (custom Metal
  shaders), holo foil that reacts to device tilt, a three-ring mechanism that
  sizes itself to how fat the binder is, and a pull-to-inspect floating card
  with haptics.
- **Built for the iPhone Duo** — opened out, the binder fills the whole inner
  display with its spine parked on the crease; fold it into book pose and the
  camera swings overhead so each page sits square-on to its own panel, with
  the device's own hinge acting as the binder's spine. Tabletop pose puts the
  binder on the upright panel and the controls on the flat one, and the outer
  display shows one page at a time. See "Folding devices" below.
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

## Folding devices

The iPhone Duo adaptation lives in `binderBuilder/Fold/` and
`Scene3D/BinderStage.swift`:

- `FoldReader.swift` is the only file that touches the iOS 27.1 APIs —
  `.onHingeChange` for the live hinge angle and
  `GeometryProxy.reservedRegions(kind: .division)` for the crease. It
  publishes a plain `FoldState` value through `@Environment(\.fold)`.
- `FoldState.swift` derives the pose (flat / book / tabletop / compact) and
  the screen geometry from those two inputs. No device is hardcoded: an
  off-centre crease or a different panel split falls out of the reserved
  region the system reports.
- `BinderStage.swift` turns that into a camera stage and the binder's own
  dressing. Everything is driven by the hinge *angle*, not by a pose
  threshold, so the scene settles into place while you fold rather than
  snapping.

The Duo symbols sit behind the `DUO_SDK` compilation condition as well as
`@available(iOS 27.1, *)`. `DUO_SDK` is **off by default**: no compiler
conditional can see an SDK version, and Xcode 27.0 already ships Swift 6.4,
so a `#if compiler(>=6.4)` gate would compile the calls against an SDK that
does not have them. With the flag off the app builds on Xcode 27.0 and
reports every device as non-folding, which is the pre-existing behaviour.

Once Xcode 27.1 (iOS 27.1 SDK) is installed, turn the real APIs on by adding
`DUO_SDK` to the `binderBuilder` target's **Swift Compiler – Custom Flags →
Active Compilation Conditions**, or build with:

```sh
xcodebuild -scheme binderBuilder SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) DUO_SDK' build
```

To exercise the fold layouts on an ordinary simulator, pass `-fold` and
optionally `-hinge`:

```sh
tools/verify.sh screenshot /tmp/book.png -uiState binderOpen -fold book -hinge 115
tools/verify.sh screenshot /tmp/flat.png -uiState binderOpen -fold flat
tools/verify.sh screenshot /tmp/table.png -uiState binderOpen -fold tabletop
tools/verify.sh screenshot /tmp/cover.png -uiState binderOpen -fold compact
```

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
SwiftUI presentation layer, and `Fold/` publishes the device's fold so both
the 3D scene and the SwiftUI chrome can lay themselves out around the crease.

See `tools/README.md` for details on rebuilding the catalog and the test
fixture.

## Disclaimer

Unofficial fan-made app. Pokémon and Pokémon character names are trademarks
of Nintendo, Creatures Inc., and GAME FREAK inc. This app is not affiliated
with, endorsed, sponsored, or approved by them. Card data and images from
[TCGdex](https://tcgdex.dev) (MIT).
