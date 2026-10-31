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

# omarchy_console_kd_mode 0|1: tty1 in text mode (0) or graphics mode (1),
# where the console keeps its text but draws none of it and the screen keeps
# what it shows. KDSETMODE, by perl: no command in the live root makes the
# call, and the initramfs, which has no perl, needs none. Fails where it can
# not (the caller goes on without).
omarchy_console_kd_mode() {
    command -v perl >/dev/null 2>&1 || return 1
    perl -e 'open(my $t, "+<", $ARGV[0]) or exit 1; ioctl($t, 0x4B3A, $ARGV[1] + 0) or exit 1' \
        "${OMARCHY_TTY:-/dev/tty1}" "$1" 2>/dev/null
}

# omarchy_console_thaw: tty1 back in text mode, if omarchy-console-logo-redraw
# put it in graphics mode ahead of a GPU driver (its --before-driver). The
# mark stays until that worked, for the next caller to try again.
omarchy_console_thaw() {
    local run="${OMARCHY_RUN_DIR:-/run/omarchy-iso}"
    [ -e "$run/console-frozen" ] || return 0
    omarchy_console_kd_mode 0 && rm -f "$run/console-frozen"
}

# omarchy_console_claim_tty1: the installer draws on tty1 from here, and the
# boot logo is no longer laid out again when a GPU driver replaces the
# framebuffer, nor the VGA one cleared (omarchy-console-logo-redraw). Taken
# under the layout lock, so a layout in progress finishes first. Until then
# the redraw goes on after the login too: the login waits for udev to settle
# (omarchy-cidata-load), GPU drivers and all, before the configurator starts,
# and a driver that loaded after the login left the console blank until the
# greeter (test/boot-render with a udev rule that holds the driver back). A
# layout takes three seconds at most (the takeover's two, the 32 px font's
# one); the claim waits five, and never fails its caller (set -e). A console
# still in graphics mode for a GPU driver that brought no framebuffer gets
# its text mode back, or the installer would draw unseen: after the claim, so
# that a freeze the wait ran out on finds tty1 taken, or is found here.
omarchy_console_claim_tty1() {
    local run="${OMARCHY_RUN_DIR:-/run/omarchy-iso}"
    mkdir -p "$run" 2>/dev/null || return 0
    {
        flock -w 5 9 || true
        : >"$run/tty1-taken"
        omarchy_console_thaw
    } 9>>"$run/console-logo.lock" 2>/dev/null || true
    return 0
}

