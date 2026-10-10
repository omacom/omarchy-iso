#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

eval "$(sed -n '/^prepare_console_keyboard() {$/,/^}$/p' "$ROOT/bin/omarchy-iso-test")"
type_text() { printf 'text:%s\n' "$1" >> "$work/events"; }
press() { printf 'press:%s\n' "$1" >> "$work/events"; }
sleep() { :; }
GUEST_PASSWORD=omarchy
KEYBOARD_LABEL=Japanese
prepare_console_keyboard
expected=$'text:sudo -k loadkeys us\npress:ret\ntext:omarchy\npress:ret'
[[ $(cat "$work/events") == "$expected" ]]
for KEYBOARD_LABEL in 'English (US)' 'Japanese (US keyboard)' Korean; do
  : > "$work/events"
  prepare_console_keyboard
  [[ ! -s $work/events ]]
done
echo 'ok - Japanese console bootstrap uses the virtual keyboard map; other layouts are untouched'

eval "$(sed -n '/^acceptance_phase() {$/,/^}$/p' "$ROOT/bin/omarchy-iso-test")"
log() { :; }
qemu-img() { :; }
start_vm() { echo start >> "$work/events"; }
establish_session() { echo session >> "$work/events"; }
ssh_session() { printf '%s\n' "$1" >> "$work/events"; }
sync_omarchy() { echo sync >> "$work/events"; }
shortcut_smoke_phase() { echo shortcuts >> "$work/events"; }
ssh_guest() { :; }
capture_console() { :; }
BASE_DISK="$work/base"
RUN_DIR="$work"
SYNC_ALL=false
: > "$work/events"
acceptance_phase >/dev/null 2>&1
expected=$'start\nsession\nomarchy-toggle-idle stay-awake\nsync\nshortcuts'
[[ $(cat "$work/events") == "$expected" ]]
echo 'ok - acceptance keeps the VM awake before shortcuts, CLI, and graphical checks'

ssh_session() { printf '%s\n' "$1" >> "$work/events"; return 1; }
: > "$work/events"
if acceptance_phase >/dev/null 2>&1; then
  echo 'Acceptance unexpectedly continued without idle inhibition' >&2
  exit 1
fi
[[ $(cat "$work/events") == $'start\nsession\nomarchy-toggle-idle stay-awake' ]]
echo 'ok - acceptance fails before further checks when the VM cannot stay awake'
