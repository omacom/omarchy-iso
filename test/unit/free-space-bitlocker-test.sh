#!/bin/bash
#
# BitLocker encrypts a partition, not the disk, and the free-space install only
# writes to free space and its own ESP. Seen on an ASUS Zenbook UX3402VA with
# Debian and an encrypted Windows side by side and 93 GiB free: the installer
# refused the disk, though nothing it would write touched Windows. A BitLocker
# partition now gets a warning and a choice, and the scan names every one.
#
# The configurator runs its screens when sourced, so take the functions out of it.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"

failures=0
check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s:\n    expected: %s\n    got:      %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

eval "$(sed -n '/^detect_bitlocker() {$/,/^}$/p;/^confirm_bitlocker_alongside() {$/,/^}$/p' "$CONFIGURATOR")"

disk=/dev/fake
encrypted=""
confirm=0
lsblk() { printf '/dev/fake disk\n/dev/fake1 part\n/dev/fake2 part\n/dev/fake3 part\n'; }
dd() {
  local p=${1#if=}
  [[ " $encrypted " == *" $p "* ]] && printf -- '-FVE-FS-' || printf 'NTFS    '
}
t() { printf '%s %s\n' "$1" "${2:-}"; }
say() { [[ $1 == --foreground ]] && shift 2; printf '%s\n' "$1"; }
gum() { echo "gum $*" >>"$screen"; return "$confirm"; }

screen=$(mktemp)
trap 'rm -f "$screen"' EXIT

check "no BitLocker lists nothing" "" "$(detect_bitlocker)"

encrypted="/dev/fake1 /dev/fake3"
check "every BitLocker partition is listed" $'/dev/fake1\n/dev/fake3' "$(detect_bitlocker)"

encrypted=""
confirm_bitlocker_alongside >"$screen"
check "a disk without BitLocker goes straight on" "0 " "$? $(cat "$screen")"

encrypted="/dev/fake1 /dev/fake3"
confirm=0
confirm_bitlocker_alongside >"$screen"
check "confirming carries on with the install" 0 "$?"
check "the warning names each partition" 2 "$(grep -c '^bitlocker.found /dev/fake[13]' "$screen")"
check "the warning mentions the recovery key" 1 "$(grep -c '^bitlocker.recovery' "$screen")"

confirm=1
confirm_bitlocker_alongside >"$screen"
check "declining goes back to the mode picker" 1 "$?"

if ! grep -q '^  confirm_bitlocker_alongside || return 1$' "$CONFIGURATOR"; then
  printf '  FAIL run_partition_decide no longer goes back when the warning is declined\n'
  failures=$((failures + 1))
fi

((failures == 0)) || exit 1
echo "ok: BitLocker warns, lists every partition, and blocks nothing"
