#!/usr/bin/env bash
#
# Instala o monitor-tools:
#   - symlinks da CLI em ~/.local/bin (monitor, brilho, contraste, monitor-info)
#   - MonitorBar.app em ~/Applications
#   - LaunchAgent para abrir o MonitorBar no login
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${PREFIX:-$HOME/.local/bin}"
APPS_DIR="${APPS_DIR:-$HOME/Applications}"
LABEL="com.paulonahes.monitorbar"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$APPS_DIR/MonitorBar.app"

say() { printf '%s\n' "$*"; }

# --- dependências -----------------------------------------------------------
if ! command -v m1ddc >/dev/null 2>&1; then
  say "aviso: m1ddc não encontrado. A CLI e o MonitorBar precisam dele:"
  say "       brew install m1ddc"
fi

# --- CLI --------------------------------------------------------------------
mkdir -p "$BIN_DIR"
for name in monitor brilho contraste monitor-info; do
  ln -sf "$DIR/bin/monitor" "$BIN_DIR/$name"
done
say "CLI instalada em $BIN_DIR"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "adicione ao PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# --- app --------------------------------------------------------------------
mkdir -p "$APPS_DIR"
"$DIR/app/build.sh" "$APP" >/dev/null
say "app instalado em $APP"

# --- LaunchAgent ------------------------------------------------------------
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/MonitorBar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/MonitorBar.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/MonitorBar.log</string>
</dict>
</plist>
PLIST

pkill -f "MonitorBar.app/Contents/MacOS/MonitorBar" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
say "MonitorBar carregado no login"

say ""
say "Pronto. Procure o ícone de sol na barra de menu."
say "Para desinstalar: $DIR/uninstall.sh"
