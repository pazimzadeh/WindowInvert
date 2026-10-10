#!/bin/bash
# Regenerates Resources/AppIcon.icns from Sources/WindowInvert/IconArt.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swiftc -O scripts/make-icon/main.swift Sources/WindowInvert/IconArt.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$TMP/AppIcon.iconset/icon_512x512@2x.png" "$TMP/preview.png"
echo "Wrote Resources/AppIcon.icns (preview: $TMP/preview.png)"
