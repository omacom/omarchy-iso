#!/bin/bash
#
# omarchy-iso-cleanup-disk skips flock -x and O_RDWR wipefs on a clean disk so
# systemd-udevd never hits EAGAIN and delays udevadm settle, while keeping
# flock -x across teardown, signature wiping, and blockdev --rereadpt on a used
# disk so udevd's probes do not race the re-read.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/configs/airootfs/usr/local/bin/omarchy-iso-cleanup-disk"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $1" >&2
  [[ -z ${2:-} ]] || echo "$2" >&2
  exit 1
}

# Call the script's own release_disk function against stubbed tools and a
# synthetic disk state.
run_case() {
  local mode=$1
  local log="$work/$mode.log"
  : >"$log"

  bash -euo pipefail -c '
    log=$1
    mode=$2
    script=$3
    work=$4
    disk="$work/fake-disk"
    : >"$disk"
    disk_name="fake-disk"

    eval "$(awk "/^[a-z_]+\(\) \{$/ { p=1 } p { print } /^\}$/ { p=0 }" "$script")"

    partitions() {
      [[ $mode == "used" ]] && echo "fake-disk1" || true
    }
    udevadm() { echo "udevadm $*" >>"$log"; }
    findmnt() { return 1; }
    swapoff() { echo "swapoff $*" >>"$log"; }
    flock() { echo "flock $*" >>"$log"; }
    blockdev() { echo "blockdev $*" >>"$log"; }
    wipefs() {
      echo "wipefs $*" >>"$log"
      if [[ " $* " == *" --no-act "* ]]; then
        [[ $mode == "used" || $mode == "sig-only" ]] && echo "0x438  ext4" || true
      fi
    }

    release_disk
    $released
  ' _ "$log" "$mode" "$SCRIPT" "$work"
}

run_case clean
! grep -q '^flock ' "$work/clean.log" || fail "a clean disk must not take flock -x" "$(cat "$work/clean.log")"
! grep -q '^wipefs --all ' "$work/clean.log" || fail "a clean disk must not run O_RDWR wipefs --all" "$(cat "$work/clean.log")"
grep -q '^blockdev --rereadpt ' "$work/clean.log" || fail "a clean disk still checks blockdev --rereadpt" "$(cat "$work/clean.log")"
echo "ok - clean disk skips flock -x and O_RDWR wipefs"

run_case used
flock_line=$(grep -n '^flock -x ' "$work/used.log" | head -n1 | cut -d: -f1)
wipe_line=$(grep -n '^wipefs --all --force /dev/fake-disk1$' "$work/used.log" | head -n1 | cut -d: -f1)
reread_line=$(grep -n '^blockdev --rereadpt ' "$work/used.log" | head -n1 | cut -d: -f1)
[[ -n $flock_line && -n $wipe_line && -n $reread_line ]] || fail "a used disk locks, wipes, and re-reads" "$(cat "$work/used.log")"
(( flock_line < wipe_line && wipe_line < reread_line )) || fail "a used disk wipes and re-reads after acquiring flock" "$(cat "$work/used.log")"
echo "ok - used disk locks, wipes signatures, and re-reads the partition table"

run_case sig-only
grep -q '^flock -x ' "$work/sig-only.log" || fail "a disk with a whole-disk signature takes flock -x" "$(cat "$work/sig-only.log")"
grep -q '^wipefs --all --force --types nogpt,PMBR,dos ' "$work/sig-only.log" || fail "a disk with a whole-disk signature wipes it" "$(cat "$work/sig-only.log")"
echo "ok - whole-disk signature without partitions is detected and wiped"
