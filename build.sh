#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-Release}"
OUTPUT_DIR="$ROOT/build"

echo "Building ShuttleTerm ($CONFIG)..."
xcodebuild \
    -project "$ROOT/ShuttleTerm.xcodeproj" \
    -scheme ShuttleTerm \
    -configuration "$CONFIG" \
    -derivedDataPath "$ROOT/.derivedData" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    build

APP_PATH="$ROOT/.derivedData/Build/Products/$CONFIG/ShuttleTerm.app"
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
cp -R "$APP_PATH" "$OUTPUT_DIR/"

echo ""
echo "Build complete: $OUTPUT_DIR/ShuttleTerm.app"
file "$OUTPUT_DIR/ShuttleTerm.app/Contents/MacOS/ShuttleTerm"
lipo -info "$OUTPUT_DIR/ShuttleTerm.app/Contents/MacOS/ShuttleTerm"