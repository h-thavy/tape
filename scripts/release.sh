#!/usr/bin/env bash
# Builds a release for GitHub: dist/Tape.zip and dist/Tape.zip.sha256.
#
#   scripts/release.sh                 # build only
#   scripts/release.sh --publish       # also create the GitHub release vX.Y.Z (needs `gh`)
#
# Signed with the same self-made "Onword Release" certificate as Onword (no personal details), so every
# version has the same identity: macOS keeps the microphone, system audio and Accessibility permissions, and
# the Keychain items holding the API keys, across updates. Its keychain and password live outside the repo,
# in TAPE_SIGNING_DIR (default ../onword-backups/signing). Without it the build is signed ad-hoc, with a
# warning. Asset names never change, so the installer can always fetch .../releases/latest/download/Tape.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"

swift test
SIGNING_DIR="${TAPE_SIGNING_DIR:-../onword-backups/signing}"
RELEASE_IDENTITY="-"
if [[ -f "$SIGNING_DIR/onword-signing.keychain-db" && -f "$SIGNING_DIR/keychain-password.txt" ]]; then
  KEYCHAIN="$(cd "$SIGNING_DIR" && pwd)/onword-signing.keychain-db"
  security unlock-keychain -p "$(cat "$SIGNING_DIR/keychain-password.txt")" "$KEYCHAIN"
  # codesign only finds identities in keychains on the search list.
  if ! security list-keychains -d user | grep -q "$KEYCHAIN"; then
    security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KEYCHAIN"
  fi
  RELEASE_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk '/"Onword Release"/ {print $2; exit}')"
fi
if [[ -z "$RELEASE_IDENTITY" || "$RELEASE_IDENTITY" == "-" ]]; then
  RELEASE_IDENTITY="-"
  echo "warning: release certificate not found; signing ad-hoc (permissions reset after this update)" >&2
fi
OUT_DIR=dist/build SIGN_IDENTITY="$RELEASE_IDENTITY" scripts/build-app.sh
codesign --verify --deep --strict dist/build/Tape.app

rm -f dist/Tape.zip dist/Tape.zip.sha256
ditto -c -k --keepParent dist/build/Tape.app dist/Tape.zip
shasum -a 256 dist/Tape.zip | awk '{print $1}' > dist/Tape.zip.sha256
echo "Built dist/Tape.zip ($(du -h dist/Tape.zip | cut -f1)), sha256 $(cat dist/Tape.zip.sha256)"

if [[ "${1:-}" == "--publish" ]]; then
  if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" dist/Tape.zip dist/Tape.zip.sha256 --clobber
    echo "Updated release $TAG"
  else
    gh release create "$TAG" dist/Tape.zip dist/Tape.zip.sha256 --title "Tape $VERSION" --notes-file "${NOTES_FILE:-/dev/null}"
    echo "Published release $TAG"
  fi
fi
