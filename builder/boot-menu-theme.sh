#!/bin/bash

# Omarchy's GRUB menu (configs/grub/themes/omarchy/theme.txt) needs fonts,
# pixmaps and the logo next to it. They are made at build time from the same
# sources as the rest of the boot: the logo from the Plymouth theme in the
# omarchy-settings package the live system installs, the fonts from the 16
# px Terminus Bold that the installer's console draws in
# (configs/airootfs/usr/share/omarchy-iso/i18n.sh), so neither can drift
# from what boots after the menu.
#
# Callers run these as `build_... || exit 1`, which turns off errexit inside
# them, so every step checks itself.
build_grub_theme() {
  local theme_dir=$1 settings_archive=$2
  local size pf2 part

  if ! bsdtar -xOf "$settings_archive" usr/share/plymouth/themes/omarchy/logo.png >"$theme_dir/logo.png" ||
    [[ ! -s $theme_dir/logo.png ]]; then
    echo "ERROR: $settings_archive has no Plymouth logo for the boot menu" >&2
    return 1
  fi

  # GRUB's own console and editor take the 16 px font as terminus-font ships
  # it for GRUB. The entries take it with every pixel doubled: Terminus keeps
  # a 2 px stroke at every size, so its 28 and 32 px builds read thin next to
  # the console, and GRUB cannot scale a bitmap font.
  cp /usr/share/grub/ter-u16b.pf2 "$theme_dir/ter-u16b.pf2" || return 1
  python3 /builder/grub-font-double.py /usr/share/grub/ter-u16b.pf2 "$theme_dir/ter-u16b-2x.pf2" "Terminus 2x" || return 1
  # The BIOS menu's font: the same 16 px Terminus Bold, as the 256-glyph PSF
  # version 1 build that syslinux's FONT loads (core/font.c); vesamenu draws
  # in the font syslinux has loaded. It lives here because mkarchiso copies
  # only *.cfg and splash.png from the syslinux directory, and this one whole
  # (configs/syslinux/archiso_head.cfg).
  zcat /usr/share/kbd/consolefonts/ter-116b.psf.gz >"$theme_dir/ter-116b.psf" || return 1
  # The theme names its fonts by family, weight and size.
  for pf2 in "ter-u16b:Terminus Bold 16" "ter-u16b-2x:Terminus 2x Bold 32"; do
    if ! grep -aq "${pf2#*:}" "$theme_dir/${pf2%%:*}.pf2"; then
      echo "ERROR: ${pf2%%:*}.pf2 is not ${pf2#*:}" >&2
      return 1
    fi
  done

  # A styled box is nine pixmaps, scaled to fit. The selected entry: Tokyo
  # Night's selection colour with the logo's green down its left edge.
  # PNG32: ImageMagick writes a one-colour image as a 1-bit colormap, which
  # GRUB's PNG reader rejects, and the menu loses its selection bar.
  for part in n ne e se s sw c; do
    magick -size 1x1 xc:'#292e42' PNG32:"$theme_dir/select_$part.png" || return 1
  done
  for part in w nw sw; do
    magick -size 4x1 xc:'#a8cd76' PNG32:"$theme_dir/select_$part.png" || return 1
  done
  magick -size 1x1 xc:'#1a1b26' PNG32:"$theme_dir/scroll_frame_c.png" || return 1
  magick -size 1x1 xc:'#414868' PNG32:"$theme_dir/scroll_thumb_c.png" || return 1
  # The console and editor ('c', 'e') in a box of the selection colour.
  for part in n ne e se s sw w nw; do
    magick -size 2x2 xc:'#292e42' PNG32:"$theme_dir/terminal_box_$part.png" || return 1
  done
  magick -size 1x1 xc:'#1a1b26' PNG32:"$theme_dir/terminal_box_c.png" || return 1
}

# The BIOS menu (configs/syslinux/archiso_head.cfg) draws on a 640x480
# picture: the same logo at half size, on the same background, where the
# menu's rows leave room for it. 8-bit RGB, as vesamenu reads PNG. Its font
# comes with the GRUB theme (build_grub_theme).
build_syslinux_splash() {
  local splash=$1 settings_archive=$2 logo

  logo=$(mktemp --suffix=.png) || return 1
  if ! bsdtar -xOf "$settings_archive" usr/share/plymouth/themes/omarchy/logo.png >"$logo" || [[ ! -s $logo ]]; then
    echo "ERROR: $settings_archive has no Plymouth logo for the BIOS menu" >&2
    rm -f "$logo"
    return 1
  fi
  magick -size 640x480 xc:'#1a1b26' \( "$logo" -filter point -resize 50% \) -gravity north -geometry +0+150 -composite PNG24:"$splash"
  local status=$?
  rm -f "$logo"
  return $status
}
