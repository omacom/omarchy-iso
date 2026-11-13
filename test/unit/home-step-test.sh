#!/bin/bash
#
# The Home step: where home lives when the machine has another disk. Its rows
# come from the shared helper's scan (omarchy's home-drive.sh), which decides
# what may be adopted or erased; this side turns them into the menu. gum
# highlights the first row, so the first row is what Enter picks: an existing
# home of the user when one was found, else home on the install disk, and
# never a row that erases a disk. With nothing to choose (no other disk) the
# step prints no rows and is skipped. The step's placement in the configurator
# is checked by text below.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SHARE="$ROOT/configs/airootfs/usr/share/omarchy-iso"
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"

# shellcheck source=../configs/airootfs/usr/share/omarchy-iso/i18n.sh
source "$SHARE/i18n.sh"
i18n_load en
# The configurator runs its screens when sourced, so take the functions out of it.
for name in home_size home_step_rows home_step_hints home_confirm_lines home_config_json home_step_needed; do
  eval "$(sed -n "/^$name() {/,/^}/p" "$CONFIGURATOR")"
done

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

# Scan rows as home_drive_scan prints them, and the order home_drive_choices
# puts them in (adoptable, the install disk, locked, erasable).
row() { local IFS=$'\t'; printf '%s\n' "$*"; }
SCAN=$(
  row adoptable home /dev/vdb1 xfs u1 "" "" 1000 1000 1395864371200 /dev/vdb 0 sam ""
  row locked home /dev/vdc1 crypto_LUKS "" l2 "" "" "" "" /dev/vdc 0 "" wrong-passphrase
  row erasable disk /dev/nvme2n1 "" "" "" "" "" "" "" /dev/nvme2n1 0 "" ""
  row refused home /dev/vdd1 ext4 u4 "" "" 999 999 4096 /dev/vdd 0 "" uid-below-1000
)
CHOICES=$'adopt\t1\ndisk\t0\nlocked\t2\nfresh\t3'

rows=$(home_step_rows "$SCAN" "$CHOICES" /dev/vda kim)
label() { sed -n "${1}p" <<<"$rows" | cut -f1; }
value() { sed -n "${1}p" <<<"$rows" | cut -f2; }

echo "==> the menu"
check "an existing home comes first, so Enter adopts it" \
  "Existing home for kim on /dev/vdb1 (xfs, 1.3T)|adopt:1" "$(label 1)|$(value 1)"
check "home on the install disk comes next" "On /dev/vda|disk" "$(label 2)|$(value 2)"
check "a locked drive asks for its passphrase" \
  "Encrypted /dev/vdc1 (enter its passphrase)|locked:2" "$(label 3)|$(value 3)"
check "an erasable disk says it erases" "Use /dev/nvme2n1 for home (erases it)|fresh:3" "$(label 4)|$(value 4)"

rows=$(home_step_rows "$SCAN" $'disk\t0\nfresh\t3' /dev/vda kim)
check "without an existing home, Enter keeps home on the install disk" "disk" "$(value 1)"
check "no erase row is ever first" "fresh:3" "$(value 2)"

rows=$(home_step_rows "" $'disk\t0' /dev/vda kim)
check "with only the install disk there is nothing to ask" "" "$rows"

# The helper's fifteenth field, dir: the user's folder sits at home/kim inside
# another system's root filesystem, or inside its btrfs root subvolume @.
IN_SYSTEM=$(
  row adoptable home /dev/vdb2 ext4 u2 "" "" 1000 1000 1395864371200 /dev/vdb 0 "" "" home
  row adoptable home /dev/vdc2 btrfs u3 "" @ 1000 1000 4096 /dev/vdc 0 "" "" home
)
rows=$(home_step_rows "$IN_SYSTEM" $'adopt\t1\nadopt\t2\ndisk\t0' /dev/vda kim)
check "a home inside another system says it is inside that system" \
  "Existing home for kim inside the system on /dev/vdb2 (ext4, 1.3T)|adopt:1" "$(label 1)|$(value 1)"
check "and names the root subvolume it is in" \
  "Existing home for kim inside the system on /dev/vdc2 (btrfs @, 4.0K)|adopt:2" "$(label 2)|$(value 2)"

echo "==> the hints"
hints=$(home_step_hints "$SCAN" kim)
check "other homes beside the user's are named as left untouched" \
  "Also on this drive: sam (left untouched)" "$(sed -n 1p <<<"$hints")"
check "a refused home says why" \
  "Home for kim on /dev/vdd1 can't be used: it belongs to a system account" "$(sed -n 2p <<<"$hints")"

hints=$(home_step_hints "$SCAN" kim /dev/vdc1)
check "a passphrase that opened nothing says so" \
  "That passphrase doesn't unlock /dev/vdc1" "$(sed -n 2p <<<"$hints")"

