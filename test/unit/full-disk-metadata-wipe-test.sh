#!/bin/bash
#
# A disk cloned from a larger drive can carry a partition beyond its current
# end. libparted then refuses the disk before archinstall gets far enough to
# perform its own wipe. Whole-disk confirmation clears that stale GPT/MBR
# metadata before archinstall is imported. Cancellation and the free-space
# (dual-boot) path must leave the same bytes untouched.
#
# Every destructive command in this test receives a regular file below a
# private temporary directory. No loop device or physical disk is used.

set -euo pipefail
export LC_ALL=C

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CONFIGURATOR="$ROOT/configs/airootfs/root/configurator"
CLEANUP="$ROOT/configs/airootfs/usr/local/bin/omarchy-iso-cleanup-disk"

for tool in dd od parted python3 sha256sum truncate wipefs; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: $tool is not installed"
    exit 0
  fi
done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {
  local label=$1 expected=$2 actual=$3
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s: expected "%s", got "%s"\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

extract_function() {
  local name=$1 file=$2
  awk -v name="$name" '
    $0 == name "() {" { in_function=1 }
    in_function { print }
    in_function && /^}$/ { exit }
  ' "$file"
}

# Exercise the exact destructive primitive used by the cleanup command, while
# keeping the command's production-only block-device guard out of this test.
eval "$(extract_function wipe_full_disk_metadata "$CLEANUP")"
eval "$(extract_function release_and_wipe "$CLEANUP")"
eval "$(extract_function confirm_disk_overwrite "$CONFIGURATOR")"
eval "$(extract_function select_installation "$CONFIGURATOR")"

bytes_hex() {
  dd if="$1" bs=1 skip="$2" count="$3" status=none 2>/dev/null |
    od -An -tx1 | tr -d '[:space:]'
}

last_lba() {
  echo $(( $(stat -c %s "$1") / 512 - 1 ))
}

gpt_partition_end_lba() {
  python3 -c 'import struct, sys
with open(sys.argv[1], "rb") as image:
    image.seek(2 * 512 + 40)
    print(struct.unpack("<Q", image.read(8))[0])' "$1"
}

mbr_partition_end_lba() {
  python3 -c 'import struct, sys
with open(sys.argv[1], "rb") as image:
    image.seek(446 + 8)
    start, size = struct.unpack("<II", image.read(8))
    print(start + size - 1)' "$1"
}

make_malformed_gpt() {
  local image=$1
  truncate -s 96M "$image"
  parted --script "$image" mklabel gpt mkpart primary 1MiB 80MiB
  truncate -s 64M "$image"
}

make_malformed_mbr() {
  local image=$1
  truncate -s 96M "$image"
  parted --script "$image" mklabel msdos mkpart primary 1MiB 80MiB
  truncate -s 64M "$image"
}

