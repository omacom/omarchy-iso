#!/bin/bash
#
# The boot logo is laid out where the installer's greeter will draw it
# (configs/airootfs/usr/share/omarchy-iso/console-logo.sh), so the greeter
# replaces it in place: the greeter's frame of logo, blank, tagline, blank and
# hint centred as a block, the logo centred at its own width, in the font the
# greeter will load. These cases run the layout against a fake console: the
# VT's size header, the framebuffer's sysfs directory, setfont, the logos.
#
# - The VGA text console (no framebuffer): the half-size logo in its own
#   font (vga-logo-font.py) at the greeter's place in half-size cells; without
#   that font the greeter's logo where it fits, the fitted copy where it does
#   not; no takeover glyph. The next layout on a framebuffer loads a whole
#   font back, and the console is cleared when the VGA console goes.
# - A UEFI framebuffer still behind the dummy console: an invisible full stop
#   first, then the layout for the size fbcon takes the console over at.
# - The font: 32 px from 1852x800 up, so 1920x1080 gets it and 1366x768,
#   1280x800 and 1600x900 keep 8x16; and the greeter's own font choice
#   (i18n_console_font) agrees for each.
# - omarchy-console-logo-redraw: only when a different framebuffer took over,
#   and never once the installer has tty1; with --wait, as soon as one does.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SHARE="$ROOT/configs/airootfs/usr/share/omarchy-iso"
REDRAW="$ROOT/configs/airootfs/usr/local/bin/omarchy-console-logo-redraw"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
ok() { echo "ok: $1"; }
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
check() { if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1: got '$2', expected '$3'"; fi; }
# expect <description> <string> <piece>...: the pieces occur in the string, in that order
expect() {
  local desc=$1 s=$2 piece
  shift 2
  for piece in "$@"; do
    [[ $s == *"$piece"* ]] || { fail "$desc: got $2"; return; }
    s=${s#*"$piece"}
  done
  ok "$desc"
}
lacks() { if [[ $2 == *"$3"* ]]; then fail "$1: got $2"; else ok "$1"; fi; }

# The logos: the greeter's 12 columns wide, the fitted copy 11; 3 rows each.
mkdir -p "$work/logo" "$work/share" "$work/bin" "$work/fb"
printf '%s\n' '▄▄▄▄▄▄▄▄▄▄▄▄' '█   LOGO   █' '▀▀▀▀▀▀▀▀▀▀▀▀' >"$work/logo/greeter.txt"
echo 12 >"$work/logo/greeter.cols"
printf '%s\n' '▄▄▄▄▄▄▄▄▄▄▄' '█  LOGO   █' '▀▀▀▀▀▀▀▀▀▀▀' >"$work/logo/fitted.txt"
echo 11 >"$work/logo/fitted.cols"
cp "$SHARE/console-logo.sh" "$work/share/"
: >"$work/share/console-32.psf"
: >"$work/share/console-16.psf"

# size <rows> <cols>: the VT's header in vcsa (rows, columns as single bytes).
size() { printf '%b%b\000\000' "\\$(printf %03o "$1")" "\\$(printf %03o "$2")" >"$work/vcsa"; }
# fb <xres> <yres> <name>, or fb none: the framebuffer's sysfs directory.
fb() {
  rm -rf "$work/fb"
  [[ $1 == none ]] && return
  mkdir -p "$work/fb"
  echo "$1,$2" >"$work/fb/virtual_size"
  echo "$3" >"$work/fb/name"
}
# setfont records its call and, for the 32 px font, halves the console in
# both directions the way the real font change does.
cat >"$work/bin/setfont" <<EOS
#!/bin/bash
echo "setfont \$*" >>"$work/setfont.log"
[[ \$* == *console-32.psf ]] || exit 0
read -r rows cols < <(hexdump -n 2 -v -e '1/1 "%u "' "$work/vcsa")
printf '%b%b\000\000' "\\\\\$(printf %03o \$((rows / 2)))" "\\\\\$(printf %03o \$((cols / 2)))" >"$work/vcsa"
EOS
chmod 755 "$work/bin/setfont"

export OMARCHY_TTY="$work/tty" OMARCHY_VCSA="$work/vcsa" OMARCHY_FB="$work/fb"
export OMARCHY_CONSOLE_LOGO_DIR="$work/logo" OMARCHY_ISO_SHARE="$work/share" OMARCHY_RUN_DIR="$work/run"
export PATH="$work/bin:$PATH"
# shellcheck source=/dev/null
source "$SHARE/console-logo.sh"
draw() { : >"$work/tty"; rm -f "$work/setfont.log"; omarchy_console_logo; cat -v "$work/tty"; }
setfont_calls() { cat "$work/setfont.log" 2>/dev/null || true; }

# The VGA text console: no framebuffer, 80x25. The greeter's 3-row logo in its
# 7-row frame starts on row 10; 12 columns centred on 80 start at column 35.
fb none; size 25 80; out=$(draw)
expect "VGA text: palette, cursor off, clear and green before the logo" "$out" '^[]P01a1b26^[]P29ece6a^[[?25l^[[2J^[[32m^[['
expect "VGA text: the greeter's logo on rows 10-12 at column 35" "$out" '^[[10;35H' '^[[11;35H' '^[[12;35H'
expect "VGA text: colour reset and the cursor a blank line below" "$out" '^[[0m^[[14;1H'
lacks "VGA text: no takeover glyph without a framebuffer" "$out" '.^[[0m^M'
check "VGA text: the kernel's font stays" "$(setfont_calls)" ""
check "VGA text: recorded as laid out on no framebuffer" "$(cat "$work/run/console-logo")" none

# A console narrower than the greeter's logo gets the fitted copy at column 1.
size 25 11; out=$(draw)
expect "11 columns: the fitted logo at column 1" "$out" '^[[10;1H' 'LOGO   '

# The half-size logo in its font: 6 cells by 2 rows here. Its frame is the
# greeter's in half-size cells, so it starts on row (25-2-2)/2+1 = 11, at
# column (80-6)/2+1 = 38; the font is loaded first and the console marked.
vga=$'\uE000\uE001\uE002\uE003\uE004\uE005'
printf '%s\n' "$vga" "$vga" >"$work/logo/vga.txt"
echo 6 >"$work/logo/vga.cols"
: >"$work/logo/vga.psf"
fb none; size 25 80; out=$(draw)
check "VGA font: the logo's font is loaded" "$(setfont_calls)" "setfont -C $work/tty $work/logo/vga.psf"
expect "VGA font: the half-size logo on rows 11-12 at column 38" "$out" '^[[11;38H' '^[[12;38H'
if [[ -e $work/run/console-logo-vga ]]; then ok "VGA font: the console is marked as having the logo's font"; else fail "VGA font: no console-logo-vga marker"; fi
# The next layout, on a framebuffer, loads no font for 8x16: the VGA logo's
# font maps the blocks where the kernel's default font has them.
fb 1280 800 i915drmfb; size 50 160; out=$(draw)
check "after the VGA font: no font loaded on a 1280x800 framebuffer" "$(setfont_calls)" ""
expect "after the VGA font: the greeter's logo on rows 22-24 at column 75" "$out" '^[[22;75H'
if [[ -e $work/run/console-logo-vga ]]; then fail "after the VGA font: the marker stayed"; else ok "after the VGA font: the marker goes"; fi
# A font that does not load leaves the full-size logo.
cat >"$work/bin/setfont-fail" <<'EOS'
#!/bin/bash
[[ $* == *vga.psf ]] && exit 1
exit 0
EOS
chmod 755 "$work/bin/setfont-fail"; mv "$work/bin/setfont" "$work/bin/setfont-ok"; mv "$work/bin/setfont-fail" "$work/bin/setfont"
fb none; size 25 80; out=$(draw)
expect "VGA font that does not load: the greeter's logo at full size, rows 10-12 at column 35" "$out" '^[[10;35H'
if [[ -e $work/run/console-logo-vga ]]; then fail "VGA font that does not load: marked anyway"; else ok "VGA font that does not load: not marked"; fi
mv "$work/bin/setfont" "$work/bin/setfont-fail"; mv "$work/bin/setfont-ok" "$work/bin/setfont"

# omarchy_console_vga_watch: clears the console once the VGA console is no
# longer a console driver, and only while the VGA logo is up.
export OMARCHY_VTCONSOLE="$work/vtconsole"
mkdir -p "$work/vtconsole/vtcon0"; echo "(S) VGA+" >"$work/vtconsole/vtcon0/name"
fb none; size 25 80; draw >/dev/null; : >"$work/tty"
omarchy_console_vga_watch 40 &
watcher=$!
sleep 0.3
check "VGA watch: nothing while the VGA console is there" "$(cat -v "$work/tty")" ""
echo "(S) dummy device" >"$work/vtconsole/vtcon0/name"
wait "$watcher"
check "VGA watch: the console cleared when it goes" "$(cat -v "$work/tty")" '^[[2J'
# fbcon has the console already (no longer 80x25): a layout is on its way,
# and a clear would wipe it.
: >"$work/run/console-logo-vga"; size 50 160; : >"$work/tty"
omarchy_console_vga_watch 4
check "VGA watch: no clear once fbcon has the console" "$(cat -v "$work/tty")" ""
size 25 80
rm -f "$work/run/console-logo-vga"; echo "(S) dummy device" >"$work/vtconsole/vtcon0/name"; : >"$work/tty"
omarchy_console_vga_watch 4
check "VGA watch: nothing without the VGA logo" "$(cat -v "$work/tty")" ""
rm -f "$work/logo/vga.txt" "$work/logo/vga.cols" "$work/logo/vga.psf"

# UEFI at 1920x1080: the dummy console's 80x25 until something is written.
# The takeover glyph goes out first; fbcon then makes it 240x67 (a tenth of a
# second later here), the 32 px font halves that to 120x33, and the logo
# sits at row (33-7)/2+1 = 14, column (120-12)/2+1 = 55.
fb 1920 1080 simpledrmdrmfb; size 25 80
(sleep 0.15; size 67 240) &
out=$(draw)
wait
expect "UEFI 1920x1080: an invisible full stop wakes fbcon before anything else" "$out" '^[[30;40m.^[[0m^M' '^[]P01a1b26'
check "UEFI 1920x1080: the 32 px font is loaded" "$(setfont_calls)" "setfont -C $work/tty $work/share/console-32.psf"
expect "UEFI 1920x1080: laid out for 120x33, rows 14-16 at column 55" "$out" '^[[14;55H' '^[[15;55H' '^[[16;55H'
check "UEFI: recorded the framebuffer the logo is on" "$(cat "$work/run/console-logo")" simpledrmdrmfb

# 1366x768 and 1280x800 keep the kernel's 8x16 (170x48, 160x50): 32 px would
# leave the greeter 85x24 and 80x25, the second narrower than its logo.
fb 1366 768 i915drmfb; size 48 170; out=$(draw)
lacks "1366x768: already taken over, no takeover glyph" "$out" '.^[[0m^M'
check "1366x768: 8x16 kept" "$(setfont_calls)" ""
expect "1366x768: rows 21-23 at column 80" "$out" '^[[21;80H' '^[[22;80H' '^[[23;80H'
fb 1280 800 i915drmfb; size 50 160; out=$(draw)
check "1280x800: 8x16 kept" "$(setfont_calls)" ""
expect "1280x800: rows 22-24 at column 75" "$out" '^[[22;75H' '^[[23;75H' '^[[24;75H'

# The font rule, and the greeter's font (i18n_console_font) agreeing with it.
cp -r "$SHARE" "$work/share-i18n"
echo font >"$work/share-i18n/console-16.psf"
echo font >"$work/share-i18n/console-32.psf"
greeter_font() {
  rm -f "$work/setfont.log"
  bash -c 'source "$1/i18n.sh"; i18n_console_font /dev/tty1' _ "$work/share-i18n" >/dev/null 2>&1 || true
  sed -n 's|.*/console-\([0-9]*\)\.psf$|\1|p' "$work/setfont.log" 2>/dev/null || true
}
for res in 1280x800:16 1366x768:16 1600x900:16 1920x1080:32 2560x1440:32 1920x720:16; do
  x=${res%%x*}; rest=${res#*x}; y=${rest%%:*}; want=${res##*:}
  fb "$x" "$y" x
  check "${x}x$y: the boot logo's font is $want px" "$(omarchy_console_font_size)" "$want"
  check "${x}x$y: the greeter loads the same $want px font" "$(greeter_font)" "$want"
done

# omarchy-console-logo-redraw: redraws only for a framebuffer the logo is not
# laid out on yet, and only while the installer has not taken tty1.
redraw() { : >"$work/tty"; "$REDRAW"; cat -v "$work/tty"; }
mkdir -p "$work/run"; rm -f "$work/run/tty1-taken"
fb 1920 1080 simpledrmdrmfb; size 67 240; echo simpledrmdrmfb >"$work/run/console-logo"
check "redraw: udev's replay of the same framebuffer draws nothing" "$(redraw)" ""
fb 1920 1080 i915drmfb; size 67 240
expect "redraw: a GPU driver's framebuffer gets the logo again, in 32 px at row 14, column 55" "$(redraw)" '^[[14;55H'
check "redraw: records the new framebuffer" "$(cat "$work/run/console-logo")" i915drmfb
fb 1920 1080 amdgpudrmfb; : >"$work/run/tty1-taken"
check "redraw: nothing once the installer has tty1" "$(redraw)" ""
rm -f "$work/run/tty1-taken" "$work/run/console-logo"
check "redraw: nothing when no boot logo was drawn" "$(redraw)" ""

# --wait: the i915 hook starts it inside the new root before switch_root, and
# it lays the logo out once the panel's framebuffer replaces the one the logo
# was drawn on (none on the VGA text console).
rm -f "$work/run/tty1-taken" "$work/run/console-logo"
fb none; size 25 80; : >"$work/tty"
OMARCHY_REDRAW_WAIT_STEPS=60 "$REDRAW" --wait &
waiter=$!
sleep 0.3
check "redraw --wait: nothing while there is no framebuffer and no record" "$(cat -v "$work/tty")" ""
echo none >"$work/run/console-logo"; size 50 160; fb 1280 800 i915drmfb
wait "$waiter"
expect "redraw --wait: the logo for the panel's console once it is there, rows 22-24 at column 75" "$(cat -v "$work/tty")" '^[[22;75H' '^[[23;75H' '^[[24;75H'
check "redraw --wait: records the panel's framebuffer" "$(cat "$work/run/console-logo")" i915drmfb
# i915's framebuffer is registered before fbcon has the panel: the console
# stays 80x25 until the takeover's modeset is done.
echo none >"$work/run/console-logo"; fb 1280 800 i915drmfb; size 25 80; : >"$work/tty"
: >"$work/run/i915-loading"
OMARCHY_REDRAW_WAIT_STEPS=60 "$REDRAW" --wait &
waiter=$!
sleep 0.3
check "redraw --wait: nothing while fbcon is still taking the panel over" "$(cat -v "$work/tty")" ""
size 50 160
wait "$waiter"
expect "redraw --wait: laid out for the panel once fbcon has it, rows 22-24 at column 75" "$(cat -v "$work/tty")" '^[[22;75H' '^[[23;75H' '^[[24;75H'
if [[ -e $work/run/i915-loading ]]; then fail "redraw --wait: left the i915-loading marker"; else ok "redraw --wait: clears the i915-loading marker"; fi
# UEFI: the logo is on simpledrm until i915 takes the framebuffer over.
fb 1920 1080 simpledrmdrmfb; size 67 240; echo simpledrmdrmfb >"$work/run/console-logo"; : >"$work/tty"
OMARCHY_REDRAW_WAIT_STEPS=60 "$REDRAW" --wait &
waiter=$!
sleep 0.3
check "redraw --wait: nothing while the logo's framebuffer is still there" "$(cat -v "$work/tty")" ""
fb 1920 1080 i915drmfb
wait "$waiter"
expect "redraw --wait: i915's framebuffer gets the logo in 32 px at row 14, column 55" "$(cat -v "$work/tty")" '^[[14;55H'
# The installer takes tty1 first, or no new framebuffer comes.
fb none; echo none >"$work/run/console-logo"; : >"$work/tty"
OMARCHY_REDRAW_WAIT_STEPS=60 "$REDRAW" --wait &
waiter=$!
sleep 0.2; : >"$work/run/tty1-taken"; size 50 160; fb 1280 800 i915drmfb
wait "$waiter"
check "redraw --wait: nothing once the installer has tty1" "$(cat -v "$work/tty")" ""
rm -f "$work/run/tty1-taken"; fb none; : >"$work/tty"
OMARCHY_REDRAW_WAIT_STEPS=4 "$REDRAW" --wait
check "redraw --wait: gives up when no framebuffer comes" "$(cat -v "$work/tty")" ""
# With the VGA logo up, it clears the console as soon as the VGA console
# goes, then lays the logo out on the framebuffer that comes, in a whole font.
echo none >"$work/run/console-logo"; : >"$work/run/console-logo-vga"; : >"$work/tty"
echo "(S) VGA+" >"$work/vtconsole/vtcon0/name"; fb none; size 25 80
OMARCHY_REDRAW_WAIT_STEPS=60 "$REDRAW" --wait &
waiter=$!
sleep 0.3
echo "(S) dummy device" >"$work/vtconsole/vtcon0/name"
sleep 0.3
check "redraw --wait: clears the console when the VGA console goes" "$(cat -v "$work/tty")" '^[[2J'
rm -f "$work/setfont.log"; size 50 160; fb 1280 800 amdgpudrmfb
wait "$waiter"
expect "redraw --wait: then the logo for the framebuffer, rows 22-24 at column 75" "$(cat -v "$work/tty")" '^[[2J' '^[[22;75H'
check "redraw --wait: in the kernel's font, none loaded" "$(setfont_calls)" ""

# --before-driver: udev, for a display controller before its driver loads.
# While the VGA logo is up it clears the console if a driver will load, and
# leaves it alone when one is bound already, none exists, or no VGA logo is up.
mkdir -p "$work/sysfs/devices/pci0000:00/0000:00:02.0"
cat >"$work/bin/modprobe" <<'EOS'
#!/bin/bash
[[ $* == *pci:v00001234* ]] && echo "insmod /lib/modules/x/kernel/drivers/gpu/drm/tiny/bochs.ko.zst"
exit 0
EOS
chmod 755 "$work/bin/modprobe"
before() {
  : >"$work/tty"
  OMARCHY_SYSFS="$work/sysfs" DEVPATH=/devices/pci0000:00/0000:00:02.0 MODALIAS=$1 "$REDRAW" --before-driver
  cat -v "$work/tty"
}
rm -f "$work/run/tty1-taken"; : >"$work/run/console-logo-vga"; size 25 80
check "before a driver: the console cleared when one will load" "$(before pci:v00001234d00001111sv0bc03sc00i00)" '^[[2J'
size 50 160
check "before a driver: no clear on a console another driver has already" "$(before pci:v00001234d00001111sv0bc03sc00i00)" ""
size 25 80
check "before a driver: nothing when none exists for the device" "$(before pci:v0000ABCDd00000001sv0bc03sc00i00)" ""
mkdir -p "$work/sysfs/devices/pci0000:00/0000:00:02.0/driver"
check "before a driver: nothing when one is bound already" "$(before pci:v00001234d00001111sv0bc03sc00i00)" ""
rmdir "$work/sysfs/devices/pci0000:00/0000:00:02.0/driver"; rm -f "$work/run/console-logo-vga"
check "before a driver: nothing without the VGA logo up" "$(before pci:v00001234d00001111sv0bc03sc00i00)" ""

# One layout at a time: a redraw waits for one in progress (the lock), then
# finds the logo laid out on this framebuffer and draws nothing.
rm -f "$work/run/tty1-taken" "$work/run/console-logo-vga"; echo none >"$work/run/console-logo"
fb 1280 800 i915drmfb; size 50 160; : >"$work/tty"
( flock 9; sleep 0.5; echo i915drmfb >"$work/run/console-logo" ) 9>>"$work/run/console-logo.lock" &
holder=$!
sleep 0.1
start=$(date +%s%N); "$REDRAW"; took=$(( ($(date +%s%N) - start) / 1000000 ))
wait "$holder"
if (( took >= 300 )); then ok "redraw: waits for a layout in progress (${took} ms)"; else fail "redraw: did not wait for the lock (${took} ms)"; fi
check "redraw: then finds the logo laid out on this framebuffer and draws nothing" "$(cat -v "$work/tty")" ""

# No logo files: nothing drawn, no error.
export OMARCHY_CONSOLE_LOGO_DIR="$work/missing"
fb none; size 25 80
check "no logo files: nothing written" "$(draw)" ""

exit "$((failures > 0))"
