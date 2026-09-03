#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

check_cache_none() {
  local description="$1" file="$2" pattern="$3"

  if grep -Fq -- "$pattern" "$file"; then
    echo "ok: $description"
  else
    echo "not ok: $description" >&2
    return 1
  fi
}

check_cache_none \
  "base-test.sh bypasses the host cache for either fresh target format" \
  "$ROOT/test/integration.d/base-test.sh" \
  '-drive file="$disk",format="$disk_format",cache=none,if=none,id=drive0'
check_cache_none \
  "omarchy-iso-test bypasses the host cache for fresh target disks" \
  "$ROOT/bin/omarchy-iso-test" \
  '-drive file="$disk",format="$disk_format",cache=none,if=none,id=drive0'

check_cache_none \
  "omarchy-iso-test defaults to physical-disk-like raw targets" \
  "$ROOT/bin/omarchy-iso-test" \
  'DISK_FORMAT=raw'
check_cache_none \
  "omarchy-iso-test creates each fresh non-raw target in the selected format" \
  "$ROOT/bin/omarchy-iso-test" \
  'qemu-img create -f "$DISK_FORMAT" "$BASE_DISK" 40G'
check_cache_none \
  "omarchy-iso-test removes Btrfs COW variance from raw physical-disk fixtures" \
  "$ROOT/bin/omarchy-iso-test" \
  'set_raw_disk_physical_semantics "$BASE_DISK"'
check_cache_none \
  "omarchy-iso-test sizes a raw fixture only after setting its semantics" \
  "$ROOT/bin/omarchy-iso-test" \
  'truncate -s 40G "$BASE_DISK"'
check_cache_none \
  "omarchy-iso-test overlays either accepted base format" \
  "$ROOT/bin/omarchy-iso-test" \
  'qemu-img create -f qcow2 -b "$BASE_DISK" -F "$DISK_FORMAT"'
check_cache_none \
  "omarchy-iso-test boots the acceptance overlay as qcow2" \
  "$ROOT/bin/omarchy-iso-test" \
  'OMARCHY_ACTIVE_DISK_FORMAT=qcow2'
check_cache_none \
  "integration boots scenario overlays as qcow2" \
  "$ROOT/test/integration.d/base-test.sh" \
  'OMARCHY_ACTIVE_DISK_FORMAT=qcow2'
check_cache_none \
  "integration removes Btrfs COW variance from raw physical-disk fixtures" \
  "$ROOT/test/integration.d/base-test.sh" \
  'set_raw_disk_physical_semantics "$BASE_DISK.building"'
check_cache_none \
  "integration sizes a raw fixture only after setting its semantics" \
  "$ROOT/test/integration.d/base-test.sh" \
  'truncate -s 40G "$BASE_DISK.building"'

for scenario in corrupt-image-test.sh pxe-test.sh slow-medium-test.sh; do
  check_cache_none \
    "$scenario boots its explicit qcow2 scratch disk as qcow2" \
    "$ROOT/test/integration.d/$scenario" \
    'OMARCHY_ACTIVE_DISK_FORMAT=qcow2'
done

for harness in "$ROOT/test/integration.d/base-test.sh" "$ROOT/bin/omarchy-iso-test"; do
  check_cache_none \
    "$(basename "$harness") bypasses the host cache for the installation ISO" \
    "$harness" \
    '-drive "file=$ISO,media=cdrom,cache=none,if=none,format=raw,id=cdrom0"'
done

for scenario in corrupt-image-test.sh slow-medium-test.sh; do
  check_cache_none \
    "$scenario bypasses the host cache for its installation ISO" \
    "$ROOT/test/integration.d/$scenario" \
    'media=cdrom,cache=none'
done
