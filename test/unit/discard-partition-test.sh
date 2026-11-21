#!/bin/bash
#
# omarchy-discard-partition tells the drive a new root partition is free
# before the install writes to it. It must never discard the ESP, a partition
# in use or a device that cannot discard, never fail the install, and never
# leave a discard running. The decisions run against stubbed lsblk and
# blkdiscard; as root, a loop device's backing file shows the discard itself.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
helper="$ROOT/configs/airootfs/usr/local/bin/omarchy-discard-partition"
tmp=$(mktemp -d)
loop=""
cleanup() {
  [[ -z $loop ]] || losetup -d "$loop" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir "$tmp/bin"
cat >"$tmp/bin/lsblk" <<'STUB'
#!/bin/bash
case " $* " in
  *" TYPE "*) echo "${FAKE_TYPE-part}" ;;
  *" PARTTYPE "*) echo "${FAKE_PARTTYPE:-0fc63daf-8483-4772-8e79-3d69d8477de4}" ;;
  *" MOUNTPOINTS "*) echo "${FAKE_MOUNTPOINTS:-}" ;;
  *" DISC-MAX "*) echo "  ${FAKE_DISC_MAX-2147450880}" ;;
  *" SIZE "*) echo "  536870912000" ;;
esac
STUB
cat >"$tmp/bin/blkdiscard" <<'STUB'
#!/bin/bash
echo "blkdiscard $*" >>"$CALLS"
[[ -z ${FAKE_SLEEP:-} ]] || sleep "$FAKE_SLEEP"
exit "${FAKE_STATUS:-0}"
STUB
chmod +x "$tmp/bin"/*

run() { # run <expected output fragment> [env...]
  local expected=$1 output status=0
  shift
  : >"$tmp/calls"
  output=$(env CALLS="$tmp/calls" PATH="$tmp/bin:$PATH" "$@" "$helper" /dev/fake1) || status=$?
  (( status == 0 )) || fail "exit $status, never fails the install: $output"
  [[ $output == *"$expected"* ]] || fail "expected '$expected', got: $output"
}

run "is not a partition" FAKE_TYPE=disk
[[ ! -s $tmp/calls ]] || fail "a whole disk was discarded"
run "is an EFI system partition" FAKE_PARTTYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
[[ ! -s $tmp/calls ]] || fail "the ESP was discarded"
run "is in use" FAKE_MOUNTPOINTS=/mnt
[[ ! -s $tmp/calls ]] || fail "a mounted partition was discarded"
run "does not accept discards" FAKE_DISC_MAX=0
[[ ! -s $tmp/calls ]] || fail "a device without discard support was discarded"
echo "ok: the ESP, whole disks, partitions in use and devices without discard are left alone"

run "discarded /dev/fake1 (512000 MiB)"
grep -qx 'blkdiscard --step 4G /dev/fake1' "$tmp/calls" || fail "blkdiscard was not run as expected: $(cat "$tmp/calls")"
run "does not support discards" FAKE_STATUS=2
run "WARNING: blkdiscard /dev/fake1 failed (exit 1)" FAKE_STATUS=1
echo "ok: a discard is run without -f, an unsupported one is skipped, and a failed one is reported, all without failing"

started=$SECONDS
run "was still running after 1s; stopped it" FAKE_SLEEP=30 OMARCHY_DISCARD_BUDGET=1
(( SECONDS - started < 10 )) || fail "a slow discard was not stopped at its budget"
pgrep -f "$tmp/bin/blkdiscard" >/dev/null && fail "the stopped discard is still running"
echo "ok: a slow discard is stopped at its budget and waited for"

if (( EUID != 0 )) || ! command -v losetup >/dev/null || ! command -v sfdisk >/dev/null; then
  echo "skip: a real discard on a loop device needs root, losetup and sfdisk"
  exit 0
fi
image=$tmp/disk.img
truncate -s 96M "$image"
printf 'label: gpt\nsize=16M, type=uefi\ntype=linux\n' | sfdisk -q "$image"
if ! loop=$(losetup --find --show --partscan "$image" 2>/dev/null); then
  loop=""
  echo "skip: no loop device here"
  exit 0
fi
udevadm settle 2>/dev/null || sleep 1
for part in "${loop}p1" "${loop}p2"; do
  [[ -b $part ]] || { echo "skip: no partition nodes for $loop"; exit 0; }
  dd if=/dev/urandom of="$part" bs=1M status=none 2>/dev/null || true
done
sync
allocated() { du -k "$image" | cut -f1; }
before=$(allocated)
"$helper" "${loop}p1" >/dev/null
(( $(allocated) == before )) || fail "the loop device's ESP was discarded"
"$helper" "${loop}p2"
after=$(allocated)
(( before - after > 70 * 1024 )) || fail "the root partition was not discarded: ${before} KiB allocated before, ${after} KiB after"
echo "ok: a loop device's root partition is discarded (${before} KiB allocated before, ${after} KiB after) and its ESP is not"
