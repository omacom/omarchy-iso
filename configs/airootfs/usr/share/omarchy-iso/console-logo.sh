# The Omarchy boot logo on tty1, laid out where the installer's greeter will
# draw it. POSIX sh: sourced by the live initramfs's hooks (busybox ash,
# etc/initcpio/hooks/omarchy-logo and omarchy-i915), by
# omarchy-console-logo-redraw in the live root, and by i18n.sh for the font
# rule. Sourced, not executed; nothing here may fail the caller.
#
# A BIOS machine boots on the VGA text console and gets a framebuffer only
# when its GPU driver loads; a UEFI machine has the firmware's framebuffer
# from the start but nothing draws on it. Either way the screen was black
# from the kernel's start until the greeter. The initramfs hook puts the
# logo on tty1 as the boot's first act, laid out the way the configurator's
# greeter() lays it out (logo, blank, tagline, blank, hint centred as a
# block, the logo centred at its own width), so the greeter draws over it in
# place: same font, same rows and columns.
#
# Three things decide the layout:
# - The console's size, from the VT's header in /dev/vcsa1. On a UEFI
#   machine fbcon defers taking the firmware framebuffer over until
#   something is written to the console, and a space does not count (the
#   dummy console ignores its erase character): until then the VT is the
#   dummy console's 80x25. omarchy_console_takeover writes an invisible full
#   stop and waits for the size to move.
# - The font (omarchy_console_font_size): the 32 px Terminus where the
#   framebuffer is at least 1852 pixels wide and 800 high, so the greeter's
#   81-column logo fills about two thirds of the width (1920x1080 and up);
#   8x16 below that, where it already fills about half (1366x768, 1280x800)
#   and 32 px would leave the greeter fewer than its 81 columns. The greeter
#   and the install dashboard load their font by the same rule
#   (i18n_console_font).
# - The logo: the greeter's own (81 columns) on a framebuffer console, the
#   copy fitted to 80 columns (omarchy-console-logo) where that is narrower.
#   The VGA text console's cells are 9x16 pixels of a 720x400 picture
#   stretched over the panel, twice a framebuffer console's 8x16 on a
#   1280x800 one, so there the logo is drawn at half size in a font of its
#   own (vga-logo-font.py: each cell a 2x4 piece of its pixel grid), which
#   puts it at the greeter's size and place. A GPU driver taking the console
#   over draws its cells in the kernel's default font, where those pieces are
#   box drawing: omarchy_console_vga_watch clears the console when the VGA
#   console goes. The font is CP437 otherwise, like the kernel's, so the
#   greeter's logo needs no font loaded on the driver's console.
#
# The paths are variables for the unit test (test/unit/console-logo-hook-test.sh).

# omarchy_console_size: "rows cols " of tty1.
omarchy_console_size() {
    hexdump -n 2 -v -e '1/1 "%u "' "${OMARCHY_VCSA:-/dev/vcsa1}" 2>/dev/null
}

# omarchy_console_takeover: on a framebuffer still behind the dummy console,
# write a full stop in black on black so fbcon takes the console over, and
# give the takeover two seconds: on UEFI it runs from a workqueue as soon as
# something is written, and a GPU driver taking over from the VGA console has
# its framebuffer in sysfs before the modeset of fbcon's takeover is done
# (in QEMU under load, longer than half a second).
omarchy_console_takeover() {
    local tty="${OMARCHY_TTY:-/dev/tty1}" fb="${OMARCHY_FB:-/sys/class/graphics/fb0}" i=0
    [ -e "$fb" ] && [ "$(omarchy_console_size)" = "25 80 " ] || return 0
    printf '\033[30;40m.\033[0m\r' 2>/dev/null >>"$tty"
    while [ "$i" -lt 40 ] && [ "$(omarchy_console_size)" = "25 80 " ]; do
        sleep 0.05
        i=$((i + 1))
    done
}

# omarchy_console_vga_bound: the VGA text console (vgacon) is still a console
# driver; a GPU driver unregisters it when it takes the hardware over.
omarchy_console_vga_bound() {
    grep -qs 'VGA' "${OMARCHY_VTCONSOLE:-/sys/class/vtconsole}"/vtcon*/name
}

# omarchy_console_vga_watch [STEPS]: while the half-size logo is up in its own
# font, clear tty1 as soon as the VGA console is gone, before fbcon shows its
# lines; a GPU driver's modeset leaves the screen dark in between. Only while
# the console is still the dummy one the driver put in its place (80x25): it
# shows nothing, and no layout can come before fbcon has the console. Once
# fbcon has it, a layout is on its way and a clear would wipe it. Polls every
# 0.05 s, STEPS times at most (default 200), and stops early once the
# initramfs is gone (the paths with it) or the installer has tty1.
omarchy_console_vga_watch() {
    local tty="${OMARCHY_TTY:-/dev/tty1}" run="${OMARCHY_RUN_DIR:-/run/omarchy-iso}" i=0
    while [ "$i" -lt "${1:-200}" ] && [ -e "$run/console-logo-vga" ] && [ ! -e "$run/tty1-taken" ]; do
        if [ -d "${OMARCHY_VTCONSOLE:-/sys/class/vtconsole}" ] && ! omarchy_console_vga_bound; then
            [ "$(omarchy_console_size)" = "25 80 " ] && printf '\033[2J' 2>/dev/null >>"$tty"
            return 0
        fi
        sleep 0.05
        i=$((i + 1))
    done
}

