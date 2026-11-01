#!/bin/bash
# shellcheck disable=SC2034,SC2329,SC2015 # stubs and settings for the extracted greeter(); ok/fail lines
#
# The greeter draws over the boot logo in place (console-logo.sh lays that
# out at the greeter's rows and columns). It must not clear the whole screen
# first, which blanked the logo for a frame between the boot and the greeter:
# it clears the rows above the logo, erases and prints each logo row in one
# write, and clears the rows below. The configurator cannot be sourced, so
# this runs its greeter() alone, with stubs for what it calls.
#
# The color shift over the logo goes through ttfx_frames, which drops ttfx's
# first write, its canvas in spaces over the logo, and passes the frames on.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

awk '/^greeter\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$CONFIGURATOR" >"$work/greeter.sh"
grep -q '^greeter() {' "$work/greeter.sh" || { echo "FAIL: no greeter() in the configurator"; exit 1; }
awk '/^ttfx_frames\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$CONFIGURATOR" >"$work/frames.sh"
grep -q '^ttfx_frames() {' "$work/frames.sh" || { echo "FAIL: no ttfx_frames() in the configurator"; exit 1; }

printf '%s\n' '▄▄▄▄' '█  █' '▀▀▀▀' >"$work/logo.txt"
out=$(
  LOGO_PATH="$work/logo.txt"
  measure_terminal() { TERM_WIDTH=160; PADDING_LEFT_SPACES=$(printf '%*s' 78 ''); }
  stty() { return 1; }
  ttfx() { :; }
  systemctl() { :; }
  LINES=50
  # shellcheck source=/dev/null
  source "$work/greeter.sh"
  greeter </dev/null 2>/dev/null | cat -v
)
# Until the Return: the reset after it may clear the screen.
first=${out%%Beautiful*}

# 3 logo rows in a 7-row frame on 50 rows: the logo on row (50-7)/2+1 = 22.
if [[ $first == *'^[[H^[[2J'* ]]; then fail "the greeter clears the whole screen before drawing"; else ok "no full clear before the greeter draws"; fi
[[ $first == *'^[[21;160H^[[1J'* ]] && ok "the rows above the logo cleared" || fail "rows above the logo not cleared: $first"
[[ $first == *'^[[22;1H^[[2K'* ]] && ok "each logo row erased and printed in one write" || fail "logo rows: $first"
n=$(grep -o '\^\[\[2K' <<<"$first" | wc -l)
[[ $n == 3 ]] && ok "three logo rows, three erasures" || fail "$n erasures for three logo rows"
[[ $first == *'^[[0m'$'\n''^[[J'* ]] && ok "the rows below the logo cleared" || fail "rows below the logo not cleared: $first"

# ttfx's own opening: hide the cursor, restore and save it, go up to the
# canvas, the canvas in spaces; then frames, each from the saved cursor.
canvas=$'\e[?25l\e8\e7\e[3A    \n    \n    \n'
frame=$'\e8\e7\e[3A\e[38;5;35m\xe2\x96\x84\e[0m'
frames=$(
  # shellcheck source=/dev/null
  source "$work/frames.sh"
  printf '%s%s%s' "$canvas" "$frame" "$frame" | ttfx_frames | cat -v
)
expected=$(printf '%s%s' "$frame" "$frame" | cat -v)
[[ $frames == "$expected" ]] && ok "ttfx's frames pass, its canvas doesn't" || fail "ttfx_frames passed: $frames"
none=$(
  # shellcheck source=/dev/null
  source "$work/frames.sh"
  printf '%s' "$canvas" | ttfx_frames | cat -v
)
[[ -z $none ]] && ok "nothing passes when no frame comes" || fail "with no frame, ttfx_frames passed: $none"

exit "$((failures > 0))"
