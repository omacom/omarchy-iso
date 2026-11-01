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
#
# On the VGA text console with the boot's half-size logo up in its font, the
# greeter keeps that logo where the boot drew it (greeter_vga), drawn again
# over itself, the tagline and hint under it, and no color shift: played on
# the VT (vt-screen.py) over the boot's screen, no cell of the logo goes blank.

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
for f in greeter_vga_logo greeter_vga; do
  awk -v f="$f" '$0 ~ "^" f "\\(\\) \\{" { on = 1 } on { print } on && /^\}/ { exit }' "$CONFIGURATOR" >>"$work/vga.sh"
  grep -q "^$f() {" "$work/vga.sh" || { echo "FAIL: no $f() in the configurator"; exit 1; }
done
grep -q '^ttfx_frames() {' "$work/frames.sh" || { echo "FAIL: no ttfx_frames() in the configurator"; exit 1; }

printf '%s\n' '▄▄▄▄' '█  █' '▀▀▀▀' >"$work/logo.txt"
out=$(
  LOGO_PATH="$work/logo.txt" CONSOLE_LOGO_PATH="$work/none.txt" LOGO_WIDTH=4
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
[[ $first == *'^[[0m^[[25;1H^[[J'* ]] && ok "the rows below the logo cleared" || fail "rows below the logo not cleared: $first"

# A console narrower than the logo (the VGA text console's 80 columns): the
# copy fitted to 80 columns, and no color shift, which would wrap.
printf '%s\n' "$(printf '█%.0s' {1..81})" "$(printf '▀%.0s' {1..81})" >"$work/wide.txt"
printf '%s\n' "$(printf 'F%.0s' {1..80})" "$(printf 'G%.0s' {1..80})" >"$work/fitted.txt"
narrow=$(
  LOGO_PATH="$work/wide.txt" CONSOLE_LOGO_PATH="$work/fitted.txt" LOGO_WIDTH=81
  measure_terminal() { TERM_WIDTH=80; PADDING_LEFT_SPACES=""; }
  stty() { return 1; }
  ttfx() { echo "ttfx ran" >>"$work/ttfx.log"; }
  systemctl() { :; }
  LINES=25
  # shellcheck source=/dev/null
  source "$work/greeter.sh"
  greeter </dev/null 2>/dev/null | cat -v
)
[[ $narrow == *"$(printf 'F%.0s' {1..80})"* && $narrow != *'█'* && $narrow != *'M-bM-^VM-^H'* ]] && ok "80 columns: the fitted logo" || fail "80 columns: not the fitted logo"
[[ ! -e $work/ttfx.log ]] && ok "80 columns: no color shift" || fail "80 columns: ttfx ran"

# A console narrower than even the fitted logo (75 columns of a 600-pixel-wide
# framebuffer): the boot lays the fitted logo out from the first column, each
# line cut at the last (console-logo.sh), and the greeter leaves it so, the
# tagline and hint on their rows. Played on the VT with the tty's line feed
# as CR LF: after a line feed each line's wrapped end took a row of its own
# and the tagline went over the logo.
digits=$(printf '0123456789%.0s' {1..8})
printf '%s\n' "$digits" "$digits" >"$work/fitted75.txt"
boot75=$(
  # shellcheck source=/dev/null
  source "$ROOT/configs/airootfs/usr/share/omarchy-iso/console-logo.sh"
  omarchy_console_layout 10 1 25 75 80 "$work/fitted75.txt"
)
python3 "$ROOT/test/unit/vt-screen.py" 25 75 <<<"$boot75" | head -n 25 >"$work/boot75.txt"
out75=$(
  LOGO_PATH="$work/wide.txt" CONSOLE_LOGO_PATH="$work/fitted75.txt" LOGO_WIDTH=81
  measure_terminal() { TERM_WIDTH=75; PADDING_LEFT_SPACES=""; }
  stty() { return 1; }
  ttfx() { :; }
  systemctl() { :; }
  LINES=25
  # shellcheck source=/dev/null
  source "$work/greeter.sh"
  greeter </dev/null 2>/dev/null
)
# Up to the hint, which ends the drawing.
out75=${out75%"${out75##*Start Install}"}
screen75=$(sed 's/$/\r/' <<<"$out75" | python3 "$ROOT/test/unit/vt-screen.py" 25 75 "$work/boot75.txt" | head -n 25)
expected75=$(for ((r = 1; r <= 25; r++)); do
  case $r in
    10 | 11) echo "${digits:0:75}" ;;
    13) printf '%19s%s\n' '' "Beautiful, Fun & Agentic Linux by DHH" ;;
    15) printf '%23s%s\n' '' "Press Return to Start Install" ;;
    *) echo ;;
  esac
done)
boot_expected75=$(for ((r = 1; r <= 25; r++)); do if ((r == 10 || r == 11)); then echo "${digits:0:75}"; else echo; fi; done)
[[ $(cat "$work/boot75.txt") == "$boot_expected75" ]] && ok "75 columns: the boot's logo cut at the last column" || fail "75 columns: the boot's screen was:"$'\n'"$(cat "$work/boot75.txt")"
[[ $screen75 == "$expected75" ]] && ok "75 columns: the greeter keeps the logo's rows, cut at the last column, and draws the tagline and hint under it" || fail "75 columns: the screen was:"$'\n'"$screen75"

