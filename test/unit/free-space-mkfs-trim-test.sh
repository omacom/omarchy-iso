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
