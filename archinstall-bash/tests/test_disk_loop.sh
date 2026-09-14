#!/usr/bin/env bash
# Integration test for the disk layer on a loop device. Needs root.
#
# Exercises the same path Omarchy's full-disk install takes: wipe, GPT with an
# ESP and a LUKS-encrypted btrfs partition, subvolumes @/@home/@log/@pkg,
# mount_ordered_layout, kernel parameters, then tears everything down.
#
#   sudo tests/test_disk_loop.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ $EUID -eq 0 ]] || { echo 'run as root (loop devices, cryptsetup, mount)' >&2; exit 1; }

work=$(mktemp -d)
image="$work/disk.img"
target="$work/target"
export ARCHINSTALL_LOG_DIR="$work/log"
loop=''

cleanup() {
  set +e
  [[ -d $target ]] && umount -R "$target" 2>/dev/null
  [[ -e /dev/mapper/archinstall-test-root ]] && cryptsetup close archinstall-test-root 2>/dev/null
  [[ -n $loop ]] && losetup -d "$loop" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

truncate -s 4G "$image"
loop=$(losetup --find --show --partscan "$image")
echo "loop device: $loop"

config="$work/config.json"
jq --arg dev "$loop" '
  .disk_config.device_modifications[0].device = $dev
  | .disk_config.device_modifications[0].partitions[0].size.value = (512 * 1024 * 1024)
  | .disk_config.device_modifications[0].partitions[1].start.value = (513 * 1024 * 1024)
  | .disk_config.device_modifications[0].partitions[1].size.value = (4096 - 513 - 1) * 1024 * 1024
  | .disk_config.disk_encryption.iter_time = 100
' "$here/../examples/omarchy-full-disk.json" >"$config"

# shellcheck disable=SC1091
source "$here/../lib/archinstall.sh"
sysinfo_has_uefi() { return 0; } # GPT layout regardless of the host firmware
# archinstall maps the encrypted root as /dev/mapper/root; a host that runs on
# LUKS already has one, so the test uses its own mapper names.
mapper=archinstall-test-root
part_mapper_name() { printf 'archinstall-test-%s' "$([[ $1 == "$(installer_get_root)" ]] && printf root || printf '%s' "$1")"; }

config_load "$config" "$here/../examples/omarchy-credentials.json"
config_summary

echo '== perform_filesystem_operations'
fs_perform_filesystem_operations
lsblk -o NAME,SIZE,FSTYPE,PARTTYPE,PARTUUID "$loop"

fail() { echo "FAIL: $*" >&2; exit 1; }
[[ ${PART_DEVPATH[0]} == "${loop}p1" ]] || fail "ESP node ${PART_DEVPATH[0]}"
[[ ${PART_DEVPATH[1]} == "${loop}p2" ]] || fail "root node ${PART_DEVPATH[1]}"
[[ $(lsblk -dnro FSTYPE "${loop}p1") == vfat ]] || fail 'ESP is not vfat'
[[ $(lsblk -dnro FSTYPE "${loop}p2") == crypto_LUKS ]] || fail 'root is not LUKS'
[[ $(lsblk -dnro PARTTYPE "${loop}p1") == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] || fail 'ESP type GUID'
[[ $(lsblk -dnro PARTTYPE "${loop}p2") == 4f68bce3-e8cd-4db1-96e7-fbcaf984b709 ]] || fail 'root type GUID'
[[ -n ${PART_PARTUUID[1]} && -n ${PART_UUID[1]} && ${PART_PARTN[1]} == 2 ]] || fail 'partition info not recorded'
[[ ! -e /dev/mapper/$mapper ]] || fail 'mapper left open after formatting'

echo '== mount_ordered_layout'
installer_init "$target" linux
installer_mount_ordered_layout
findmnt -R "$target"
[[ $(findmnt -no SOURCE "$target") == "/dev/mapper/${mapper}[/@]" ]] || fail "root mount: $(findmnt -no SOURCE "$target")"
[[ $(findmnt -no SOURCE "$target/home") == "/dev/mapper/${mapper}[/@home]" ]] || fail 'home subvolume'
[[ $(findmnt -no SOURCE "$target/var/log") == "/dev/mapper/${mapper}[/@log]" ]] || fail 'log subvolume'
[[ $(findmnt -no SOURCE "$target/var/cache/pacman/pkg") == "/dev/mapper/${mapper}[/@pkg]" ]] || fail 'pkg subvolume'
[[ $(findmnt -no OPTIONS "$target") == *compress=zstd* ]] || fail 'compress=zstd missing on root'
[[ $(findmnt -no SOURCE "$target/boot") == "${loop}p1" ]] || fail 'ESP not mounted'
[[ $(findmnt -no OPTIONS "$target/boot") == *fmask=0077* ]] || fail 'ESP fmask'

# The passphrase must open the volume the way a user types it at boot.
umount -R "$target"
cryptsetup close "$mapper"
printf '%s' hunter2 | cryptsetup open "${loop}p2" "$mapper" --key-file - || fail 'passphrase does not unlock the volume'
cryptsetup close "$mapper"

echo '== kernel parameters'
INST_ZRAM_ENABLED=1
params=$(installer_get_kernel_params 1)
echo "$params"
[[ $params == "cryptdevice=PARTUUID=${PART_PARTUUID[1]}:root root=/dev/mapper/root zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs" ]] || fail 'kernel parameters'

echo '== mapper collision is refused'
out=$(luks_unlock_if_needed "${loop}p1" root hunter2 2>&1) && fail 'host /dev/mapper/root was accepted for another device'
[[ $out == *'already exists'* ]] || fail "unexpected collision message: $out"

echo '== re-run wipes the previous layout'
fs_perform_filesystem_operations
[[ $(lsblk -dnro FSTYPE "${loop}p2") == crypto_LUKS ]] || fail 'second run'

echo 'all disk tests passed'
