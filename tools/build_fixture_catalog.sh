#!/bin/sh
# Builds the test fixture catalog (Base Set only, including dhash/phash rows)
# used by the Swift Testing suite.
set -eu

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$TOOLS_DIR")"
OUT="$REPO_ROOT/binderBuilderTests/Fixtures/catalog-base1.sqlite"

mkdir -p "$(dirname "$OUT")"
"$TOOLS_DIR/.venv/bin/python" "$TOOLS_DIR/build_catalog.py" --sets base1 --out "$OUT"
echo "fixture written: $OUT"