echo "==> the confirmation"
say() { shift $(($# - 1)); printf '%s\n' "$1"; }
home_mode=fresh home_row=$(row erasable disk /dev/vdb "" "" "" "" "" "" "" /dev/vdb 0 "" "")
home_scan_result=$(row adoptable home /dev/vdb1 xfs u1 "" "" 1000 1000 4096 /dev/vdb 0 "" "")
check "erasing a disk that holds the user's home says so" \
  $'/dev/vdb will also be erased for your home.\n/dev/vdb holds your existing home, which will be lost.' "$(home_confirm_lines encrypted)"
home_scan_result=""
check "erasing a disk without a home of theirs says only that" "/dev/vdb will also be erased for your home." "$(home_confirm_lines encrypted)"

home_mode=adopt home_row=$(row adoptable home /dev/vdb1 xfs u1 "" "" 1000 1000 4096 /dev/vdb 0 "" "")
check "an adopted home is kept as it is" "Your existing home on /dev/vdb1 is kept as it is." \
  "$(home_confirm_lines unencrypted)"
home_row=$(sed -n 1p <<<"$IN_SYSTEM")
check "a home inside another system is kept, and the rest of that system is not touched" \
  "Your home inside the system on /dev/vdb2 is kept as it is; the rest of that system is not touched." \
  "$(home_confirm_lines unencrypted)"

echo "==> the config"
home_mode=adopt home_row=$(row adoptable home /dev/vdb1 xfs u1 "" "" 1000 1000 4096 /dev/vdb 0 "" "")
check "an adopted home's config says it is the filesystem itself" \
  '"home": {"mode":"adopt","device":"/dev/vdb1","uuid":"u1","fstype":"xfs","subvol":"","luks_uuid":"","uid":1000,"gid":1000,"dir":""},' \
  "$(home_config_json)"
home_row=$(sed -n 2p <<<"$IN_SYSTEM")
check "a home inside another system's config names its folder" \
  '"home": {"mode":"adopt","device":"/dev/vdc2","uuid":"u3","fstype":"btrfs","subvol":"@","luks_uuid":"","uid":1000,"gid":1000,"dir":"home"},' \
  "$(home_config_json)"
home_mode=fresh home_row=$(row erasable disk /dev/vdb "" "" "" "" "" "" "" /dev/vdb 0 "" "")
check "a fresh home's config names only the disk" '"home": {"mode":"fresh","disk":"/dev/vdb"},' "$(home_config_json)"

echo "==> when to ask"
home_step_needed $'/dev/vda' /dev/vda && r=yes || r=no
check "a machine whose only disk is the install disk is not scanned" "no" "$r"
home_step_needed $'/dev/vda\n/dev/vdb' /dev/vda && r=yes || r=no
check "a machine with another disk is scanned" "yes" "$r"

echo "==> asking"
# home_step against a stand-in gum: each call takes the next scan, choice or
# typed passphrase from a queue, and every scan records the secrets it got.
eval "$(sed -n "/^home_step() {/,/^}/p" "$CONFIGURATOR")"
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
pop() { head -n1 "$STUB/$1"; sed -i 1d "$STUB/$1"; }
gum() {
  case $1 in
    spin)
      [[ -e $STUB/first-secret ]] || printf '%s' "$HOME_DRIVE_SECRET" >"$STUB/first-secret"
      printf '%s' "$HOME_DRIVE_SECRET" >"$STUB/last-secret"
      printf '%s\n' "$SCAN"
      return "$(pop spin-status)"
      ;;
    choose)
      echo choose >>"$STUB/asked"
      # Esc once the queue is empty, so a step that asks again ends.
      [[ -s $STUB/choices ]] || return "$OMARCHY_FORM_BACK"
      pop choices
      ;;
    input) pop passphrases ;;
  esac
}
clear_logo() { :; }
step() { :; }
say() { shift $(($# - 1)); printf '%s\n' "$1" >>"$STUB/said"; }
abort() { echo aborted >>"$STUB/said"; return 1; }
get_root_disk() { :; }
home_drive_choices() { printf '%s\n' "$CHOICES"; }
home_drive_scan_cleanup() { echo cleaned >>"$STUB/cleaned"; }
home_drive_luks_passphrase() { :; }
available_disks=$'/dev/vda\n/dev/vdb' disk=/dev/vda username=kim password=pw OMARCHY_FORM_BACK=99 HOME_DRIVE=/dev/null

printf '0\n0\n0\n' >"$STUB/spin-status"
printf 'locked:2\nlocked:2\ndisk\n' >"$STUB/choices"
printf 'first\nsecond\n' >"$STUB/passphrases"
home_password=""
home_step
check "passphrases typed for locked drives are all kept" $'first\nsecond' "$home_password"
check "the first scan tries the password" "pw" "$(<"$STUB/first-secret")"
check "the last scan tries every passphrase typed too" $'pw\nfirst\nsecond' "$(<"$STUB/last-secret")"
check "a passphrase that opened nothing is told" "yes" \
  "$(grep -qx "That passphrase doesn't unlock /dev/vdc1" "$STUB/said" && echo yes || echo no)"

rm -f "$STUB"/*
printf '130\n' >"$STUB/spin-status"
home_mode=adopt home_row=x
home_step && r=$? || r=$?
check "an interrupted scan keeps home on the install disk" "0|disk|" "$r|$home_mode|$home_row"
check "and asks nothing from what it printed" "no" "$([[ -e $STUB/asked ]] && echo yes || echo no)"
check "and lets go of what it left open" "cleaned" "$(cat "$STUB/cleaned" 2>/dev/null)"

echo "==> the configurator"
select_installation=$(sed -n '/^select_installation() {/,/^}/p' "$CONFIGURATOR")
check "the Home step runs after the install mode is chosen" "yes" \
  "$(grep -q 'home_step' <<<"$select_installation" && echo yes || echo no)"
deferred=$(sed -n '/^if \$defer_provisioning; then/,/^else/p' "$CONFIGURATOR")
check "deferred provisioning never asks (first-boot setup does)" "no" \
  "$(grep -q 'home_step' <<<"$deferred" && echo yes || echo no)"
check "both configurations (full disk, free space) carry the home choice" "2" \
  "$(grep -c '^ *\$home_json$' "$CONFIGURATOR")"

if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
