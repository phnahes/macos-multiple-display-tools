#!/usr/bin/env bash
#
# Removes the CLI, the app and the LaunchAgent installed by install.sh.
#
set -euo pipefail

BIN_DIR="${PREFIX:-$HOME/.local/bin}"
APPS_DIR="${APPS_DIR:-$HOME/Applications}"
LABEL="com.paulonahes.monitorbar"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
APP="$APPS_DIR/MonitorBar.app"

pkill -f "MonitorBar.app/Contents/MacOS/MonitorBar" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$AGENT"
rm -rf "$APP"

# Remove only symlinks that point back to this repository.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/monitor"
for name in monitor brightness contrast monitor-info brilho contraste; do
  link="$BIN_DIR/$name"
  [ -L "$link" ] || continue
  if [ "$link" -ef "$SELF" ]; then
    rm -f "$link"
    continue
  fi
  # Dangling symlink left behind if the repository moved.
  target="$(readlink "$link")"
  case "$target" in
    */bin/monitor) [ -e "$target" ] || rm -f "$link" ;;
  esac
done

echo "macos-multiple-display-tools uninstalled."
