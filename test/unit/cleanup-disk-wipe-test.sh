#!/bin/bash
#
# #137: a Full Install onto a disk that still held a LUKS partition aborted in archinstall, because
# the cleanup released the holders but left the signature on the disk. The wipe happens only where
# the disk is being erased - protected mode returns before it.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CLEANUP="$ROOT/configs/airootfs/usr/local/bin/omarchy-iso-cleanup-disk"

pass() {
  printf 'ok - %s\n' "$1"
}

fail() {
  local description="$1"
  local detail="${2:-}"

  [[ -n $detail ]] && printf '%s\n' "$detail" >&2
  printf 'not ok - %s\n' "$description" >&2
  exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stub="$work/bin"
mkdir -p "$stub"

# A disk with the two partitions from the report: one plain, one an older LUKS install.
cat >"$stub/lsblk" <<'SH'
#!/bin/bash
case " $* " in
  *" PATH,TYPE "*) printf '/dev/sda disk\n/dev/sda1 part\n/dev/sda2 crypt\n' ;;
  *" PATH "*)      printf '/dev/sda\n/dev/sda1\n/dev/sda2\n' ;;
esac
SH

cat >"$stub/wipefs" <<'SH'
#!/bin/bash
# --all --force <device>: record the device, not the flags.
printf '%s\n' "${!#}" >>"$WIPEFS_LOG"
SH

# Everything else the cleanup drives: present, and quiet.
for command in findmnt swapoff pvs vgchange cryptsetup blockdev partprobe udevadm; do
  printf '#!/bin/bash\nexit 0\n' >"$stub/$command"
done
chmod +x "$stub"/*

run() {  # $@ = cleanup-disk arguments
  PATH="$stub:$PATH" WIPEFS_LOG="$work/wiped" bash "$CLEANUP" "$@" >"$work/out" 2>&1
}

# A full install: the disk and both partitions lose their signatures.
run /dev/sda || fail "the cleanup runs on a wiped disk" "$(cat "$work/out")"
for device in /dev/sda /dev/sda1 /dev/sda2; do
  grep -qx "$device" "$work/wiped" 2>/dev/null ||
    fail "$device is wiped before archinstall sees it" "$(cat "$work/wiped" 2>/dev/null)"
done
pass "a full install wipes the disk and its partitions"

# Protected mode: the disk is not being erased, so nothing may be wiped.
: >"$work/wiped"
run --protected /mnt || fail "protected mode exits cleanly" "$(cat "$work/out")"
[[ ! -s $work/wiped ]] ||
  fail "protected mode leaves the disk's signatures alone" "$(cat "$work/wiped")"
pass "protected mode does not touch signatures"
