# Disk partitioning helpers, shared by the ISO configurator and its tests.
#
# The rule here is: never predict a partition number. parted fills the lowest
# free GPT slot, not "highest existing + 1", so any disk whose numbering has a
# hole — exactly what deleting a partition to free space leaves behind, which
# is what our own partition tool tells the user to do — hands back a number we
# did not choose. Everything below reads back what was actually created.
#
# Sourced, not executed. The configurator defines abort() and
# disk_abort_hook(); tests get the plain fallbacks.

# Partitions this run created, in creation order. rollback_created_parts()
# undoes exactly these and nothing else.
created_parts=()

# Set by create_partition() instead of being printed: a command substitution
# would run it in a subshell and lose the created_parts bookkeeping.
created_partition_number=""

# Compute partition device path, handling NVMe/mmcblk's pN naming.
partition_path() {
  local _disk="$1" _num="$2"
  if [[ "$_disk" == *nvme* || "$_disk" == *mmcblk* ]]; then
    echo "${_disk}p${_num}"
  else
    echo "${_disk}${_num}"
  fi
}

# Partition numbers as the on-disk GPT reports them. parted rather than lsblk
# on purpose: this is the table parted itself is about to modify, so discovery
# never depends on the kernel having re-read the partition table yet — and the
# same code works against an image file in tests, where lsblk sees nothing.
partition_numbers() {
  parted -ms "$1" unit B print 2>/dev/null | tail -n +3 | cut -d: -f1
}

partition_size_bytes() {
  parted -ms "$1" unit B print 2>/dev/null |
    awk -F: -v n="$2" '$1 == n { gsub(/B/, "", $4); print $4; exit }'
}

# Fail loudly. The former version looped over sleep and returned its status,
# so a device that never appeared was indistinguishable from one that did.
wait_for_device() {
  local i
  for i in $(seq 1 10); do
    [[ -b "$1" ]] && return 0
    udevadm settle 2>/dev/null || true
    sleep 1
  done
  return 1
}

_disk_abort() {
  if declare -F disk_abort_hook >/dev/null; then
    disk_abort_hook "$1"
  elif declare -F abort >/dev/null; then
    abort "$1"
  fi
  echo "Error: $1" >&2
  exit 1
}

# Run a disk-writing command, fold its stderr into stdout, and abort on a
# non-zero exit. The fold matters: .automated_script.sh tees stdout into
# /var/log/omarchy-install.log but sends stderr straight to the tty (gum draws
# its TUI there), so an unwrapped failure leaves no trace in the log the user
# uploads — and the configurator's next screen clears it off the display too.
disk_step() {
  local desc="$1"
  shift
  local output status=0
  output=$("$@" 2>&1) || status=$?
  [[ -n $output ]] && printf '%s\n' "$output"
  (( status == 0 )) && return 0
  _disk_abort "$desc failed (exit $status)"
}

# Create one partition and report the number parted actually assigned.
# Returns non-zero without touching created_parts if anything looks wrong;
# the caller decides how loudly to fail.
create_partition() {
  local disk="$1" start="$2" end="$3" fstype="$4" name="$5"
  local before after num actual want tolerance

  created_partition_number=""

  # Lexicographic sort on both sides: comm needs its inputs ordered the same
  # way it compares them, and `sort -n` (1, 2, 10) is not that order.
  before=$(partition_numbers "$disk" | sort)

  parted --script "$disk" mkpart primary "$fstype" "${start}B" "${end}B" || return 1
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true

  after=$(partition_numbers "$disk" | sort)
  num=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
  [[ -n $num ]] || return 1

  # The number must be genuinely new. This is the safety property that keeps a
  # numbering mistake from ever formatting a partition somebody else is using;
  # it is cheaper and more reliable than sniffing the target for signatures,
  # which would false-positive on remnants left in freed space.
  grep -qx "$num" <<<"$before" && return 1

  actual=$(partition_size_bytes "$disk" "$num")
  [[ -n $actual ]] || return 1
  want=$((end - start))
  tolerance=$((1024 * 1024))
  (( actual >= want - tolerance && actual <= want + tolerance )) || return 1

  parted --script "$disk" name "$num" "$name" || true

  created_parts+=("$num")
  created_partition_number="$num"
}

