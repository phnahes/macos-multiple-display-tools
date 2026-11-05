#!/usr/bin/env bash
#
# Compila o MonitorBar.app (Swift, sem Xcode) em app/build/MonitorBar.app.
# Uso: ./app/build.sh [destino]
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-$DIR/build/MonitorBar.app}"

command -v swiftc >/dev/null 2>&1 || {
  echo "erro: swiftc não encontrado. Instale as Command Line Tools: xcode-select --install" >&2
  exit 1
}

rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS"

swiftc "$DIR/main.swift" \
  -O \
  -target "$(uname -m)-apple-macos12.0" \
  -o "$DEST/Contents/MacOS/MonitorBar"

cp "$DIR/Info.plist" "$DEST/Contents/Info.plist"

# Assinatura ad-hoc: suficiente para rodar localmente.
codesign --force --sign - "$DEST" >/dev/null 2>&1 || true

echo "$DEST"