# Minimal configurator UI stand-ins. The cleanup stand-in refuses anything but
# a disposable file in this test's directory, then calls the production wipe
# primitive above.
clear_logo() { :; }
say() { :; }
t() { printf '%s' "$1"; }
abort() { return 99; }
gum() {
  [[ ${1:-} == confirm ]] || return 2
  return "$GUM_CONFIRM_STATUS"
}
events=()
verify_install_medium_before_disk_write() {
  events+=(verify)
  return "${VERIFY_MEDIUM_STATUS:-0}"
}
omarchy-iso-cleanup-disk() {
  [[ ${1:-} == --full-disk-overwrite-confirmed && $# == 2 ]] || return 2
  [[ $2 == "$WORK/"* && -f $2 ]] || return 2
  events+=(wipe)
  disk=$2
  disk_name=$(basename "$disk")
  wipe_partition_table=true
  release_and_wipe
}

echo "==> malformed metadata fixture"
make_malformed_gpt "$WORK/malformed-gpt.img"
if (( $(gpt_partition_end_lba "$WORK/malformed-gpt.img") > $(last_lba "$WORK/malformed-gpt.img") )); then
  check "the GPT fixture has an out-of-bounds partition" true true
else
  check "the GPT fixture has an out-of-bounds partition" true false
fi
check "the primary GPT header is present" 4546492050415254 \
  "$(bytes_hex "$WORK/malformed-gpt.img" 512 8)"
check "the protective MBR is present" 55aa \
  "$(bytes_hex "$WORK/malformed-gpt.img" 510 2)"

echo "==> ordinary post-import cleanup"
cp "$WORK/malformed-gpt.img" "$WORK/post-import.img"
disk="$WORK/post-import.img"
disk_name=post-import
wipe_partition_table=false
partitions() { :; }
unuse() { :; }
release_holders() { :; }
blockdev() { return 0; }
release_and_wipe
check "post-import cleanup preserves the table archinstall already read" 4546492050415254 \
  "$(bytes_hex "$disk" 512 8)"

echo "==> confirmed full-disk overwrite"
cp "$WORK/malformed-gpt.img" "$WORK/confirmed.img"
disk="$WORK/confirmed.img"
GUM_CONFIRM_STATUS=0
CONFIGURATOR_DRY_RUN=false
VERIFY_MEDIUM_STATUS=0
events=()
if confirm_disk_overwrite; then
  check "confirmation proceeds" true true
else
  check "confirmation proceeds" true false
fi
check "the install medium is verified before metadata is erased" "verify wipe" "${events[*]}"
check "confirmed GPT metadata is erased" 0000000000000000 "$(bytes_hex "$disk" 512 8)"
check "confirmed MBR metadata is erased" 0000 "$(bytes_hex "$disk" 510 2)"

echo "==> failed install-medium verification"
cp "$WORK/malformed-gpt.img" "$WORK/bad-medium.img"
disk="$WORK/bad-medium.img"
before=$(sha256sum "$disk" | cut -d' ' -f1)
GUM_CONFIRM_STATUS=0
VERIFY_MEDIUM_STATUS=17
events=()
if confirm_disk_overwrite; then
  check "a bad install medium stops the overwrite" false true
else
  check "a bad install medium stops the overwrite" false false
fi
after=$(sha256sum "$disk" | cut -d' ' -f1)
check "a bad install medium preserves every disk byte" "$before" "$after"
check "cleanup does not run after failed verification" "verify" "${events[*]}"
VERIFY_MEDIUM_STATUS=0

echo "==> cancelled full-disk overwrite"
cp "$WORK/malformed-gpt.img" "$WORK/cancelled.img"
disk="$WORK/cancelled.img"
before=$(sha256sum "$disk" | cut -d' ' -f1)
GUM_CONFIRM_STATUS=1
events=()
if confirm_disk_overwrite; then
  check "cancellation returns to the mode picker" false true
else
  check "cancellation returns to the mode picker" false false
fi
after=$(sha256sum "$disk" | cut -d' ' -f1)
check "cancellation preserves every byte" "$before" "$after"
check "cancellation performs neither verification nor cleanup" "" "${events[*]}"

echo "==> dry configurator demonstration"
cp "$WORK/malformed-gpt.img" "$WORK/dry-run.img"
disk="$WORK/dry-run.img"
before=$(sha256sum "$disk" | cut -d' ' -f1)
GUM_CONFIRM_STATUS=0
CONFIGURATOR_DRY_RUN=true
events=()
if confirm_disk_overwrite; then
  check "dry-run confirmation proceeds" true true
else
  check "dry-run confirmation proceeds" true false
fi
after=$(sha256sum "$disk" | cut -d' ' -f1)
check "the dry configurator preserves every byte" "$before" "$after"
check "the dry configurator performs neither verification nor cleanup" "" "${events[*]}"
CONFIGURATOR_DRY_RUN=false

echo "==> free-space dual boot"
cp "$WORK/malformed-gpt.img" "$WORK/dual-boot.img"
disk="$WORK/dual-boot.img"
before=$(sha256sum "$disk" | cut -d' ' -f1)
requires_full_disk_install() { return 1; }
install_mode_form() { install_mode=free_space; }
run_partition_decide() { return 0; }
disk_form() { return 98; }
install_mode=""
install_target=""
events=()
if select_installation; then
  check "dual boot selects the protected path" free_space "$install_target"
else
  check "dual boot selects the protected path" free_space failed
fi
after=$(sha256sum "$disk" | cut -d' ' -f1)
check "dual boot preserves every byte before its own partition plan" "$before" "$after"
check "dual boot never calls the full-disk verification or cleanup branch" "" "${events[*]}"

echo "==> malformed MBR metadata"
make_malformed_mbr "$WORK/malformed-mbr.img"
if (( $(mbr_partition_end_lba "$WORK/malformed-mbr.img") > $(last_lba "$WORK/malformed-mbr.img") )); then
  check "the MBR fixture has an out-of-bounds partition" true true
else
  check "the MBR fixture has an out-of-bounds partition" true false
fi
check "the MBR signature is present" 55aa "$(bytes_hex "$WORK/malformed-mbr.img" 510 2)"
wipe_full_disk_metadata "$WORK/malformed-mbr.img"
check "the MBR metadata is erased" 0000 "$(bytes_hex "$WORK/malformed-mbr.img" 510 2)"

if ((failures > 0)); then
  echo "FAIL: $failures check(s) failed"
  exit 1
fi
echo "ok: full-disk confirmation repairs malformed metadata without touching cancelled or dual-boot disks"
