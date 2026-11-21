#!/bin/bash
#
# The LUKS calibration is an Argon2id benchmark whose result sets the cost of
# the disk password. Beside the boot-time hashes of the medium it measures
# 20-30% low on a machine with 4 cores or fewer, so there it must wait for
# them; with 6 cores or more it runs beside them and is ready for an install
# that starts early. The generator decides, from the machine's core count.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
generator="$ROOT/configs/airootfs/etc/systemd/system-generators/omarchy-luks-calibrate-order"
unit="$ROOT/configs/airootfs/etc/systemd/system/omarchy-luks-calibrate.service"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# A sysfs with $1 cores of $2 threads each, numbered as the kernel does:
# every core's first thread, then the siblings.
machine() {
  local cores=$1 threads=$2 core thread cpu=0 siblings
  rm -rf "$work/sys" "$work/out"
  mkdir -p "$work/out" "$work/sys/devices/system/cpu/cpufreq"
  for ((thread = 0; thread < threads; thread++)); do
    for ((core = 0; core < cores; core++)); do
      siblings=$core
      ((threads == 2)) && siblings="$core,$((core + cores))"
      mkdir -p "$work/sys/devices/system/cpu/cpu$cpu/topology"
      echo "$siblings" >"$work/sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list"
      cpu=$((cpu + 1))
    done
  done
}

ordering() {
  OMARCHY_SYSFS="$work/sys" sh "$generator" "$work/out" "$work/early" "$work/late"
  cat "$work/out/omarchy-luks-calibrate.service.d/"*.conf 2>/dev/null || true
}

after_the_hashes=$'[Unit]\nAfter=omarchy-mirror-verify.service omarchy-root-image-verify.service'

for spec in "2 2" "4 1" "4 2" "5 2"; do
  machine $spec
  [[ $(ordering) == "$after_the_hashes" ]] || fail "$spec (cores threads): the calibration does not wait for the hashes"
done
for spec in "6 1" "6 2" "8 1" "16 2"; do
  machine $spec
  [[ -z $(ordering) ]] || fail "$spec (cores threads): the calibration waits for the hashes"
done

# No topology to read: wait, the cautious way round.
rm -rf "$work/sys" "$work/out"
mkdir -p "$work/out"
[[ $(ordering) == "$after_the_hashes" ]] || fail "an unreadable topology does not wait for the hashes"

# The unit leaves the ordering to the generator, which the image must be able
# to run.
! grep -q '^After=.*verify' "$unit" || fail "the unit orders itself after the hashes on every machine"
grep -q '\["/etc/systemd/system-generators/omarchy-luks-calibrate-order"\]="0:0:755"' "$ROOT/configs/profiledef.sh" ||
  fail "profiledef.sh does not make the generator executable"

echo "ok - the LUKS calibration waits for the medium's hashes only below 6 cores"
