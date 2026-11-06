#!/usr/bin/env bash
#
# One-shot setup for macos-multiple-display-tools.
#
# Checks and installs, in order:
#   1. macOS / Apple Silicon sanity check
#   2. Command Line Tools (swiftc), if missing
#   3. Homebrew, if missing
#   4. m1ddc, if missing
#   5. install.sh (CLI symlinks, app build, LaunchAgent)
#
# Usage: ./setup.sh [-y|--yes] [--help]
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSUME_YES=0

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf 'setup: %s\n' "$*" >&2; exit 1; }

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ -t 0 ] || return 1
  printf '%s [y/N] ' "$1"
  read -r answer
  case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

usage() {
  cat <<'EOF'
setup.sh — prepare everything macos-multiple-display-tools needs and install it

Usage:
  ./setup.sh [-y|--yes]

Options:
  -y, --yes   do not ask before installing Homebrew / m1ddc
  -h, --help  show this help

Steps:
  1. check macOS and CPU architecture
  2. install Command Line Tools if swiftc is missing (opens the macOS dialog)
  3. install Homebrew if missing
  4. install m1ddc if missing
  5. run install.sh (CLI symlinks, MonitorBar.app, LaunchAgent)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

# --- 1. platform ------------------------------------------------------------
step "[1/5] Checking the platform"
[ "$(uname -s)" = "Darwin" ] || die "this project is macOS-only"
if [ "$(uname -m)" != "arm64" ]; then
  say "warning: m1ddc targets Apple Silicon; on Intel Macs the CLI needs a different DDC tool."
fi
say "macOS $(sw_vers -productVersion) on $(uname -m)"

# --- 2. Command Line Tools --------------------------------------------------
step "[2/5] Checking Command Line Tools"
if command -v swiftc >/dev/null 2>&1; then
  say "swiftc found"
else
  say "swiftc not found — the app needs the Command Line Tools."
  if confirm "Open the Command Line Tools installer now?"; then
    xcode-select --install 2>/dev/null || true
    say ""
    say "Finish the installation in the macOS dialog, then run ./setup.sh again."
    exit 0
  fi
  die "install the Command Line Tools first: xcode-select --install"
fi

# --- 3. Homebrew ------------------------------------------------------------
step "[3/5] Checking Homebrew"
if command -v brew >/dev/null 2>&1; then
  say "Homebrew found at $(command -v brew)"
else
  say "Homebrew not found."
  if confirm "Install Homebrew now?"; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [ -x "$candidate" ]; then eval "$("$candidate" shellenv)"; break; fi
    done
  fi
  command -v brew >/dev/null 2>&1 ||
    die "Homebrew is required. Install it from https://brew.sh and run ./setup.sh again."
fi

# --- 4. m1ddc ---------------------------------------------------------------
step "[4/5] Checking m1ddc"
if command -v m1ddc >/dev/null 2>&1; then
  say "m1ddc found at $(command -v m1ddc)"
else
  say "m1ddc not found."
  if confirm "Install m1ddc with Homebrew now?"; then
    brew install m1ddc
  fi
  command -v m1ddc >/dev/null 2>&1 ||
    die "m1ddc is required. Install it with: brew install m1ddc"
fi

# --- 5. install -------------------------------------------------------------
step "[5/5] Installing macos-multiple-display-tools"
"$DIR/install.sh"

say ""
say "All set."
