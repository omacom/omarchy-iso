#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/install/provisioning"
cat > "$work/install/provisioning/setup-form.sh" <<'FORM'
OMARCHY_KEYBOARD_LAYOUTS=$'Chinese (Simplified, Pinyin)|us|pinyin
English (US)|us
Japanese|jp106|mozc'
FORM
export OMARCHY_PATH="$work"
eval "$(sed -n '/^select_keyboard() {$/,/^}$/p' "$ROOT/bin/omarchy-iso-test")"
press() { pressed+=("$1"); }
sleep() { :; }

pressed=()
select_keyboard "Japanese"
[[ ${pressed[*]} == "down" ]]
pressed=()
select_keyboard "Chinese (Simplified, Pinyin)"
[[ ${pressed[*]} == "up" ]]
pressed=()
select_keyboard "English (US)"
(( ${#pressed[@]} == 0 ))
if (set -e; select_keyboard "Missing") 2>"$work/error"; then
  echo "Unknown keyboard unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'Keyboard choice is absent' "$work/error"
echo "ok - VM keyboard choices are relative to the default and reject absent rows"
