#!/bin/bash
#
# Every installer text needs an OMARCHY_ZH entry, or a Chinese install shows it in English.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SETUP_FORM="${OMARCHY_SOURCE:-$ROOT/../omarchy}/install/provisioning/setup-form.sh"

fail() {
  printf 'not ok - %s\n' "$1"
  [[ -z ${2:-} ]] || printf '%s\n' "$2" | sed 's/^/# /'
  exit 1
}

if [[ ! -r $SETUP_FORM ]]; then
  printf 'ok - # skip the setup form is not checked out next to this repo (set OMARCHY_SOURCE)\n'
  exit 0
fi

source "$SETUP_FORM"
for file in configs/airootfs/root/configurator configs/airootfs/usr/local/bin/omarchy-install-dashboard; do
  eval "$(sed -n '/^OMARCHY_ZH+=(/,/^)/p' "$ROOT/$file")"
done

mapfile -t texts < <(
  grep -ho 'omarchy_text "[^"$]*"' "$ROOT/configs/airootfs/root/configurator" "$ROOT/configs/airootfs/usr/local/bin/omarchy-install-dashboard" |
    sed 's/^omarchy_text "//; s/"$//' | sort -u
)
((${#texts[@]} > 50)) || fail "the installer routes its text through omarchy_text" "found ${#texts[@]}"
for text in "${texts[@]}"; do
  [[ -n ${OMARCHY_ZH[$text]:-} ]] || fail "every installer text has a Chinese entry" "missing: $text"
done
printf 'ok - every installer and dashboard text has a Chinese entry\n'

for action in "View full log" "Drop to shell" "Reboot" "Power off" "Upload log for support"; do
  [[ -n ${OMARCHY_ZH[$action]:-} ]] || fail "labels passed through variables have Chinese entries" "missing: $action"
done
printf 'ok - labels passed through variables have Chinese entries\n'

mapfile -t diagnosis < <(grep -x ' *echo "[^"$]*"' "$ROOT/configs/airootfs/usr/local/bin/omarchy-install-diagnose-media" | sed 's/^ *echo "//; s/"$//')
((${#diagnosis[@]} >= 10)) || fail "the media diagnosis sentences are found" "found ${#diagnosis[@]}"
for line in "${diagnosis[@]}"; do
  [[ -n ${OMARCHY_ZH[$line]:-} ]] || fail "every media diagnosis sentence has a Chinese entry" "missing: $line"
done
printf 'ok - every media diagnosis sentence has a Chinese entry\n'

[[ $(OMARCHY_INSTALL_LANG=zh omarchy_text "Confirm overwriting %s" /dev/vda) == "确认覆盖 /dev/vda" ]] ||
  fail "Chinese text keeps its printf arguments"
[[ $(omarchy_text "Confirm overwriting %s" /dev/vda) == "Confirm overwriting /dev/vda" ]] ||
  fail "English stays the default"
printf 'ok - omarchy_text formats Chinese and English alike\n'