# Start sector and size in bytes for every partition, one "start size" line.
# Start is the identity cfdisk Resize preserves (it changes the end, not the
# start), so a later comparison can tell a shrink from a delete or a new
# partition in free space. parted rather than lsblk so this works against
# image files in tests, the same way partition_numbers does.
partition_starts_and_sizes() {
  local out
  # Judge parted by its exit status, not by what it printed. Reading the table
  # can fail, and a failure that arrives as empty output is indistinguishable
  # from a disk with no partitions — which reads as "nothing shrank" and is
  # exactly how a guard like this fails open. Capture first so the status is
  # parted's own and not awk's.
  out=$(parted -ms "$1" unit B print 2>/dev/null) || return 1
  printf '%s\n' "$out" | tail -n +3 | awk -F: '
    $1 ~ /^[0-9]+$/ {
      start=$2; size=$4;
      gsub(/B/, "", start);
      gsub(/B/, "", size);
      print start, size
    }'
}

# Lines of "start old_size new_size" for partitions that shrank by more than
# 1MiB. Matched by start sector so a delete (start gone) or a newly created
# partition (start unseen) is not a shrink. The 1MiB slack is the same
# alignment tolerance create_partition uses.
shrunk_partition_lines() {
  local before="$1" after="$2"
  awk -v tol=$((1024 * 1024)) '
    NR == FNR { old[$1] = $2; next }
    ($1 in old) && ((old[$1] - $2) > tol) { print $1, old[$1], $2 }
  ' <(printf '%s\n' "$before") <(printf '%s\n' "$after")
}

# Snapshot the GPT so a later cfdisk session can be undone. Fails when sfdisk
# fails or writes nothing usable (no table, sfdisk unavailable, unreadable
# disk): a partial dump would restore a table nobody verified, so the caller
# must treat a false here as "do not let cfdisk near this disk".
save_partition_table() {
  local disk="$1" dest="$2" status=0
  sfdisk -d "$disk" >"$dest" 2>/dev/null || status=$?
  (( status == 0 )) && [[ -s $dest ]]
}

# Rewrite the GPT from an sfdisk dump. Used to undo a cfdisk Resize: that
# command only changes the partition table, so putting the original table
# back is a full recovery as long as nothing has been written into the gap.
restore_partition_table() {
  local disk="$1" src="$2" output status=0
  output=$(sfdisk --force "$disk" <"$src" 2>&1) || status=$?
  [[ -n $output ]] && printf '%s\n' "$output"
  partprobe "$disk" 2>/dev/null || true
  return "$status"
}

# If any existing partition shrank, restore dump and return 0. Return 1 when
# the table is fine (delete/create/grow/no-op). Return 2 when a shrink was
# found but the dump could not be written back. Return 3 when the edit cannot
# be judged at all: no usable snapshot to compare against or restore from, or
# a table that no longer reads back.
#
# 3 must never collapse into 1. "Cannot tell" is precisely the state in which
# a shrink is invisible, and answering "the table is fine" there hands the
# installer a disk whose existing filesystem may already be past its new end.
restore_shrunk_partitions() {
  local disk="$1" dump="$2" before="$3" after shrunk
  [[ -n $dump && -s $dump ]] || return 3
  after=$(partition_starts_and_sizes "$disk") || return 3
  shrunk=$(shrunk_partition_lines "$before" "$after")
  [[ -n $shrunk ]] || return 1
  restore_partition_table "$disk" "$dump" || return 2
  return 0
}

# Undo the partitions this run created, highest number first. Scoped strictly
# to created_parts: without this, a failed install leaves the user's freed
# space occupied by orphans, and the retry reports "not enough free space"
# with no way to connect that to what just happened.
rollback_created_parts() {
  local disk="$1" n
  (( ${#created_parts[@]} > 0 )) || return 0
  for n in $(printf '%s\n' "${created_parts[@]}" | sort -rn); do
    parted --script "$disk" rm "$n" >/dev/null 2>&1 || true
  done
  partprobe "$disk" 2>/dev/null || true
  created_parts=()
}
