#!/bin/bash
#
# The ISO must carry a GPT that UEFI firmware accepts: a GPT header behind a
# protective MBR. The build finds the ISO it wrote with iso_written_since and
# checks it with iso_has_valid_gpt (builder/iso-partition-table.sh). The
# layout it guards against is the one archiso gives an ISO that also boots
# through BIOS: a GPT header, and an MBR with real entries in place of the
# protective one. An MSI Z690 did not offer a stick with that layout in its
# boot menu.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../../builder/iso-partition-table.sh
source "$ROOT/builder/iso-partition-table.sh"

# Without a work directory the images below would land in /.
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

# image NAME GPT_HEADER ENTRY... : two sectors, with the MBR entries given as
# "slot:boot:type:first-lba" (hex bytes, decimal LBA) and "EFI PART" at LBA 1
# when GPT_HEADER is yes.
image() {
  local name=$1 header=$2 entry slot boot type lba
  shift 2
  head -c 1024 /dev/zero >"$WORK/$name"
  for entry in "$@"; do
    IFS=: read -r slot boot type lba <<<"$entry"
    printf "\\x$boot" | dd of="$WORK/$name" bs=1 seek=$((446 + 16 * slot)) conv=notrunc status=none
    printf "\\x$type" | dd of="$WORK/$name" bs=1 seek=$((446 + 16 * slot + 4)) conv=notrunc status=none
    printf "\\x$(printf '%02x' $((lba & 255)))\\x$(printf '%02x' $((lba >> 8 & 255)))" |
      dd of="$WORK/$name" bs=1 seek=$((446 + 16 * slot + 8)) conv=notrunc status=none
  done
  printf '\x55\xaa' | dd of="$WORK/$name" bs=1 seek=510 conv=notrunc status=none
  [[ $header != yes ]] || printf 'EFI PART' | dd of="$WORK/$name" bs=1 seek=512 conv=notrunc status=none
}

# yes or no, and anything the check wrote to stderr: it runs in the build's
# log, and must stay quiet whatever the bytes are.
valid() {
  local answer=no
  iso_has_valid_gpt "$WORK/$1" 2>"$WORK/stderr" && answer=yes
  [[ -s $WORK/stderr ]] && answer+=" (stderr: $(head -n 1 "$WORK/stderr"))"
  echo "$answer"
}

# What xorriso writes with -appended_part_as_gpt and --mbr-force-bootable.
image valid yes 0:00:ee:1 1:80:00:0
check "a protective MBR in front of a GPT header is a valid GPT" yes "$(valid valid)"

# What it writes with -isohybrid-gpt-basdat: the ISO and the EFI system
# partition as MBR entries, and a GPT header nothing announces.
image isohybrid yes 0:80:00:64 1:00:ef:12864600
check "a GPT header behind an MBR with real entries is not" no "$(valid isohybrid)"

image no-header no 0:00:ee:1
check "a protective MBR with no GPT header is not" no "$(valid no-header)"

image wrong-start yes 0:00:ee:64
check "a 0xEE entry that does not start at LBA 1 is not protective" no "$(valid wrong-start)"

image last-slot yes 3:00:ee:1
check "the protective entry counts in any of the four slots" yes "$(valid last-slot)"

check "a file that cannot be read is not a valid GPT" no "$(valid missing)"

# The release directory on a second build: the launcher renamed the first
# build's ISO, and this build has written its own.
mkdir "$WORK/release"
touch -d "2 hours ago" "$WORK/release/omarchy-2026.11.25-x86_64-quattro.iso"
touch -d "1 hour ago" "$WORK/started"
touch "$WORK/release/omarchy-2026.11.26-x86_64.iso"
check "only the ISO written after the build started is the build's own" \
  "$WORK/release/omarchy-2026.11.26-x86_64.iso" "$(iso_written_since "$WORK/release" "$WORK/started")"

rm "$WORK/release/omarchy-2026.11.26-x86_64.iso"
check "an ISO from an earlier build is not" "" "$(iso_written_since "$WORK/release" "$WORK/started")"

if ((failures)); then
  echo "FAIL: $failures check(s) failed"
  exit 1
fi
echo "ok: the build checks its own ISO, and tells a valid GPT from the isohybrid one"
