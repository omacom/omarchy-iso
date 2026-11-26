#!/bin/bash
#
# The ISO must carry a GPT that UEFI firmware accepts: a GPT behind a
# protective MBR. The build checks each ISO it wrote with iso_has_valid_gpt
# (builder/iso-partition-table.sh). The layout it guards against is the one
# archiso gives an ISO that also boots through BIOS: a GPT, and an MBR with
# real entries in place of the protective one. An MSI Z690 did not offer a
# stick with that layout in its boot menu.

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

# image NAME LABEL: a 1 MiB disk image with an empty partition table.
image() {
  truncate -s 1M "$WORK/$1"
  echo "label: $2" | sfdisk --quiet "$WORK/$1" >/dev/null
}

# yes or no, and anything the check wrote to stderr: it runs in the build's
# log, and must stay quiet whatever the file is.
valid() {
  local answer=no
  iso_has_valid_gpt "$WORK/$1" 2>"$WORK/stderr" && answer=yes
  [[ -s $WORK/stderr ]] && answer+=" (stderr: $(head -n 1 "$WORK/stderr"))"
  echo "$answer"
}

# What xorriso writes with -appended_part_as_gpt.
image gpt gpt
check "a GPT behind a protective MBR is valid" yes "$(valid gpt)"

# What it writes with -isohybrid-gpt-basdat: the same GPT, and an MBR whose
# entries are real partitions. Byte 4 of an MBR entry is its type.
cp "$WORK/gpt" "$WORK/isohybrid"
printf '\xef' | dd of="$WORK/isohybrid" bs=1 seek=$((446 + 4)) conv=notrunc status=none
check "the same GPT behind an MBR with no protective entry is not" no "$(valid isohybrid)"

image mbr dos
check "an MBR partition table alone is not" no "$(valid mbr)"

check "a file that cannot be read is not" no "$(valid missing)"

if ((failures)); then
  echo "FAIL: $failures check(s) failed"
  exit 1
fi
echo "ok: the build tells a valid GPT from the isohybrid one"
