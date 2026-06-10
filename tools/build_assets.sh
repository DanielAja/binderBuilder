#!/bin/bash
# Regenerate all 3D assets (.usdz) and 2D resources (cardback.png, studio.exr)
# headlessly with Blender. Extra args are forwarded to gen_assets.py,
# e.g.:  tools/build_assets.sh --only Binder
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"

if [[ ! -x "$BLENDER" ]]; then
    echo "error: Blender not found at $BLENDER (set BLENDER=...)" >&2
    exit 1
fi

"$BLENDER" --background --python "$ROOT/tools/blender/gen_assets.py" -- \
    --out "$ROOT/binderBuilder/Assets3D" \
    --resources "$ROOT/binderBuilder/Resources" \
    "$@"
