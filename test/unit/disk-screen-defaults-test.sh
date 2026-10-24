#!/bin/bash
#
# The disk and mode screens are gum lists, and gum highlights the first entry,
# so the first entry is the default a user confirms with Enter. Seen on an MSI
# desktop with a GL.iNet Comet KVM attached: the disk list opened on the
# Comet's 5.7 GB USB storage and offered its 0-byte optical drive, and on the
# disk that held the owner's daily install the mode list opened on "Full disk
# install".
#
# install_disk_candidates() and install_mode_choices() decide those lists, and
# the configurator calls them (checked by text below; it cannot be sourced).

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"

# shellcheck source=../configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh
source "$LIB"

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

# lsblk -dbpno NAME,TYPE,SIZE,RM,TRAN on that desktop, as it printed it: the
# boot stick, the Comet's storage and optical drive, zram, two NVMe SSDs.
LSBLK_DISKS=$'/dev/sda     disk  256087425024 1 usb
/dev/sdb     disk    6156156928 1 usb
/dev/sdc     disk             0 1 usb
/dev/zram0   disk   33249296384 0
/dev/nvme1n1 disk 1000204886016 0 nvme
/dev/nvme0n1 disk 1000204886016 0 nvme'
lsblk() {
  if [[ "$*" == "-dbpno NAME,TYPE,SIZE,RM,TRAN" ]]; then
    printf '%s\n' "$LSBLK_DISKS"
    return 0
  fi
  command lsblk "$@"
}

# /sys/block/<disk>/device/type, which an MMC card has: SD or MMC.
SYSFS_BLOCK=$(mktemp -d)
trap 'rm -rf "$SYSFS_BLOCK"' EXIT
card() { mkdir -p "$SYSFS_BLOCK/$1/device"; printf '%s\n' "$2" >"$SYSFS_BLOCK/$1/device/type"; }

list() { tr '\n' ' ' | sed 's/ $//'; }

echo "==> the disk list"
check "internal disks first, no 0-byte drive, no zram, no boot medium" \
  "/dev/nvme1n1 /dev/nvme0n1 /dev/sdb" "$(install_disk_candidates /dev/sda | list)"
check "with no boot medium known" \
  "/dev/nvme1n1 /dev/nvme0n1 /dev/sda /dev/sdb" "$(install_disk_candidates "" | list)"

LSBLK_DISKS=$'/dev/sda disk 512110190592 0 sata
/dev/sdb disk 64023257088 1 usb
/dev/vda disk 34359738368 0 virtio'
check "a SATA disk before a USB stick; a virtio disk counts as internal" \
  "/dev/sda /dev/vda /dev/sdb" "$(install_disk_candidates "" | list)"

LSBLK_DISKS=$'/dev/mmcblk0 disk 31268536320 0 mmc
/dev/sda disk 128035676160 0 usb'
card mmcblk0 MMC
check "a USB disk that does not say it is removable is still external" \
  "/dev/mmcblk0 /dev/sda" "$(install_disk_candidates "" | list)"

# An SD card in a PCIe reader reports RM 0 and TRAN mmc, like an eMMC, and
# sorts before NVMe (major 179 against 259).
LSBLK_DISKS=$'/dev/mmcblk0 disk 63864569856 0 mmc
/dev/mmcblk1 disk 31268536320 0 mmc
/dev/mmcblk1boot0 disk 4194304 0 mmc
/dev/mmcblk1boot1 disk 4194304 0 mmc
/dev/nvme0n1 disk 512110190592 0 nvme'
card mmcblk0 SD
card mmcblk1 MMC
check "an SD card goes after the internal disks; an eMMC's boot areas are not offered" \
  "/dev/mmcblk1 /dev/nvme0n1 /dev/mmcblk0" "$(install_disk_candidates "" | list)"

echo "==> the mode list"
check "a disk with partitions and room: free space first" \
  "free_space|full_disk|other_disk" \
  "$(install_mode_choices true 3 | paste -sd'|' -)"
check "an empty disk with room: full disk first" \
  "full_disk|free_space|other_disk" \
  "$(install_mode_choices true 0 | paste -sd'|' -)"
check "no free-space mode on offer (BIOS, or no room)" \
  "full_disk|other_disk" \
  "$(install_mode_choices false 3 | paste -sd'|' -)"

echo "==> the configurator calls them"
check "disk list from install_disk_candidates" "1" \
  "$(grep -v '^\s*#' "$CONFIGURATOR" | grep -c 'install_disk_candidates "\$exclude_disk"')"
check "mode list from install_mode_choices" "1" \
  "$(grep -v '^\s*#' "$CONFIGURATOR" | grep -c 'install_mode_choices "\$free_space_offered"')"

if ((failures > 0)); then
  echo "FAIL: $failures check(s) failed"
  exit 1
fi
echo "ok: the disk and mode screens open on a safe default"
