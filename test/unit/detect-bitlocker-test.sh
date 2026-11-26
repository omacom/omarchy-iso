#!/bin/bash
#
# detect_bitlocker() reads eight bytes of every partition and looks for
# BitLocker's signature in them. Read into a shell variable as they are, those
# bytes made bash print "warning: command substitution: ignored null byte in
# input" for every partition with a NUL among them, and a LUKS, ext4 or btrfs
# partition has one. The warning went to the installer's screen, between two
# configurator screens, on every disk that already held Linux. The check has to
# find a BitLocker partition and print nothing else, whatever the bytes are.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
configurator="$ROOT/configs/airootfs/root/configurator"

# Without a work directory the fixtures below would land in /.
WORK=$(mktemp -d) || { echo "mktemp gave no work directory" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf "  ok   %s\n" "$label"
  else
    printf "  FAIL %s: expected [%s], got [%s]\n" "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# The function as the configurator defines it.
eval "$(sed -n '/^detect_bitlocker() {$/,/^}$/p' "$configurator")"
declare -F detect_bitlocker >/dev/null ||
  { echo "detect_bitlocker is not in ${configurator#"$ROOT/"}"; exit 1; }

# Partitions as files: a LUKS2 header, the zeroed start of an ext4 or btrfs
# partition, and a BitLocker volume boot record.
printf 'LUKS\272\276\000\002\000\000\000\000\000\000\100\000' >"$WORK/luks"
head -c 512 /dev/zero >"$WORK/zeros"
printf '\353\130\220-FVE-FS-\000\002\010' >"$WORK/bitlocker"

# lsblk lists the partitions of $disk: here, the files the case names.
PARTS=()
lsblk() {
  local part
  for part in "${PARTS[@]}"; do
    printf '%s part\n' "$WORK/$part"
  done
}

# Sets found, status and noise: what the check printed, what it returned, and
# everything that reached stderr, the shell's own warnings included.
probe() {
  PARTS=("$@")
  found=$(disk=/dev/test detect_bitlocker 2>"$WORK/stderr")
  status=$?
  noise=$(<"$WORK/stderr")
  # A blank line is noise too, and the substitution above drops it.
  [[ -z $noise && -s $WORK/stderr ]] && noise="blank lines"
  return 0
}

probe luks zeros
check "a disk with LUKS and ext4 has no BitLocker" "1:" "$status:$found"
check "and the check prints no warning for their NUL bytes" "" "$noise"

probe luks bitlocker zeros
check "a BitLocker partition is found among the others" "0:$WORK/bitlocker" "$status:$found"
check "and nothing else reaches the screen" "" "$noise"

probe missing
check "a partition that cannot be read is not BitLocker" "1:" "$status:$found"
check "and its read error stays off the screen" "" "$noise"

if ((failures)); then
  echo "FAIL: $failures check(s) failed"
  exit 1
fi
echo "ok: the BitLocker check finds the signature and prints nothing else"
