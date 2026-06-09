#!/bin/bash
# Build (and optionally test/screenshot) Binder Builder on the iPhone simulator.
# Usage:
#   tools/verify.sh build
#   tools/verify.sh test
#   tools/verify.sh screenshot /tmp/shot.png [extra launch args...]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$PROJECT_DIR/binderBuilder.xcodeproj"
SCHEME="binderBuilder"
SIM_NAME="${SIM_NAME:-Shots-iPhone16ProMax}"
DEST="platform=iOS Simulator,name=$SIM_NAME"
BUNDLE_ID="com.aja.binderBuilder"

case "${1:-build}" in
  build)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" build | tail -5
    ;;
  test)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" test | tail -30
    ;;
  screenshot)
    OUT="${2:?usage: verify.sh screenshot <out.png> [launch args...]}"
    shift 2
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" build -quiet
    APP_PATH=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
      -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/{d=$3}/ FULL_PRODUCT_NAME/{n=$3}END{print d"/"n}')
    xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
    xcrun simctl install "$SIM_NAME" "$APP_PATH"
    xcrun simctl terminate "$SIM_NAME" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$SIM_NAME" "$BUNDLE_ID" "$@"
    sleep "${SHOT_DELAY:-9}"
    xcrun simctl io "$SIM_NAME" screenshot "$OUT"
    echo "screenshot: $OUT"
    ;;
  *)
    echo "unknown command: $1" >&2; exit 1
    ;;
esac
