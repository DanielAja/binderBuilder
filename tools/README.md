# tools/

## build_catalog.py — TCGdex -> catalog.sqlite

Builds the bundled card catalog (`binderBuilder/Resources/catalog.sqlite`)
from the free TCGdex API (https://tcgdex.dev, MIT). Schema v1 is a fixed
contract with the Swift `Catalog/` layer: `set_info`, `card`, `card_fts`
(FTS5), `price_snapshot` (TCGplayer USD + Cardmarket EUR), `card_hash`
(64-bit dHash + pHash at orientations 0/90/180/270, 8-byte BLOBs, computed
from low-res card images for the binder scanner), `catalog_meta`.

### Setup (one-time)

```sh
cd tools
python3 -m venv .venv
.venv/bin/pip install requests Pillow imagehash
```

### Usage

```sh
.venv/bin/python build_catalog.py                        # full build (~20k cards)
.venv/bin/python build_catalog.py --sets base1,base2     # subset build
.venv/bin/python build_catalog.py --refresh-prices-only  # force re-fetch card JSON
.venv/bin/python build_catalog.py --skip-images          # no image download/hashes
.venv/bin/python build_catalog.py --out /tmp/cat.sqlite  # custom output path
```

All raw API JSON and low-res images are mirrored under `tools/cache/`
(gitignored): `cache/sets/<id>.json`, `cache/cards/<id>.json`,
`cache/images/<id>.webp`. Re-runs skip anything already cached, so an
interrupted full pull simply resumes when re-run. Progress is printed
(`set X/Y`, `cards N/M`, `images N/M`) and mirrored to
`tools/cache/progress.txt`.

A cold full pull (~20k card JSONs + ~20k images, 12 workers) takes roughly
30–90 minutes; a fully cached rebuild takes ~2 minutes. Full builds
hard-fail (exit 1) if the final card count is below 15,000.

`image_base` stores the path after `https://assets.tcgdex.net/`
(e.g. `en/base/base1/4`); the app appends `/low.webp` or `/high.webp`.

## build_fixture_catalog.sh

Regenerates the test fixture
`binderBuilderTests/Fixtures/catalog-base1.sqlite` (Base Set only,
hashes included). Run after any schema change, then commit the fixture.

## verify.sh

Build / test / screenshot helper for the iOS app (see script header).
