# shellcheck shell=bash
# Port of lib/locale/utils.py and the locale/keyboard methods of Installer.

locale_list_keyboard_languages() {
  SYSTEMD_COLORS=0 localectl --no-pager list-keymaps 2>/dev/null
}

locale_verify_keyboard_layout() {
  local layout=${1,,} l
  while read -r l; do
    [[ ${l,,} == "$layout" ]] && return 0
  done < <(locale_list_keyboard_languages)
  return 1
}

# get_kb_layout(): the live console keymap, if localectl knows it.
locale_get_kb_layout() {
  local layout
  layout=$(SYSTEMD_COLORS=0 localectl --no-pager status 2>/dev/null | awk -F': ' '/VC Keymap: /{ print $2 }' | tail -n1)
  [[ -n $layout && $layout != '(unset)' ]] || return 0
  locale_verify_keyboard_layout "$layout" && printf '%s' "$layout"
  return 0
}

# Installer.set_vconsole(): KEYMAP + FONT in /etc/vconsole.conf.
installer_set_vconsole() {
  local kb=$CFG_LOCALE_KB font=$CFG_LOCALE_FONT
  [[ $font == ter-* ]] && pacman_strap terminus-font
  mkdir -p "$INST_TARGET/etc"
  printf 'KEYMAP=%s\nFONT=%s\n' "$kb" "$font" >"$INST_TARGET/etc/vconsole.conf"
  info "Wrote to $INST_TARGET/etc/vconsole.conf using $kb and $font"
}

# Installer.set_locale(): uncomment the locale in locale.gen, run locale-gen,
# write locale.conf.
installer_set_locale() {
  local lang=$CFG_LOCALE_LANG encoding=$CFG_LOCALE_ENC modifier='' potential
  if [[ $lang == *.* ]]; then
    potential=${lang#*.}
    lang=${lang%%.*}
    if [[ $CFG_LOCALE_ENC == UTF-8 && $potential != "$CFG_LOCALE_ENC" ]]; then
      encoding=$potential
    fi
  fi
  if [[ $lang == *@* ]]; then
    modifier="@${lang#*@}"
    lang=${lang%%@*}
  fi

  local locale_gen="$INST_TARGET/etc/locale.gen"
  local entry_re="^#${lang}(\\.${encoding})?${modifier} ${encoding}"
  if ! grep -Eq "$entry_re" "$locale_gen" 2>/dev/null; then
    error "Invalid locale: language '$CFG_LOCALE_LANG', encoding '$CFG_LOCALE_ENC'"
    return 1
  fi
  # Uncomment the first matching entry only, like upstream.
  local tmp
  tmp=$(mktemp)
  awk -v re="${entry_re//\\/\\\\}" '!done && $0 ~ re { sub(/^#/, ""); done = 1 } { print }' "$locale_gen" >"$tmp" && cat "$tmp" >"$locale_gen"
  rm -f "$tmp"

  if ! chroot_cmd locale-gen; then
    error "Failed to run locale-gen on target: $SYS_CMD_OUTPUT"
    return 1
  fi
  printf 'LANG=%s.%s%s\n' "$lang" "$encoding" "$modifier" >"$INST_TARGET/etc/locale.conf"
}

# Installer.set_keyboard_language(): upstream boots the target in a container
# to run `localectl set-keymap`. This writes what localectl would have
# written without booting anything: KEYMAP in vconsole.conf (via
# systemd-firstboot, keeping the FONT set_vconsole wrote) and the matching
# X11 layout from systemd's kbd-model-map.
installer_set_keyboard_language() {
  local language=${1:-$CFG_LOCALE_KB}
  info "Setting keyboard language to $language"
  if [[ -z ${language// /} ]]; then
    info 'Keyboard language was not changed from default (no language specified)'
    return 0
  fi
  if ! locale_verify_keyboard_layout "$language"; then
    error "Invalid keyboard language specified: $language"
    return 1
  fi

  local vconsole="$INST_TARGET/etc/vconsole.conf" font=''
  [[ -f $vconsole ]] && font=$(grep '^FONT=' "$vconsole" | head -n1)
  if command -v systemd-firstboot >/dev/null 2>&1; then
    sys_cmd systemd-firstboot --root="$INST_TARGET" --keymap="$language" --force ||
      die "Unable to set locale '$language' for console: $SYS_CMD_OUTPUT"
    [[ -n $font ]] && ! grep -q '^FONT=' "$vconsole" && printf '%s\n' "$font" >>"$vconsole"
  else
    mkdir -p "$INST_TARGET/etc"
    { grep -v '^KEYMAP=' "$vconsole" 2>/dev/null; printf 'KEYMAP=%s\n' "$language"; } >"$vconsole.new"
    mv "$vconsole.new" "$vconsole"
  fi

  locale_write_x11_keyboard "$language"
  info "Keyboard language for this installation is now set to: $language"
}

# localectl set-keymap also derives the X11 layout through kbd-model-map.
locale_write_x11_keyboard() {
  local keymap=$1 map=/usr/share/systemd/kbd-model-map layout model variant options
  [[ -f $map ]] || return 0
  read -r layout model variant options < <(awk -v k="$keymap" '$1 == k { print $2, $3, $4, $5; exit }' "$map")
  [[ -n $layout ]] || return 0
  [[ $model == '-' ]] && model=''
  [[ $variant == '-' ]] && variant=''
  [[ $options == '-' ]] && options=''
  local conf="$INST_TARGET/etc/X11/xorg.conf.d/00-keyboard.conf"
  mkdir -p "${conf%/*}"
  {
    printf '# Written by systemd-localed(8), read by systemd-localed and Xorg. It'"'"'s\n# probably wise not to edit this file manually. Use localectl(1) to\n# update this file.\nSection "InputClass"\n        Identifier "system-keyboard"\n        MatchIsKeyboard "on"\n        Option "XkbLayout" "%s"\n' "$layout"
    [[ -n $model ]] && printf '        Option "XkbModel" "%s"\n' "$model"
    [[ -n $variant ]] && printf '        Option "XkbVariant" "%s"\n' "$variant"
    [[ -n $options ]] && printf '        Option "XkbOptions" "%s"\n' "$options"
    printf 'EndSection\n'
  } >"$conf"
  # systemd-firstboot knows XKB too; keep vconsole.conf in sync with localectl's output.
  local vconsole="$INST_TARGET/etc/vconsole.conf"
  {
    grep -v '^XKB' "$vconsole" 2>/dev/null
    printf 'XKBLAYOUT=%s\n' "$layout"
    [[ -n $model ]] && printf 'XKBMODEL=%s\n' "$model"
    [[ -n $variant ]] && printf 'XKBVARIANT=%s\n' "$variant"
    [[ -n $options ]] && printf 'XKBOPTIONS=%s\n' "$options"
  } >"$vconsole.new"
  mv "$vconsole.new" "$vconsole"
}