# ttfx's own opening: hide the cursor, restore and save it, go up to the
# canvas, the canvas in spaces; then frames, each from the saved cursor.
canvas=$'\e[?25l\e8\e7\e[3A    \n    \n    \n'
frame=$'\e8\e7\e[3A\e[38;5;35m\xe2\x96\x84\e[0m'
# The VGA case: a 6-column, 2-row half-size logo; the boot lays it out on
# rows 11-12 at column 38 of 80x25 (console-logo.sh), the tagline goes to row
# 14 and the hint to row 16, each centred.
mkdir -p "$work/vga" "$work/run"
vga=$'\uE000\uE001\uE002\uE003\uE004\uE005'
# The boot leaves the logo it drew beside its record (console-logo.sh).
printf '%s\n' "$vga" "$vga" >"$work/run/vga.txt"; echo 6 >"$work/run/vga.cols"; : >"$work/run/console-logo-vga"
boot=$(for ((r = 1; r <= 25; r++)); do if ((r == 11 || r == 12)); then printf '%37s%s\n' '' "$vga"; else echo; fi; done)
printf '%s\n' "$boot" >"$work/boot.txt"
vga_out=$(
  LOGO_PATH="$work/logo.txt" CONSOLE_LOGO_PATH="$work/vga/fitted.txt" LOGO_WIDTH=81
  OMARCHY_RUN_DIR="$work/run" OMARCHY_FB="$work/no-fb"
  # tty1's stand-in: whatever tty(1) says for the greeter's stdin here.
  OMARCHY_GREETER_TTY=$(tty 2>/dev/null </dev/null)
  ttfx() { echo "ttfx ran" >>"$work/vga-ttfx.log"; }
  systemctl() { :; }
  # shellcheck source=/dev/null
  source "$ROOT/configs/airootfs/usr/share/omarchy-iso/console-logo.sh"
  # shellcheck source=/dev/null
  source "$work/greeter.sh"
  # shellcheck source=/dev/null
  source "$work/vga.sh"
  greeter </dev/null 2>/dev/null
)
# Until the Return: the reset after it clears the screen.
printf '%s' "${vga_out%%$'\033[0m\033[H\033[2J'*}" >"$work/vga-greeter"
screen=$(python3 "$ROOT/test/unit/vt-screen.py" 25 80 "$work/boot.txt" <"$work/vga-greeter")
expected=$(for ((r = 1; r <= 25; r++)); do
  case $r in
    11 | 12) printf '%37s%s\n' '' "$vga" ;;
    14) printf '%21s%s\n' '' "Beautiful, Fun & Agentic Linux by DHH" ;;
    16) printf '%25s%s\n' '' "Press Return to Start Install" ;;
    *) echo ;;
  esac
done; echo "flashed: none")
[[ $screen == "$expected" ]] && ok "VGA: the boot's logo kept in place, the tagline and hint under it, nothing of it blanked" || fail "VGA: the screen was:"$'\n'"$screen"
[[ ! -e $work/vga-ttfx.log ]] && ok "VGA: no color shift" || fail "VGA: ttfx ran"

# A GPU driver's framebuffer coming while the VGA greeter waits for the
# Return: the screen cleared, the console waited for, the installer's font,
# then the framebuffer's greeter. script(1) gives the wait a terminal to time
# out on; the framebuffer appears 0.7 s in.
cat >"$work/late.sh" <<EOS
OMARCHY_RUN_DIR="$work/run" OMARCHY_FB="$work/late-fb" CONSOLE_LOGO_PATH="$work/vga/fitted.txt"
source "$ROOT/configs/airootfs/usr/share/omarchy-iso/console-logo.sh"
source "$work/vga.sh"
systemctl() { :; }
wait_for_stable_terminal() { echo wait >>"$work/late.log"; }
i18n_console_font() { echo font >>"$work/late.log"; }
greeter() { echo "framebuffer greeter" >>"$work/late.log"; }
( sleep 0.7; mkdir -p "$work/late-fb" ) &
greeter_vga >"$work/late.out"
EOS
rm -f "$work/late.log"
# script(1) passes the end of its input on to the terminal, which the wait
# reads as no Return ever coming: its input stays open for two seconds.
sleep 2 | timeout 10 script -qec "bash $work/late.sh" /dev/null >/dev/null 2>&1 || true
check_late=$(tr '\n' ' ' <"$work/late.log" 2>/dev/null || true)
[[ $check_late == "wait font framebuffer greeter " ]] && ok "VGA, a framebuffer while it waits: the console waited for, the font, the framebuffer's greeter" || fail "VGA, a framebuffer while it waits: '$check_late'"
[[ $(cat -v "$work/late.out") == *'^[[0m^[[H^[[2J' ]] && ok "VGA, a framebuffer while it waits: the screen cleared first" || fail "VGA, a framebuffer while it waits: not cleared: $(cat -v "$work/late.out" | tail -c 80)"

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