# omarchy_console_font_size: 32 or 16, the console font for this framebuffer.
omarchy_console_font_size() {
    local fb="${OMARCHY_FB:-/sys/class/graphics/fb0}" xres=0 yres=0
    [ -r "$fb/virtual_size" ] && IFS=, read -r xres yres <"$fb/virtual_size"
    if [ "${xres:-0}" -ge 1852 ] 2>/dev/null && [ "${yres:-0}" -ge 800 ] 2>/dev/null; then
        echo 32
    else
        echo 16
    fi
}

omarchy_console_logo() {
    local tty="${OMARCHY_TTY:-/dev/tty1}" fb="${OMARCHY_FB:-/sys/class/graphics/fb0}"
    local dir="${OMARCHY_CONSOLE_LOGO_DIR:-/usr/share/omarchy-iso/console-logo}"
    local share="${OMARCHY_ISO_SHARE:-/usr/share/omarchy-iso}" run="${OMARCHY_RUN_DIR:-/run/omarchy-iso}"
    local logo rows cols logo_rows logo_cols top left row line fb_name=none size frame=4
    [ -e "$tty" ] || return 0
    omarchy_console_takeover
    size=$(omarchy_console_font_size)
    logo=greeter
    if [ ! -e "$fb" ]; then
        # The VGA text console: the half-size logo, in its font.
        if [ -r "$dir/vga.psf" ] && [ -r "$dir/vga.txt" ] && setfont -C "$tty" "$dir/vga.psf" 2>/dev/null; then
            logo=vga
            frame=2
        fi
    elif [ "$size" = 32 ] && [ -r "$share/console-32.psf" ]; then
        setfont -C "$tty" "$share/console-32.psf" 2>/dev/null
    fi
    # shellcheck disable=SC2046 # rows and columns, two words
    set -- $(omarchy_console_size)
    rows=${1:-25}
    cols=${2:-80}

    # The widths come from the generator's sidecars: busybox's awk and wc
    # count bytes, and the block glyphs are three each.
    if [ "$logo" = vga ]; then
        logo_cols=$(cat "$dir/vga.cols" 2>/dev/null)
    else
        logo_cols=$(cat "$dir/greeter.cols" 2>/dev/null)
        if [ ! -r "$dir/greeter.txt" ] || ! [ "${logo_cols:-0}" -gt 0 ] 2>/dev/null || [ "$cols" -lt "$logo_cols" ]; then
            logo=fitted
            logo_cols=$(cat "$dir/fitted.cols" 2>/dev/null)
        fi
    fi
    [ "${logo_cols:-0}" -gt 0 ] 2>/dev/null || logo_cols=80
    [ -r "$dir/$logo.txt" ] || return 0
    logo_rows=$(wc -l <"$dir/$logo.txt")
    # The greeter's frame: logo, blank, tagline, blank, hint; in half-size
    # cells those four lines are two.
    top=$(((rows - logo_rows - frame) / 2 + 1))
    [ "$top" -lt 1 ] && top=1
    left=$(((cols - logo_cols) / 2 + 1))
    [ "$left" -lt 1 ] && left=1
    {
        # Palette entries 0 and 2 as .automated_script.sh sets them later.
        printf '\033]P01a1b26\033]P29ece6a\033[?25l\033[2J\033[32m'
        row=$top
        while IFS= read -r line; do
            printf '\033[%d;%dH%s' "$row" "$left" "$line"
            row=$((row + 1))
        done <"$dir/$logo.txt"
        printf '\033[0m\033[%d;1H' "$((row + 1))"
    } 2>/dev/null >>"$tty"

    # Which framebuffer the logo is laid out for: omarchy-console-logo-redraw
    # compares it, and .automated_script.sh leaves the logo up while it exists.
    # console-logo-vga: the console has the VGA logo's font.
    [ -r "$fb/name" ] && read -r fb_name <"$fb/name"
    if mkdir -p "$run" 2>/dev/null; then
        echo "$fb_name" 2>/dev/null >"$run/console-logo"
        if [ "$logo" = vga ]; then
            : 2>/dev/null >"$run/console-logo-vga"
        else
            rm -f "$run/console-logo-vga"
        fi
    fi
    [ -w /dev/kmsg ] && echo "omarchy-logo: ${cols}x$rows on $fb_name, $logo logo at row $top column $left" 2>/dev/null >/dev/kmsg
    return 0
}
