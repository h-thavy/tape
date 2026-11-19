#!/usr/bin/env bash
# Builds build/Tape.app from the Swift package.
#
#   scripts/build-app.sh                         # signs with your first "Apple Development" identity
#   SIGN_IDENTITY=- scripts/build-app.sh         # ad-hoc (permissions reset on every rebuild)
#
# A real identity matters: macOS ties the microphone, system audio and Accessibility grants, and access to the
# API keys in the Keychain, to the signature. So builds use the release certificate when it's here (the same
# one as the installed app: no Keychain prompts when switching between the two), else Apple Development.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGNING_DIR="${TAPE_SIGNING_DIR:-../onword-backups/signing}"
if [[ -z "${SIGN_IDENTITY:-}" && -f "$SIGNING_DIR/onword-signing.keychain-db" && -f "$SIGNING_DIR/keychain-password.txt" ]]; then
  KEYCHAIN="$(cd "$SIGNING_DIR" && pwd)/onword-signing.keychain-db"
  security unlock-keychain -p "$(cat "$SIGNING_DIR/keychain-password.txt")" "$KEYCHAIN"
  if ! security list-keychains -d user | grep -q "$KEYCHAIN"; then
    security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KEYCHAIN"
  fi
  SIGN_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/"Onword Release"/ {print $2; exit}')"
fi
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
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: swift scripts/make-icon.swift
cp -R "$BIN_DIR/Tape_TapeCore.bundle" "$APP/Contents/Resources/" # recap PDF stylesheet
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"            # Geist and Geist Mono (OFL)
codesign --force --options runtime --sign "$SIGN_IDENTITY" --entitlements Resources/Tape.entitlements "$APP"
# Register the fresh bundle with LaunchServices (dev builds only; releases are registered by the installer).
if [[ "$OUT_DIR" == "build" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi

echo "Built $APP ($(du -sh "$APP" | cut -f1), signed with: $SIGN_IDENTITY)"
