#!/usr/bin/env bash
#
# Installs macos-multiple-display-tools:
#   - CLI symlinks in ~/.local/bin (monitor, brightness, contrast, monitor-info)
#   - MonitorBar.app in ~/Applications
#   - LaunchAgent to start MonitorBar at login
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${PREFIX:-$HOME/.local/bin}"
APPS_DIR="${APPS_DIR:-$HOME/Applications}"
LABEL="com.paulonahes.monitorbar"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$APPS_DIR/MonitorBar.app"

say() { printf '%s\n' "$*"; }

# --- dependencies -----------------------------------------------------------
if ! command -v m1ddc >/dev/null 2>&1; then
  say "warning: m1ddc not found. The CLI and MonitorBar need it:"
  say "         ./setup.sh installs it, or run: brew install m1ddc"
fi

# --- CLI --------------------------------------------------------------------
mkdir -p "$BIN_DIR"
for name in monitor brightness contrast monitor-info brilho contraste; do
  ln -sf "$DIR/bin/monitor" "$BIN_DIR/$name"
done
say "CLI installed in $BIN_DIR"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "add it to your PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

# --- app --------------------------------------------------------------------
mkdir -p "$APPS_DIR"
"$DIR/app/build.sh" "$APP" >/dev/null
say "app installed at $APP"

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
say "MonitorBar loaded at login"

say ""
say "Done. Look for the sun icon in the menu bar."
say "To uninstall: $DIR/uninstall.sh"
