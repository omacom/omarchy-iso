# Installer strings, shared by the configurator and the install dashboard.
#
# Catalogs are i18n/<code>.json beside this file, one per language the console
# font can draw, keyed like Omarchy's own catalogs with %1-style placeholders.
# English fills any key a translation lacks. Sourced, not executed.

OMARCHY_ISO_SHARE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OMARCHY_ISO_I18N_DIR=${OMARCHY_ISO_I18N_DIR:-$OMARCHY_ISO_SHARE/i18n}
# The boot logo's layout, for its font rule (i18n_console_font).
# shellcheck source=/dev/null
[[ -r $OMARCHY_ISO_SHARE/console-logo.sh ]] && source "$OMARCHY_ISO_SHARE/console-logo.sh"

declare -gA OMARCHY_ISO_TEXT=()

i18n_load() {
  local code=en file key value
  i18n_translated "${1:-}" && code=$1

  OMARCHY_ISO_TEXT=()
  for file in "$OMARCHY_ISO_I18N_DIR/en.json" "$OMARCHY_ISO_I18N_DIR/$code.json"; do
    [[ -r $file ]] || continue
    while IFS=$'\t' read -r key value; do
      OMARCHY_ISO_TEXT[$key]=$value
    done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' "$file")
  done

}

i18n_translated() {
  [[ $1 =~ ^[a-z]{2,3}(-[A-Z]{2})?$ && -r $OMARCHY_ISO_I18N_DIR/$1.json ]]
}

# The kernel's console fonts carry only the IBM PC character set, so a Linux VT
# gets Terminus, patched for the logo. On a framebuffer, at the size the boot
# logo was laid out in (omarchy_console_font_size, console-logo.sh), so the
# greeter draws over the logo in place; on the VGA text console, at the size
# the kernel picked. Nothing here may fail the caller, which can be running
# under set -euo pipefail.
i18n_console_font() {
  local tty=$1 height size=16 font=${OMARCHY_ISO_CONSOLE_FONT:-}
  [[ $tty == /dev/tty[0-9]* ]] || return 0

  if [[ -e ${OMARCHY_FB:-/sys/class/graphics/fb0} ]] && declare -F omarchy_console_font_size >/dev/null; then
    size=$(omarchy_console_font_size) || size=16
  else
    height=$(showconsolefont -i -C "$tty" 2>/dev/null | sed -n 's/^[0-9]*x\([0-9]*\)x[0-9]*$/\1/p') || height=16
    (( ${height:-16} >= 32 )) && size=32
  fi
  if [[ -z $font ]]; then
    # customize_airootfs.sh builds both sizes into the image: starting Python
    # for console-font.py on the live medium cost 0.6 s on the usb2 boot
    # benchmark, with the verify units sharing the stick fairly. An image
    # without them generates the font once, into /run.
    font=$OMARCHY_ISO_SHARE/console-$size.psf
    [[ -s $font ]] || font=/run/omarchy-iso/console-$size.psf
  fi
  if [[ ! -s $font ]]; then
    mkdir -p "$(dirname "$font")" 2>/dev/null || return 0
    python3 "$OMARCHY_ISO_SHARE/console-font.py" "/usr/share/kbd/consolefonts/ter-v${size}b.psf.gz" "$font" 2>/dev/null || return 0
  fi
  setfont -C "$tty" "$font" 2>/dev/null || true
}

# t <key> [args...]: the string in the loaded language, %1.. filled from args.
t() {
  local text=${OMARCHY_ISO_TEXT[$1]-$1} i=1 arg
  shift
  for arg in "$@"; do
    text=${text//"%$i"/"$arg"}
    i=$((i + 1))
  done
  printf '%s' "$text"
}
