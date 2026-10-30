#!/bin/bash
#
# The install dashboard draws its icon in half blocks, two pixels to a cell,
# each half in its own colour. The Linux VT reads the bright backgrounds
# (SGR 100-107) as the normal ones (40-47), so a cell that asks for one loses
# that half: the grey under a green tracing tip came out black. Every pair of
# halves the trace draws must show both colours on the VT.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
DASHBOARD="$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

source <(sed -n '/^icon_cell() {/,/^}/p' "$DASHBOARD")
declare -F icon_cell >/dev/null || fail "the dashboard defines icon_cell"
CSI=$'\033['
RESET=$'\033[0m'

# What a colour code shows on the VT: 100-107 read as 40-47, and 40 is the
# screen's own background.
vt_colour() {
  case $1 in
    32 | 42) echo green ;;
    90) echo grey ;;
    *) echo none ;;
  esac
}

# The two halves of a drawn cell as the VT shows them, upper then lower.
vt_halves() {
  local cell=$1 pattern=$'^\033\\[([0-9]+);([0-9]+)m(.+)$' fg bg
  if [[ $cell == "$RESET " ]]; then
    echo "none none"
    return
  fi
  [[ $cell =~ $pattern ]] || fail "icon_cell draws a cell the test can read" "$(printf '%q' "$cell")"
  fg=$(vt_colour "${BASH_REMATCH[1]}")
  bg=$(vt_colour "${BASH_REMATCH[2]}")
  case ${BASH_REMATCH[3]} in
    █) echo "$fg $fg" ;;
    ▀) echo "$fg $bg" ;;
    ▄) echo "$bg $fg" ;;
    *) fail "icon_cell draws a half block" "$(printf '%q' "$cell")" ;;
  esac
}

# One cell, one pixel over another. With step 1 drawn, a pixel at step 1 is
# traced (green), one at a later step is outline still to trace (grey).
ICON_WIDTH=1
declare -a ICON_TRACE ICON_FILL
for upper in none grey green; do
  for lower in none grey green; do
    ICON_TRACE=() ICON_FRAME=""
    case $upper in grey) ICON_TRACE[0]=2 ;; green) ICON_TRACE[0]=1 ;; esac
    case $lower in grey) ICON_TRACE[1]=3 ;; green) ICON_TRACE[1]=1 ;; esac
    icon_cell 0 1 0
    [[ $ICON_FRAME != *";10"[0-7]"m"* ]] ||
      fail "a $upper over $lower cell asks for no bright background" "$(printf '%q' "$ICON_FRAME")"
    [[ $(vt_halves "$ICON_FRAME") == "$upper $lower" ]] ||
      fail "a $upper over $lower cell shows both halves on the VT" "$(printf '%q' "$ICON_FRAME")"
  done
done
pass "every traced, outline and empty pair of halves keeps both colours on the VT"
