# Installer strings, shared by the configurator and the install dashboard.
#
# Catalogs are i18n/<code>.json beside this file, one per language the console
# font can draw, keyed like Omarchy's own catalogs with %1-style placeholders.
# English fills any key a translation lacks. Sourced, not executed.

OMARCHY_ISO_SHARE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OMARCHY_ISO_I18N_DIR=${OMARCHY_ISO_I18N_DIR:-$OMARCHY_ISO_SHARE/i18n}

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
  [[ $1 =~ ^[a-z]{2,3}(-[A-Z]{2})?$ && -r $OMARCHY_ISO_I18N_DIR/$1.json ]] || return 1
  # CJK is beyond any console font: its catalog only applies inside kmscon,
  # which draws with real fonts. On the plain VT the language stays English.
  i18n_needs_kmscon "$1" && [[ ${OMARCHY_ISO_KMSCON:-} != 1 ]] && return 1
  return 0
}

# Languages whose script the Linux console cannot draw and that the ISO has a
# catalog for; picking one moves the installer into kmscon (omarchy-iso-kmscon).
# Without a catalog the installer would stay English there too.
i18n_needs_kmscon() {
  [[ ($1 == zh-* || $1 == ja || $1 == ko) && -r $OMARCHY_ISO_I18N_DIR/$1.json ]]
}

# Terminal columns a string takes: CJK and fullwidth characters take two.
# ${#s} counts characters, which centers Chinese text half a string too far right.
display_width() {
  local text=$1 narrow wide
  # Escapes, not literal characters: editors may normalize a literal U+F900
  # into U+8C48, which would double everything up to U+FAFF.
  printf -v narrow '[^\u1100-\u115F\u2E80-\u3029\u3030-\u303E\u3040-\u3098\u309B-\uA4CF\uAC00-\uD7A3\uF900-\uFAFF\uFE10-\uFE19\uFE30-\uFE4F\uFF00-\uFF60\uFFE0-\uFFE6\U0001F300-\U0001F64F\U0001F900-\U0001F9FF\U00020000-\U0003FFFD]'
  wide=${text//$narrow/}
  printf '%s' $((${#text} + ${#wide}))
}

# The kernel's console fonts carry only the IBM PC character set, so a Linux VT
# gets Terminus, patched for the logo, at the size the kernel picked. Nothing
# here may fail the caller, which can be running under set -euo pipefail.
i18n_console_font() {
  local tty=$1 height terminus font=${OMARCHY_ISO_CONSOLE_FONT:-/run/omarchy-iso/console.psf}
  [[ $tty == /dev/tty[0-9]* ]] || return 0

  # The bundled runtime's own routine, when it ships one: first-boot setup
  # draws with the same file.
  if [[ -r $OMARCHY_ISO_SHARE/console-font.sh ]]; then
    source "$OMARCHY_ISO_SHARE/console-font.sh"
    omarchy_console_font "$tty" || true
    return 0
  fi

  if [[ ! -s $font ]]; then
    height=$(showconsolefont -i -C "$tty" 2>/dev/null | sed -n 's/^[0-9]*x\([0-9]*\)x[0-9]*$/\1/p') || height=16
    terminus=/usr/share/kbd/consolefonts/ter-v16b.psf.gz
    (( ${height:-16} >= 32 )) && terminus=/usr/share/kbd/consolefonts/ter-v32b.psf.gz
    mkdir -p "$(dirname "$font")" 2>/dev/null || return 0
    python3 "$OMARCHY_ISO_SHARE/console-font.py" "$terminus" "$font" 2>/dev/null || return 0
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
