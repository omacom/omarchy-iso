#!/bin/bash
# shellcheck disable=SC2034,SC2329,SC2015 # stubs and settings for the extracted functions; ok/fail lines
#
# The configurator waits for the live VT to settle at the width its greeter
# is drawn for (wait_for_stable_terminal: the same width a few samples
# running). Where the boot logo is laid out for the framebuffer the console
# has now, at a width the logo fits or narrower on a console that is that
# framebuffer's size (omarchy_console_fits_fb), the console has settled
# already (console_settled) and the greeter comes at once; anywhere else, a
# different framebuffer, no record, a narrower console not on its
# framebuffer yet, the samples run as before. The configurator cannot be sourced: this runs the two functions
# alone, with stty and sleep standing in.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

for f in console_settled wait_for_stable_terminal; do
  awk -v f="$f" '$0 ~ "^" f "\\(\\) \\{" { on = 1 } on { print } on && /^\}/ { exit }' "$CONFIGURATOR" >>"$work/functions.sh"
  grep -q "^$f() {" "$work/functions.sh" || { echo "FAIL: no $f() in the configurator"; exit 1; }
done

mkdir -p "$work/run" "$work/fb"
# The functions read the terminal's size from /dev/tty: script(1) gives the
# run one (a test runner may have none). stty stands in and counts.
cat >"$work/run.sh" <<EOS
LOGO_WIDTH=81 CONSOLE_LOGO_PATH="$work/none.txt" OMARCHY_RUN_DIR="$work/run" OMARCHY_FB="$work/fb"
stty() { echo x >>"$work/samples"; echo "50 \$WIDTH"; }
sleep() { :; }
[[ \${FITS:-} ]] && omarchy_console_fits_fb() { [[ \$FITS == yes ]]; }
source "$work/functions.sh"
wait_for_stable_terminal
EOS
# samples <record|-> <fb name> <width>: how many width samples the wait took.
samples() {
  if [[ $1 == - ]]; then rm -f "$work/run/console-logo"; else echo "$1" >"$work/run/console-logo"; fi
  echo "$2" >"$work/fb/name"
  : >"$work/samples"
  WIDTH=$3 FITS=${4:-} script -qec "bash $work/run.sh" /dev/null >/dev/null
  wc -l <"$work/samples"
}
check() { if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1: got '$2', expected '$3'"; fi; }

check "laid out for this framebuffer, wide enough: one look, no wait" "$(samples bochs-drmdrmfb bochs-drmdrmfb 120)" 1
check "laid out for another framebuffer: the samples run" "$(samples simpledrmdrmfb bochs-drmdrmfb 120)" 4
check "no boot logo laid out: the samples run" "$(samples - bochs-drmdrmfb 120)" 4
check "narrower than the logo: one look, then the samples run (the 5 s cap)" "$(samples bochs-drmdrmfb bochs-drmdrmfb 80)" 51
check "narrower than the logo, the framebuffer's own size (640x480): one look, no wait" "$(samples bochs-drmdrmfb bochs-drmdrmfb 80 yes)" 1
check "narrower than the logo, not the framebuffer's size yet: the samples run" "$(samples bochs-drmdrmfb bochs-drmdrmfb 80 no)" 51
check "narrower, its own size, but laid out for another framebuffer: the samples run (the 5 s cap)" "$(samples simpledrmdrmfb bochs-drmdrmfb 80 yes)" 50

exit "$((failures > 0))"
