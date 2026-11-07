#!/usr/bin/env bash
#
# CLI test suite. Uses fake m1ddc and ioreg binaries, so it needs no hardware.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/home"
install -m 755 "$ROOT/tests/fake-m1ddc" "$TMP/bin/m1ddc"
install -m 755 "$ROOT/tests/fake-ioreg" "$TMP/bin/ioreg"

export PATH="$TMP/bin:$PATH"
export FAKE_STATE="$TMP/state"
export HOME="$TMP/home"
export MONITOR_NAME="Test"
unset MONITOR_ID 2>/dev/null || true

MON="$ROOT/bin/monitor"
pass=0
fail=0

check() { # description expected actual
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n     expected [%s], got [%s]\n' "$1" "$2" "$3"
    fail=$((fail + 1))
  fi
}

check_contains() { # description needle haystack
  case "$3" in
    *"$2"*) printf 'ok   %s\n' "$1"; pass=$((pass + 1)) ;;
    *) printf 'FAIL %s\n     missing [%s] in [%s]\n' "$1" "$2" "$3"; fail=$((fail + 1)) ;;
  esac
}

# --- brightness -------------------------------------------------------------
check "default brightness" 50 "$("$MON" brightness)"
check "auto-detect without a name" 50 "$(MONITOR_NAME='' "$MON" brightness)"
check "set absolute" 70 "$("$MON" brightness 70)"
check "state persisted" 70 "$(cat "$TMP/state/luminance")"
check "increase by 5" 75 "$("$MON" brightness +5)"
check "decrease by 10" 65 "$("$MON" brightness -10)"
check "max" 100 "$("$MON" brightness max)"
check "min" 0 "$("$MON" brightness min)"
check "clamp low" 0 "$("$MON" brightness -500)"
check "clamp high" 100 "$("$MON" brightness +500)"
check "get keyword" 100 "$("$MON" brightness get)"

# --- contrast and volume ----------------------------------------------------
check "contrast default" 50 "$("$MON" contrast)"
check "contrast set" 80 "$("$MON" contrast 80)"
check "volume set" 40 "$("$MON" volume 40)"

# --- errors -----------------------------------------------------------------
"$MON" brightness abc >/dev/null 2>&1
check "invalid value exits 1" 1 "$?"

MONITOR_ID=1 "$MON" brightness >/dev/null 2>&1
check "built-in index exits 1" 1 "$?"

out="$(FAKE_LIST='[1] Unknown Display (0000)' "$MON" brightness 2>&1)"
check "no external exits 1" 1 "$?"
check_contains "no external message" "no external display answers DDC" "$out"

out="$("$MON" brightness 2>&1 >/dev/null)"
check "no error output on success" "" "$out"

# --- info -------------------------------------------------------------------
info="$("$MON" info)"
check_contains "info lists displays" "Test Monitor" "$info"
check_contains "info shows connection" "USB-C 2 (left, rear)" "$info"
check_contains "info shows link" "2.7 Gbps (HBR), 4 lanes" "$info"
check_contains "info shows brightness" "Brightness: 100" "$info"

# --- dispatch through symlinks ---------------------------------------------
ln -sf "$MON" "$TMP/bin/brightness"
ln -sf "$MON" "$TMP/bin/monitor-info"
check "brightness shortcut" 100 "$("$TMP/bin/brightness")"
check_contains "monitor-info shortcut" "Connection:" "$("$TMP/bin/monitor-info")"

# --- misc -------------------------------------------------------------------
check "version" "1.1.0" "$("$MON" --version)"
check_contains "help mentions angle" "monitor angle" "$("$MON" help)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
