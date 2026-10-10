#!/bin/bash
# Builds WindowInvert.app into ./build.
#   SIGN_IDENTITY  codesigning identity (default: "WindowInvert Local Signing" if present, else ad-hoc "-")
#   ARCHS          "universal" (default) or "native"
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=WindowInvert
BUILD_DIR=build
APP="$BUILD_DIR/$APP_NAME.app"

if [[ "${ARCHS:-universal}" == "universal" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN_DIR=".build/apple/Products/Release"
else
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
strip -x "$APP/Contents/MacOS/$APP_NAME"  # local symbols only; ~35% smaller
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The layered .icon gives macOS 26+ proper dark/tinted variants (Assets.car); AppIcon.icns is the fallback.
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$BUILD_DIR/assets-info.plist" >/dev/null

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    if security find-identity -p codesigning 2>/dev/null | grep -q "WindowInvert Local Signing"; then
        SIGN_IDENTITY="WindowInvert Local Signing"
    else
        SIGN_IDENTITY="-"
    fi
fi
codesign --force --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP (signed with: $SIGN_IDENTITY)"
