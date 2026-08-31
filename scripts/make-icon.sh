#!/bin/bash
# Renders AppIcon.icns from generate-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET="$WORK_DIR/AppIcon.iconset"
MODULE_CACHE="$WORK_DIR/module-cache"
mkdir -p "$ICONSET"

for size in 16 32 64 128 256 512 1024; do
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift scripts/generate-icon.swift "$ICONSET/icon_${size}x${size}.png" "$size"
done
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift scripts/pack-icon.swift Resources/AppIcon.icns \
    "$ICONSET/icon_16x16.png" \
    "$ICONSET/icon_32x32.png" \
    "$ICONSET/icon_64x64.png" \
    "$ICONSET/icon_128x128.png" \
    "$ICONSET/icon_256x256.png" \
    "$ICONSET/icon_512x512.png" \
    "$ICONSET/icon_1024x1024.png"
echo "Wrote Resources/AppIcon.icns"
