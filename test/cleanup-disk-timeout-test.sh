#!/bin/bash
#
# omarchy-iso-cleanup-disk runs from a phase with check=True, so a probe that
# never returns is an install that never returns — and the screen says only
# "Cleaning up existing holders on install disk" while it happens. These cases
# pin the bound that stops that.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLEANUP="$ROOT/configs/airootfs/usr/local/bin/omarchy-iso-cleanup-disk"

pass() { printf 'ok - %s\n' "$1"; }

fail() {
  local description="$1" detail="${2:-}"
  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

stub_dir="$work/stubs"
mkdir -p "$stub_dir"

# A disk with one partition and nothing else on it.
cat >"$stub_dir/lsblk" <<'STUB'
#!/bin/bash
echo "/dev/testdisk disk"
echo "/dev/testdisk1 part"
STUB

# The wedged probe: LVM blocked on a global mutex some other driver is stuck
# under. That state takes no signal at all, so the stub ignores SIGTERM — a plain
# sleep would pass this test against an implementation that still hangs for real.
cat >"$stub_dir/pvs" <<'STUB'
#!/bin/bash
printf 'pvs called\n' >>"$TEST_LOG"
trap "" TERM
sleep 300
STUB

for tool in findmnt umount swapoff vgchange cryptsetup blockdev partprobe udevadm; do
  cat >"$stub_dir/$tool" <<STUB
#!/bin/bash
printf '$tool %s\n' "\$*" >>"\$TEST_LOG"
exit 0
STUB
done
chmod +x "$stub_dir"/*

export TEST_LOG="$work/calls.log"
: >"$TEST_LOG"

# The script guards on [[ -b ]], which no stub can satisfy, so borrow whatever
# block device this host has. Nothing is read from it: every tool that would
# touch it is stubbed above.
disk=""
for candidate in /dev/loop0 /dev/sda /dev/vda /dev/nvme0n1 /dev/disk0; do
  [[ -b $candidate ]] && { disk="$candidate"; break; }
done
if [[ -z $disk ]]; then
  printf 'ok - skipped: no block device on this host to pass the -b guard\n'
  exit 0
fi

start=$SECONDS
status=0
PATH="$stub_dir:$PATH" OMARCHY_CLEANUP_TIMEOUT=2 bash "$CLEANUP" "$disk" >"$work/out" 2>&1 || status=$?
elapsed=$(( SECONDS - start ))

grep -q 'pvs called' "$TEST_LOG" || fail "the test actually exercised the LVM probe" "$(cat "$TEST_LOG")"
(( elapsed < 60 )) || fail "a wedged probe no longer hangs the install" "took ${elapsed}s"
pass "a wedged LVM probe is bounded rather than hanging the install"

(( status == 0 )) || fail "cleanup still succeeds despite a probe timing out" "exit $status"
pass "a timed-out probe does not fail the install"

# The whole point is that a stall is explicable, so it has to say something.
grep -q 'gave up' "$work/out" || fail "abandoning a probe is reported" "$(cat "$work/out")"
pass "an abandoned probe says so"

# udevadm settle defaults to 120s; on a blank screen that reads as a hang.
grep -q 'udevadm settle --timeout' "$CLEANUP" ||
  fail "udevadm settle carries an explicit timeout"
pass "udevadm settle is bounded"