# omarchy_console_no_driver_coming: true where no GPU driver will give tty1 a
# framebuffer any more: there is none, and either the kernel runs nomodeset or
# no display controller has a driver bound or one to load. The live login runs
# after udev has settled (omarchy-cidata-load), so by the configurator's first
# screen a driver that is coming has loaded or is loading.
omarchy_console_no_driver_coming() {
    local fb="${OMARCHY_FB:-/sys/class/graphics/fb0}" dev class alias cmdline=""
    [ -e "$fb" ] && return 1
    read -r cmdline <"${OMARCHY_CMDLINE:-/proc/cmdline}" 2>/dev/null
    case " $cmdline " in *" nomodeset "*) return 0 ;; esac
    for dev in "${OMARCHY_SYSFS:-/sys}"/bus/pci/devices/*; do
        read -r class <"$dev/class" 2>/dev/null || continue
        case $class in 0x03*) ;; *) continue ;; esac
        [ -e "$dev/driver" ] && return 1
        read -r alias <"$dev/modalias" 2>/dev/null || continue
        modprobe -n -b -v "$alias" 2>/dev/null | grep -q '^insmod ' && return 1
    done
    return 0
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

# omarchy_console_font_32 TTY FONT: load the 32 px font, and again while the
# console's columns still count 8-pixel cells. A font loaded as fbcon takes a
# GPU driver's framebuffer over can be reset to the kernel's when the takeover
# finishes: the logo was then laid out at 8x16, and jumped to 16x32 at the
# greeter (QEMU under load, BIOS at 1920x1440). A second at most.
omarchy_console_font_32() {
    local tty="$1" font="$2" fb="${OMARCHY_FB:-/sys/class/graphics/fb0}" xres=0 yres=0 i=0
    [ -r "$fb/virtual_size" ] && IFS=, read -r xres yres <"$fb/virtual_size"
    while :; do
        setfont -C "$tty" "$font" 2>/dev/null
        # shellcheck disable=SC2046 # rows and columns, two words
        set -- $(omarchy_console_size)
        [ "${2:-0}" -le $((xres / 16)) ] 2>/dev/null && return 0
        [ "$i" -lt 10 ] || return 0
        sleep 0.1
        i=$((i + 1))
    done
}

omarchy_console_logo() {
    local tty="${OMARCHY_TTY:-/dev/tty1}" fb="${OMARCHY_FB:-/sys/class/graphics/fb0}"
    local dir="${OMARCHY_CONSOLE_LOGO_DIR:-/usr/share/omarchy-iso/console-logo}"
    local share="${OMARCHY_ISO_SHARE:-/usr/share/omarchy-iso}" run="${OMARCHY_RUN_DIR:-/run/omarchy-iso}"
    local logo rows cols logo_rows logo_cols top left row line fb_name=none size frame=4 screen i
    [ -e "$tty" ] || return 0
    omarchy_console_takeover
    size=$(omarchy_console_font_size)
    logo=greeter
    if [ ! -e "$fb" ] && ! omarchy_console_vga_bound; then
        # No display yet: a GPU with neither a firmware framebuffer nor VGA
        # (QEMU's virtio-gpu-pci on UEFI) shows nothing until its driver
        # loads, and fbcon would then show this layout, made for the dummy
        # console's 80x25, at the top left of the driver's framebuffer until
        # the redraw. The console stays empty; the redraw draws the logo.
        mkdir -p "$run" 2>/dev/null && echo none 2>/dev/null >"$run/console-logo"
        [ -w /dev/kmsg ] && echo "omarchy-logo: no display yet, the logo waits for a framebuffer" 2>/dev/null >/dev/kmsg
        return 0
    fi
    if [ ! -e "$fb" ]; then
        # The VGA text console: the half-size logo, in its font.
        if [ -r "$dir/vga.psf" ] && [ -r "$dir/vga.txt" ] && setfont -C "$tty" "$dir/vga.psf" 2>/dev/null; then
            logo=vga
            frame=2
        fi
    elif [ "$size" = 32 ] && [ -r "$share/console-32.psf" ]; then
        omarchy_console_font_32 "$tty" "$share/console-32.psf"
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
    # Drawn over what the console shows rather than after clearing it: the
    # rows above the logo erased, each logo row drawn with what is left and
    # right of it erased, the rows below erased. ISOLINUX's logo is on the
    # screen already, cell for cell, and stays up instead of going dark for
    # the clear (a frame of black in QEMU, where each of the clear's writes
    # to the VGA's memory leaves the guest). Erasing the rest of a row that
    # ends in the last column would erase that column (the VT holds the
    # cursor there until the next character), so such rows are erased first.
    screen=$(
        if [ "$logo" = vga ]; then
            # ISOLINUX put this logo up already, in its colors: bright green
            # on the VGA palette's black (configs/syslinux/omarchy-logo.txt).
            # Drawn the same, it stays as it is; the installer's palette
            # comes with a GPU driver's framebuffer or the login.
            printf '\033[?25l\033[1;32m'
        else
            # Palette entries 0 and 2 as .automated_script.sh sets them later.
            printf '\033]P01a1b26\033]P29ece6a\033[?25l\033[32m'
        fi
        [ "$top" -gt 1 ] && printf '\033[%d;%dH\033[1J' "$((top - 1))" "$cols"
        row=$top
        while IFS= read -r line; do
            if [ $((left + logo_cols)) -gt "$cols" ]; then
                printf '\033[%d;1H\033[2K\033[%d;%dH%s' "$row" "$row" "$left" "$line"
            elif [ "$left" -gt 1 ]; then
                printf '\033[%d;1H\033[%dX\033[%d;%dH%s\033[K' "$row" "$((left - 1))" "$row" "$left" "$line"
            else
                printf '\033[%d;1H%s\033[K' "$row" "$line"
            fi
            row=$((row + 1))
        done <"$dir/$logo.txt"
        [ "$row" -le "$rows" ] && printf '\033[%d;1H\033[J' "$row"
        printf '\033[0m\033[%d;1H' "$((row + 1))"
    )
    # In one write, and again on a fresh open if that fails: login hangs tty1
    # up as it starts the session (util-linux login's vhangup), and a layout
    # it cut off half way left the console cleared and the logo missing until
    # the greeter (QEMU under load, one BIOS boot in six; the journal had the
    # layout, the screen only its clear).
    i=0
    while [ "$i" -lt 3 ]; do
        printf '%s' "$screen" 2>/dev/null >>"$tty" && break
        i=$((i + 1))
        sleep 0.05
    done

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
    # The BIOS boot starts without a cursor, so none shows below ISOLINUX's
    # logo (configs/syslinux/omarchy-logo.cfg); tty1 keeps its own hidden,
    # the consoles opened from here on get theirs.
    echo 1 2>/dev/null >"${OMARCHY_VT_CURSOR:-/sys/module/vt/parameters/global_cursor_default}"
    return 0
}
