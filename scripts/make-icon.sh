#!/bin/bash
# Renders AppIcon.icns from the Kleio master PNG.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ICONSET="$WORK_DIR/AppIcon.iconset"
MODULE_CACHE="$WORK_DIR/module-cache"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift scripts/generate-icon.swift Resources/KleioIcon.png "$ICONSET/icon_${size}x${size}.png" "$size"
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" swift scripts/generate-icon.swift Resources/KleioIcon.png "$ICONSET/icon_${size}x${size}@2x.png" "$((size * 2))"
done
/usr/bin/iconutil -c icns -o Resources/AppIcon.icns "$ICONSET"
echo "Wrote Resources/AppIcon.icns"
