#!/usr/bin/env bash
#
# Builds MonitorBar.app (Swift, no Xcode) into app/build/MonitorBar.app.
# Usage: ./app/build.sh [destination]
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$DIR/build/MonitorBar.app}"

command -v swiftc >/dev/null 2>&1 || {
  echo "error: swiftc not found. Install the Command Line Tools: xcode-select --install" >&2
  exit 1
}

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS"

swiftc "$DIR/main.swift" \
  -O \
  -target "$(uname -m)-apple-macos12.0" \
  -o "$DEST/Contents/MacOS/MonitorBar"

cp "$DIR/Info.plist" "$DEST/Contents/Info.plist"

# Ad-hoc signature: enough to run locally.
codesign --force --sign - "$DEST" >/dev/null 2>&1 || true

echo "$DEST"
