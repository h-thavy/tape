#!/usr/bin/env bash
# Native, offline smoke test. Does not launch Tape, read recordings, or use API keys.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --target TapeCore
BIN_DIR="$(swift build --show-bin-path)"
OUT="${1:-build/pdf-qa}"
mkdir -p "$OUT"
if [[ -f "$BIN_DIR/TapeCore.o" ]]; then
  MODULES="$BIN_DIR"
  OBJECTS=("$BIN_DIR/TapeCore.o")
else
  MODULES="$BIN_DIR/Modules"
  OBJECTS=("$BIN_DIR"/TapeCore.build/*.o)
fi
swiftc -parse-as-library -I "$MODULES" \
  scripts/recap-pdf-smoke.swift Sources/Tape/RecapPDFExporter.swift \
  "${OBJECTS[@]}" -o "$BIN_DIR/recap-pdf-smoke"
"$BIN_DIR/recap-pdf-smoke" scripts/fixtures/recap-pdf.md "$OUT"
