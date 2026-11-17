#!/bin/bash
#
# The configurator mounts the ESP it has just formatted, and probes vfat
# partitions for a Windows ESP. Both mounts name their type. Untyped, mount
# takes the type from udev's database, which records a new filesystem a few
# milliseconds after mkfs.fat closes the device; until then mount walks
# /proc/filesystems, and on a fresh live boot (no vfat module loaded yet) that
# ends at squashfs: "Can't find a SQUASHFS superblock". Measured in VMs: 38 of
# 70 free-space ESP mounts failed untyped, 0 of 50 typed.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
configurator="$ROOT/configs/airootfs/root/configurator"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -Fq 'mount -t vfat "$efi_dev"' "$configurator" || fail "the new ESP is mounted without its type"
grep -Fq 'mount -t vfat -o ro "$p"' "$configurator" || fail "the Windows ESP probe mounts without a type"
if grep -nE '(^|[^-])mount (-o [^ ]+ )?"\$(efi_dev|p)"' "$configurator"; then
  fail "an ESP is mounted without its type"
fi
echo "ok - every ESP mount in the configurator names vfat"
