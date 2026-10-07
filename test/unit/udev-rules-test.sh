#!/bin/bash
#
# The udev rules shipped in the live ISO must parse, and the boot-medium rule
# must keep putting USB disks and optical drives on BFQ: that is what makes
# the root-image verify unit's IOSchedulingClass=idle mean anything while the
# live system pages its airootfs in from the same stick.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
rules_dir="$ROOT/configs/airootfs/etc/udev/rules.d"

if ! command -v udevadm >/dev/null || ! udevadm verify --help >/dev/null 2>&1; then
  echo "skip: udevadm verify unavailable"
  exit 0
fi

udevadm verify --no-style "$rules_dir"/*.rules

bfq_rule="$rules_dir/71-omarchy-iso-boot-medium-bfq.rules"
grep -qE '^ACTION=="add\|change".*ENV\{ID_BUS\}=="usb".*ATTR\{queue/scheduler\}="bfq"' "$bfq_rule" ||
  { echo "USB disks are no longer put on bfq in $bfq_rule"; exit 1; }
grep -qE '^ACTION=="add\|change".*KERNEL=="sr\[0-9\]\*.*ATTR\{queue/scheduler\}="bfq"' "$bfq_rule" ||
  { echo "optical drives are no longer put on bfq in $bfq_rule"; exit 1; }
grep -qE 'ENV\{DEVTYPE\}=="disk"' "$bfq_rule" ||
  { echo "bfq rule must be scoped to whole disks (partitions have no queue/)"; exit 1; }

echo "ok: udev rules parse; boot media go on bfq"
