#!/bin/bash

# Omarchy's GRUB menu (configs/grub/themes/omarchy/theme.txt) needs fonts,
# pixmaps and the logo next to it. They are made at build time from the same
# sources as the rest of the boot: the logo from the Plymouth theme in the
# omarchy-settings package the live system installs, the fonts from
# JetBrains Mono, so neither can drift from what boots after the menu.
#
# Callers run these as `build_... || exit 1`, which turns off errexit inside
# them, so every step checks itself.
build_grub_theme() {
  local theme_dir=$1 settings_archive=$2
  local fonts=/usr/share/fonts/TTF size weight pf2 part

  if ! bsdtar -xOf "$settings_archive" usr/share/plymouth/themes/omarchy/logo.png >"$theme_dir/logo.png" ||
    [[ ! -s $theme_dir/logo.png ]]; then
    echo "ERROR: $settings_archive has no Plymouth logo for the boot menu" >&2
    return 1
  fi

  # Latin, punctuation and the box and arrow glyphs GRUB's console and
  # editor draw; the full font is 30 times larger and slower to load.
  for size in 16 26; do
    for weight in Regular Bold; do
      [[ $size == 16 && $weight == "Bold" ]] && continue
      pf2="$theme_dir/jetbrains-mono-${weight,,}-$size.pf2"
      grub-mkfont --size "$size" --range 0x20-0x7E,0xA0-0x17F,0x2000-0x206F,0x2190-0x21FF,0x2500-0x25FF \
        --output "$pf2" "$fonts/JetBrainsMono-$weight.ttf" || return 1
      # grub-mkfont writes an empty "Unknown" font for an input it cannot
      # read, and the theme names its fonts by family, weight and size.
      if ! grep -aq "JetBrains Mono $weight $size" "$pf2"; then
        echo "ERROR: $pf2 is not JetBrains Mono $weight $size" >&2
        return 1
      fi
    done
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
# menu's rows leave room for it. 8-bit RGB, as vesamenu reads PNG.
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
