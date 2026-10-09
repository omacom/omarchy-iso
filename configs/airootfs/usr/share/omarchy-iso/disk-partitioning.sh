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
#
# That same tee also reaches the tty, so a successful command's output goes to
# the log file alone: mkfs.btrfs, the subvolumes and mkfs.fat otherwise flash
# ~27 lines of text between two configurator screens.
disk_step() {
  local desc="$1"
  shift
  local output status=0
  output=$("$@" 2>&1) || status=$?
  if [[ -n $output ]]; then
    if (( status == 0 )) && [[ -n ${OMARCHY_INSTALL_LOG_FILE:-} ]]; then
      printf '%s\n' "$output" >>"$OMARCHY_INSTALL_LOG_FILE"
    else
      printf '%s\n' "$output"
    fi
  fi
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
