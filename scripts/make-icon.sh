#!/bin/bash
# Regenerates the app icon (Resources/AppIcon.icon + Resources/AppIcon.icns fallback) from
# Sources/WindowInvert/IconArt.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
swiftc -O scripts/make-icon/main.swift Sources/WindowInvert/IconArt.swift -o "$TMP/make-icon"
"$TMP/make-icon" "$TMP/AppIcon.iconset" "$TMP/AppIcon.appiconset" Resources/AppIcon.icon
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icon and Resources/AppIcon.icns"
