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

# Internal disks must not stay on the Kyber that omarchy-settings' rule gives
# every disk: in the live ISO it throttles the image write (see the rule).
internal_rule="$rules_dir/72-omarchy-iso-internal-disk-scheduler.rules"
end='GOTO="omarchy_iso_internal_disk_scheduler_end"'
lines=$(grep -v '^#' "$internal_rule" | grep .)
has() { grep -qxF -- "$1" <<<"$lines"; }
has "TEST==\"mq/1\", ATTR{queue/scheduler}=\"none\"" ||
  { echo "disks with several hardware queues are no longer put on none in $internal_rule"; exit 1; }
has "TEST!=\"mq/1\", ATTR{queue/scheduler}=\"mq-deadline\"" ||
  { echo "disks with one hardware queue are no longer put on mq-deadline in $internal_rule"; exit 1; }
# Everything else must have left before those two lines: other events and
# devices, partitions, USB disks (matched on a parent, never negated: a negated
# SUBSYSTEMS passes on the disk itself and would take a USB stick off bfq), and
# zoned disks.
for skip in 'ACTION!="add|change"' 'SUBSYSTEM!="block"' 'ENV{DEVTYPE}!="disk"' 'KERNEL!="nvme*|vd*|sd*"' \
  'SUBSYSTEMS=="usb"' 'ATTR{queue/zoned}!="none"'; do
  has "$skip, $end" || { echo "$internal_rule no longer skips on $skip"; exit 1; }
  skip_line=$(grep -nxF -- "$skip, $end" <<<"$lines" | cut -d: -f1)
  set_line=$(grep -n 'ATTR{queue/scheduler}=' <<<"$lines" | head -n1 | cut -d: -f1)
  ((skip_line < set_line)) || { echo "$internal_rule sets a scheduler before it skips on $skip"; exit 1; }
done
[[ $(tail -n1 <<<"$lines") == 'LABEL="omarchy_iso_internal_disk_scheduler_end"' ]] ||
  { echo "$internal_rule does not end at its label"; exit 1; }
! grep -q 'SUBSYSTEMS!=' <<<"$lines" || { echo "$internal_rule negates SUBSYSTEMS"; exit 1; }
! grep -q kyber <<<"$lines" || { echo "$internal_rule selects kyber"; exit 1; }
# It has to sort after omarchy-settings' 60- rule and the 71- boot-medium rule.
[[ ${internal_rule##*/} > 71-omarchy-iso-boot-medium-bfq.rules ]] ||
  { echo "$internal_rule must sort after the 71- rule"; exit 1; }

echo "ok: udev rules parse; boot media go on bfq; internal disks leave kyber"
