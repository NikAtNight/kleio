#!/bin/bash
# Renders AppIcon.icns from generate-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 64 128 256 512 1024; do
    swift scripts/generate-icon.swift "$ICONSET/icon_${size}x${size}.png" "$size"
done
mv "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
cp "$ICONSET/icon_64x64.png" "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_32x32.png" "$ICONSET/icon_16x16@2x.png"
rm -f "$ICONSET/icon_64x64.png"

iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
