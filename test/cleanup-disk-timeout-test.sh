#!/bin/bash
#
# omarchy-iso-cleanup-disk runs from a phase with check=True, so a command
# wedged in the kernel must be given up on, not waited for — except partprobe,
# whose abandoned rescan would race archinstall, so that one must fail loudly.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
CLEANUP="$ROOT/configs/airootfs/usr/local/bin/omarchy-iso-cleanup-disk"

pass() { printf 'ok - %s\n' "$1"; }
fail() {
  [[ -n ${2:-} ]] && printf '%s\n' "$2" >&2
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

work=$(mktemp -d)
stubs="$work/stubs"; mkdir -p "$stubs"
export TEST_LOG="$work/calls.log"
WEDGED_PIDS="$work/wedged.pids"

# Wedged stubs outlive the script by design — abandoning them is the behaviour
# under test — so the test reaps them itself.
reap_wedged() {
  [[ -s $WEDGED_PIDS ]] && kill -9 $(cat "$WEDGED_PIDS") 2>/dev/null || true
  : >"$WEDGED_PIDS"
}
trap 'reap_wedged; rm -rf "$work"' EXIT

# Wedged like a real D-state task: ignores TERM, so a plain sleep would pass
# against an implementation that still signals and waits. trap-then-exec keeps
# it one process, recorded for reap_wedged.
wedge() {
  cat >"$stubs/$1" <<STUB
#!/bin/bash
printf '$1 %s\n' "\$*" >>"\$TEST_LOG"
echo \$\$ >>"$WEDGED_PIDS"
trap '' TERM
exec sleep 300
STUB
  chmod +x "$stubs/$1"
}

stub() {
  local tool
  for tool in "$@"; do
    cat >"$stubs/$tool" <<STUB
#!/bin/bash
printf '$tool %s\n' "\$*" >>"\$TEST_LOG"
exit 0
STUB
    chmod +x "$stubs/$tool"
  done
}

# lsblk echoes back the real disk it was given — the script re-checks [[ -b ]]
# — plus a fake partition; findmnt claims one mount everywhere. Together they
# make every teardown path run against the stubs.
cat >"$stubs/lsblk" <<'STUB'
#!/bin/bash
for arg in "$@"; do disk=$arg; done
if [[ $* == *TYPE* ]]; then
  echo "$disk disk"
  echo "/dev/testdisk1 part"
else
  echo "$disk"
fi
STUB

cat >"$stubs/findmnt" <<'STUB'
#!/bin/bash
printf 'findmnt %s\n' "$*" >>"$TEST_LOG"
[[ $* == *-S* ]] && echo /fake/mountpoint
exit 0
STUB
chmod +x "$stubs"/*

# The script guards on [[ -b ]], which no stub can satisfy, so borrow a block
# device from the host. Nothing touches it: every tool is stubbed.
disk=""
for candidate in /dev/loop0 /dev/sda /dev/vda /dev/nvme0n1 /dev/disk0; do
  [[ -b $candidate ]] && { disk="$candidate"; break; }
done
if [[ -z $disk ]]; then
  printf 'ok - skipped: no block device on this host to pass the -b guard\n'
  exit 0
fi

# Watchdog: an implementation that regresses to blocking fails this test
# instead of hanging it. Returns 124 on overrun.
run_cleanup() {
  local pid waited=0 status=0
  : >"$TEST_LOG"
  PATH="$stubs:$PATH" OMARCHY_CLEANUP_TIMEOUT=2 \
    bash "$CLEANUP" "$disk" >"$work/out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && ((waited < 60)); do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 124
  fi
  wait "$pid" || status=$?
  return "$status"
}

# ── swapoff (teardown) and pvs (probe) both wedge ───────────────────────────
wedge swapoff
wedge pvs
stub umount vgchange cryptsetup blockdev partprobe udevadm

status=0
run_cleanup || status=$?

((status != 124)) || fail "a wedged command no longer hangs the install" "$(cat "$work/out")"
pass "wedged swapoff and pvs are bounded rather than hanging the install"

((status == 0)) || fail "cleanup still succeeds despite commands timing out" "exit $status: $(cat "$work/out")"
pass "timed-out teardown and probes do not fail the install"

grep -q '^swapoff ' "$TEST_LOG" || fail "the test actually exercised the teardown" "$(cat "$TEST_LOG")"
grep -q '^pvs ' "$TEST_LOG" || fail "the test actually exercised the LVM probe" "$(cat "$TEST_LOG")"
grep -q '^partprobe ' "$TEST_LOG" || fail "cleanup carried on past the wedged commands" "$(cat "$TEST_LOG")"
pass "cleanup runs to the end past the wedged commands"

grep -q 'gave up' "$work/out" || fail "abandoning a command is reported" "$(cat "$work/out")"
pass "an abandoned command says so"

reap_wedged

# ── partprobe wedges ────────────────────────────────────────────────────────
stub swapoff pvs
wedge partprobe

status=0
run_cleanup || status=$?

((status != 124)) || fail "a wedged partprobe no longer hangs the install" "$(cat "$work/out")"
((status != 0)) || fail "a wedged partprobe fails the phase instead of racing archinstall" "$(cat "$work/out")"
grep -q 'refusing to hand the disk' "$work/out" ||
  fail "a wedged partprobe explains the refusal" "$(cat "$work/out")"
pass "a wedged partprobe fails loudly instead of handing archinstall a live rescan"

reap_wedged

# udevadm settle defaults to 120s; on a blank screen that reads as a hang.
grep -q 'udevadm settle --timeout' "$CLEANUP" ||
  fail "udevadm settle carries an explicit timeout"
pass "udevadm settle is bounded"
