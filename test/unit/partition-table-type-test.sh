#!/bin/bash
#
# The free-space install decides from the disk's partition table type whether
# it has a table at all. With none, run_partition_decide plans the whole disk
# and runs mklabel gpt, which replaces every partition on it. That type came
# from lsblk alone, which answers from udev's database: a disk udev has not
# finished probing has no PTTYPE there, and udev and blkid both skip the table
# of a disk that carries a stale RAID member signature. partition_table_type()
# asks parted, which reads the table itself, and keeps blkid's probe and lsblk
# as witnesses.
#
# blkid and parted read image files directly, so this needs no root, no loop
# devices and no real disk.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"

for tool in parted blkid; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool is not installed"
    exit 0
  fi
done

# shellcheck source=../configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh
source "$LIB"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s: expected "%s", got "%s"\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# udev's view of the disk. LSBLK_PTTYPE unset: udev has caught up and answers
# what is on the disk; set (even empty): udev answers that.
lsblk() {
  if [[ "$1 $2" == "-dno PTTYPE" ]]; then
    if [[ -n ${LSBLK_PTTYPE+set} ]]; then
      printf '%s\n' "$LSBLK_PTTYPE"
    else
      blkid -p -s PTTYPE -o value "${!#}" 2>/dev/null || true
    fi
    return 0
  fi
  command lsblk "$@"
}

# blkid's probe. BLKID_PTTYPE unset: what is on the disk; set (even empty): that,
# as for a disk whose stale RAID signature makes libblkid skip the table.
blkid() {
  if [[ -n ${BLKID_PTTYPE+set} && "$1 $2 $3" == "-p -s PTTYPE" ]]; then
    printf '%s\n' "$BLKID_PTTYPE"
    [[ -n $BLKID_PTTYPE ]]
    return
  fi
  command blkid "$@"
}

new_disk() {
  disk=$(mktemp "$WORK/disk-XXXXXX.img")
  truncate -s "$1" "$disk"
}

echo "==> a disk with a GPT and partitions"
new_disk 8G
parted --script "$disk" mklabel gpt mkpart esp fat32 1MiB 2049MiB mkpart root btrfs 2050MiB 6000MiB
check "udev up to date" "gpt" "$(partition_table_type "$disk")"
check "udev reports no table yet" "gpt" "$(LSBLK_PTTYPE='' partition_table_type "$disk")"
check "neither udev nor blkid reports one (stale RAID signature)" "gpt" \
  "$(LSBLK_PTTYPE='' BLKID_PTTYPE='' partition_table_type "$disk")"

echo "==> a disk with an MBR"
new_disk 2G
parted --script "$disk" mklabel msdos mkpart primary ext4 1MiB 1000MiB
check "udev reports no table yet" "msdos" "$(LSBLK_PTTYPE='' partition_table_type "$disk")"

echo "==> a blank disk"
new_disk 2G
check "no table" "" "$(partition_table_type "$disk")"

echo "==> blkid and lsblk are still witnesses when parted finds nothing"
new_disk 2G
check "blkid knows a table parted does not" "PMBR" "$(BLKID_PTTYPE=PMBR partition_table_type "$disk")"
check "udev knows a table neither probe does" "gpt" "$(LSBLK_PTTYPE=gpt partition_table_type "$disk")"

echo "==> the configurator reads the type only through partition_table_type"
# Checked by text: the configurator cannot be sourced. Each PTTYPE read of its
# own is one more place where udev's answer alone decides.
check "lsblk PTTYPE reads left in the configurator" "0" \
  "$(grep -v '^\s*#' "$CONFIGURATOR" | grep -c 'PTTYPE')"
check "partition_table_type calls in the configurator" "2" \
  "$(grep -v '^\s*#' "$CONFIGURATOR" | grep -c 'partition_table_type "\$disk"')"

if ((failures > 0)); then
  echo "FAIL: $failures check(s) failed"
  exit 1
fi
echo "ok: the partition table type comes from the disk, not udev's database"
