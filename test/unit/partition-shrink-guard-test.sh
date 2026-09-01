#!/bin/bash
#
# cfdisk Resize rewrites the GPT and leaves the filesystem at its old size.
# That is the dual-boot trap: shrinking Windows/NTFS or an existing Linux
# /home from the partition tool corrupts the other OS. The guard must restore
# the original table when an existing partition shrank, and leave the table
# alone for the operations the tool actually tells the user to do — delete
# something unused, or create nothing and leave Free space.
#
# sfdisk and parted both operate on image files, so this needs no root, no
# loop devices, and no real disk.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LIB="$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"

if ! command -v parted >/dev/null 2>&1; then
  echo "SKIP: parted is not installed"
  exit 0
fi
if ! command -v sfdisk >/dev/null 2>&1; then
  echo "SKIP: sfdisk is not installed"
  exit 0
fi

# shellcheck source=../configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh
source "$LIB"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

IMG="$WORK/disk.img"
MIB=$((1024 * 1024))
failures=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ $expected == "$actual" ]]; then
    printf '  ok   %s\n' "$label"
  else
    printf '  FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

# parted's end position is inclusive, so partitions laid back to back overlap
# by a sector and are refused. Leave a MiB between them.
mkpart_mib() {
  parted --script "$IMG" mkpart "$1" "$2" "$(($3 * MIB))B" "$(($4 * MIB))B"
}

build_disk() {
  rm -f "$IMG"
  truncate -s 4G "$IMG"
  parted --script "$IMG" mklabel gpt
  mkpart_mib one ext4 1 800
  mkpart_mib two ext4 801 1200
  mkpart_mib three ext4 1201 1600
}

# Rewrite the first partition's size in an sfdisk dump and apply it — the same
# kind of table-only shrink cfdisk Resize performs.
shrink_first_partition_sectors() {
  local sectors="$1" dump
  dump=$(mktemp)
  sfdisk -d "$IMG" >"$dump"
  awk -v sz="$sectors" '
    !done && /^[^#].*size=/ {
      sub(/size=[[:space:]]*[0-9]+/, "size=" sz)
      done=1
    }
    { print }
  ' "$dump" | sfdisk --force "$IMG" >/dev/null 2>&1
  rm -f "$dump"
}

layout() {
  partition_starts_and_sizes "$IMG" | tr '\n' ' ' | sed 's/ $//'
}

echo "==> shrinking an existing partition is detected and restored"
build_disk
before=$(partition_starts_and_sizes "$IMG")
dump="$WORK/table.dump"
save_partition_table "$IMG" "$dump"
check "sfdisk dump captured" "0" "$?"
original=$(layout)

# 400MiB in 512-byte sectors.
shrink_first_partition_sectors 819200
check "shrink changed the table" "changed" "$([[ $(layout) == "$original" ]] && echo same || echo changed)"
shrunk=$(shrunk_partition_lines "$before" "$(partition_starts_and_sizes "$IMG")")
check "shrink reported a line" "has-shrink" "$([[ -n $shrunk ]] && echo has-shrink || echo none)"

restore_shrunk_partitions "$IMG" "$dump" "$before"
check "restore_shrunk_partitions reports restored" "0" "$?"
check "original sizes are back" "$original" "$(layout)"

echo "==> deleting a partition to make free space is not a shrink"
build_disk
before=$(partition_starts_and_sizes "$IMG")
dump="$WORK/table.dump"
save_partition_table "$IMG" "$dump"
parted --script "$IMG" rm 2
restore_shrunk_partitions "$IMG" "$dump" "$before"
check "delete is left alone" "1" "$?"
check "remaining numbers" "1 3" "$(partition_numbers "$IMG" | sort | tr '\n' ' ' | sed 's/ $//')"

echo "==> creating a partition in free space is not a shrink"
build_disk
parted --script "$IMG" rm 3
before=$(partition_starts_and_sizes "$IMG")
dump="$WORK/table.dump"
save_partition_table "$IMG" "$dump"
mkpart_mib three ext4 2000 2500
restore_shrunk_partitions "$IMG" "$dump" "$before"
check "create is left alone" "1" "$?"
check "new partition exists" "1 2 3" "$(partition_numbers "$IMG" | sort | tr '\n' ' ' | sed 's/ $//')"

echo "==> growing a partition is not a shrink"
build_disk
parted --script "$IMG" rm 3
before=$(partition_starts_and_sizes "$IMG")
dump="$WORK/table.dump"
save_partition_table "$IMG" "$dump"
# Grow partition 2 into the hole left by 3. parted resizepart prompts on
# shrink, not on grow.
parted --script "$IMG" resizepart 2 "$((2000 * MIB))B"
restore_shrunk_partitions "$IMG" "$dump" "$before"
check "grow is left alone" "1" "$?"

echo "==> no table change is not a shrink"
build_disk
before=$(partition_starts_and_sizes "$IMG")
dump="$WORK/table.dump"
save_partition_table "$IMG" "$dump"
restore_shrunk_partitions "$IMG" "$dump" "$before"
check "no-op is left alone" "1" "$?"
check "layout unchanged" "$before" "$(partition_starts_and_sizes "$IMG")"

# Everything above is the guard working. The rest is the guard failing, which
# is where a data-safety check earns its keep: every way of not knowing must
# come back as "do not continue", never as the "table is fine" status that
# lets the install proceed.
echo "==> a table that cannot be read or snapshotted is refused, not assumed safe"

save_partition_table "$WORK/missing.img" "$WORK/empty.dump"
check "save_partition_table rejects a disk it cannot read" "1" "$?"
[[ -s $WORK/empty.dump ]]
check "a failed dump is not accepted as a snapshot" "1" "$?"

partition_starts_and_sizes "$WORK/missing.img" >/dev/null
check "partition_starts_and_sizes reports an unreadable disk" "1" "$?"

build_disk
before=$(partition_starts_and_sizes "$IMG")
dump="$WORK/table.dump"
save_partition_table "$IMG" "$dump"
check "snapshot of a real table succeeds" "0" "$?"

restore_shrunk_partitions "$IMG" "" "$before"
check "no snapshot is 'cannot tell', not 'fine'" "3" "$?"
restore_shrunk_partitions "$IMG" "$WORK/empty.dump" "$before"
check "an empty snapshot is 'cannot tell', not 'fine'" "3" "$?"

# The restore itself can fail — a disk that went away mid-session, an sfdisk
# that refuses the dump. The shrink is real and still on the table at that
# point, so this must never look like the untouched-table case.
echo "==> a shrink that cannot be undone stops the install"

build_disk
before=$(partition_starts_and_sizes "$IMG")
echo "not an sfdisk dump" >"$WORK/corrupt.dump"
shrink_first_partition_sectors 400000
restore_shrunk_partitions "$IMG" "$WORK/corrupt.dump" "$before" >/dev/null 2>&1
check "a failed restore is reported as a failed restore" "2" "$?"
[[ $(layout) == "$before" ]]
check "the shrink is still on the table after a failed restore" "1" "$?"

build_disk
before=$(partition_starts_and_sizes "$IMG")
dump="$WORK/table.dump"
save_partition_table "$IMG" "$dump"
truncate -s 0 "$IMG"
restore_shrunk_partitions "$IMG" "$dump" "$before"
check "a table that will not read back is 'cannot tell', not 'fine'" "3" "$?"

if (( failures > 0 )); then
  printf '\n%d check(s) failed\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
