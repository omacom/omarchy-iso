#!/bin/bash
#
# The free-space install makes its btrfs in the configurator, and the root
# image is written over it right after. mkfs.btrfs discards the whole partition
# first unless given -K, which through dm-crypt costs seconds on a 1 TB SSD
# before the install timer starts (798 GiB on a 990 PRO). The
# full-disk path passes -K through archinstall_adapter; assert this one does.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
configurator="$ROOT/configs/airootfs/root/configurator"

# Non-comment lines only: the flag is explained in prose next to the call.
calls=$(grep -vE '^\s*#' "$configurator" | grep -E '\bmkfs\.btrfs\b' || true)
[[ $(grep -c . <<<"$calls") -eq 1 ]] ||
  { echo "expected exactly one mkfs.btrfs call in the configurator, found: ${calls:-none}"; exit 1; }
grep -qE 'mkfs\.btrfs\s+(-\S+\s+)*-K\b' <<<"$calls" ||
  { echo "the free-space mkfs.btrfs runs without -K and TRIMs the whole partition: $calls"; exit 1; }

echo "ok: the free-space mkfs.btrfs skips the whole-device TRIM"

# With -K, the raw root partition is discarded instead: after wipefs clears it
# and before LUKS, mkfs or the image write it (omarchy-discard-partition).
order=$(grep -nvE '^\s*#' "$configurator" |
  grep -E 'wipefs -af "\$root_partition_device"|omarchy-discard-partition "\$root_partition_device"|omarchy-luks-calibrate format|mkfs\.btrfs' |
  sed -E 's/^([0-9]+):.*(wipefs|omarchy-discard-partition|omarchy-luks-calibrate|mkfs\.btrfs).*/\2/' | paste -sd' ' -)
[[ $order == "wipefs omarchy-discard-partition omarchy-luks-calibrate mkfs.btrfs" ]] ||
  { echo "the free-space root must be wiped, discarded, then encrypted and formatted; found: ${order:-nothing}"; exit 1; }

echo "ok: the free-space root partition is discarded after wipefs and before LUKS and mkfs"
