#!/usr/bin/env bash
# Builds build/Tape.app from the Swift package.
#
#   scripts/build-app.sh                         # signs with your first "Apple Development" identity
#   SIGN_IDENTITY=- scripts/build-app.sh         # ad-hoc (permissions reset on every rebuild)
#
# A real identity matters: macOS ties the microphone, system audio and Accessibility grants to the signature.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }')"
  SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
OUT_DIR="${OUT_DIR:-build}"
APP="$OUT_DIR/Tape.app"

swift build -c release --product Tape
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Tape" "$APP/Contents/MacOS/Tape"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift scripts/make-icon.swift
codesign --force --options runtime --sign "$SIGN_IDENTITY" --entitlements Resources/Tape.entitlements "$APP"
# Register the fresh bundle with LaunchServices (dev builds only; releases are registered by the installer).
if [[ "$OUT_DIR" == "build" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi

echo "Built $APP ($(du -sh "$APP" | cut -f1), signed with: $SIGN_IDENTITY)"
