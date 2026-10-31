#!/bin/bash
# shellcheck disable=SC2015 # ok/fail lines
#
# The BIOS boot menu's install medium entry boots from omarchy-logo.cfg, which
# puts the boot logo up first (configs/syslinux/). Its kernel command line is
# the menu's other entry's, the speech one's, but for accessibility=on there
# and quiet, vga=0x0f04 (keep the mode, and the logo's font with it) and
# vt.global_cursor_default=0 (no cursor under it) here: a change to one that
# misses the other shows up here.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SYSLINUX="$ROOT/configs/syslinux"
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }

# label_lines FILE LABEL: the lines of LABEL's block in FILE.
label_lines() { awk -v label="$2" '/^LABEL /{on = ($2 == label)} on' "$1"; }
words() { tr ' ' '\n' | grep -v '^$' | sort; }

menu=$(label_lines "$SYSLINUX/archiso_sys-linux.cfg" arch64)
logo=$(label_lines "$SYSLINUX/omarchy-logo.cfg" arch64)
speech=$(label_lines "$SYSLINUX/archiso_sys-linux.cfg" arch64speech)

grep -qx 'CONFIG /boot/syslinux/omarchy-logo.cfg /boot/syslinux/' <<<"$menu" && ok "the menu entry boots from omarchy-logo.cfg" || fail "the menu entry: $menu"
for key in LINUX INITRD; do
  if [[ $(grep "^$key " <<<"$logo") == "$(grep "^$key " <<<"$speech")" ]]; then ok "$key as the speech entry's"; else fail "$key differs from the speech entry's"; fi
done
diff <(sed -n 's/^APPEND //p' <<<"$logo" | words | grep -vx -e 'vga=0x0f04' -e quiet -e 'vt.global_cursor_default=0') \
  <(sed -n 's/^APPEND //p' <<<"$speech" | words | grep -vx 'accessibility=on') >/dev/null &&
  ok "the kernel command line is the speech entry's, but for quiet, vga= and the cursor" ||
  fail "the kernel command lines differ beyond quiet, vga=, the cursor and accessibility="
grep -q '^APPEND .*\bvga=0x0f04\b' <<<"$logo" && ok "vga=0x0f04 keeps the mode and the logo's font" || fail "no vga=0x0f04"
for key in "FONT omarchy-logo.psf" "DISPLAY omarchy-logo.txt" "PROMPT 0" "TIMEOUT 0"; do
  grep -qx "$key" "$SYSLINUX/omarchy-logo.cfg" && ok "omarchy-logo.cfg: $key" || fail "omarchy-logo.cfg lacks $key"
done
for file in omarchy-logo.psf omarchy-logo.txt; do
  [[ -s $SYSLINUX/$file ]] && ok "$file is there" || fail "$file missing"
done

exit "$((failures > 0))"
