#!/bin/bash
# Builds "Work Timer.app" into ./dist
#
#   ./build.sh              universal binary (arm64 + x86_64)
#   UNIVERSAL=0 ./build.sh  native arch only (faster)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Work Timer"
BIN_NAME="WorkTimer"
DIST="dist"
APP="$DIST/$APP_NAME.app"
UNIVERSAL="${UNIVERSAL:-1}"

if [[ "$UNIVERSAL" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
    echo "==> Building universal (arm64 + x86_64), release"
else
    ARCH_FLAGS=()
    echo "==> Building native arch, release"
fi

swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
BIN_PATH="$BIN_DIR/$BIN_NAME"

if [[ ! -f "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH" "$APP/Contents/MacOS/$BIN_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Rendering app icon"
swift Tools/make-icon.swift "$APP/Contents/Resources/AppIcon.icns" >/dev/null

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/$BIN_NAME")"
echo "==> Built $APP"
