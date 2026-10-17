#!/bin/bash
#
# #112: two identical drives render one and the same picker line - same size, same model, same
# partitions - and "/dev/sda vs /dev/sdb" is not a stable identity for the disk about to be wiped.
# The list adds each disk's serial when entries would otherwise repeat, and leaves the usual
# machine's lines as they were.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"

# shellcheck source=../../configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh
source "$LIB"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# One twin pair (sda/sdb) and one disk that is nothing like them (sdc).
cat >"$work/lsblk" <<'SH'
#!/bin/bash
device="${!#}"
case "$*" in
  *"TYPE,NAME"*)   printf 'part %s1 ext4 /mnt\n' "$device" ;;
  *"SIZE"*)        [[ $device == /dev/sdc ]] && printf '1.8T\n' || printf '465.8G\n' ;;
  *"VENDOR"*)      printf 'ATA\n' ;;
  *"MODEL"*)       [[ $device == /dev/sdc ]] && printf 'Samsung_SSD_990_PRO\n' || printf 'CT500MX500SSD1\n' ;;
  *"SERIAL"*)      printf '%s\n' "${device#/dev/}-SERIAL" ;;
esac
SH
chmod +x "$work/lsblk"
export PATH="$work:$PATH"

twins=$(printf '/dev/sda\n/dev/sdb\n' | disk_picker_options)
grep -q '\[sda-SERIAL\]' <<<"$twins" ||
  fail "the first of two identical disks shows its serial" "$twins"
grep -q '\[sdb-SERIAL\]' <<<"$twins" ||
  fail "the second of two identical disks shows its serial" "$twins"
[[ $(grep -c . <<<"$twins") == 2 ]] ||
  fail "both disks are still offered" "$twins"
pass "two identical disks are told apart by serial"

mixed=$(printf '/dev/sda\n/dev/sdc\n' | disk_picker_options)
grep -q 'SERIAL' <<<"$mixed" &&
  fail "disks that already differ keep their short line" "$mixed"
pass "distinct disks keep their short line"
