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

# Keep protected entries, including their byte ranges, for checks before writes
# and rollback. On BitLocker disks this is the whole original table. On a
# live-media disk it is the mounted source (and our temporary loader, if found),
# so the restricted editor can free other partitions without touching the ISO.
protected_disk=""
protected_partition_table=""

protect_existing_partitions() {
  local table
  table=$(parted -ms "$1" unit B print) || return 1
  [[ $table == *':gpt:'* ]] || return 1
  protected_partition_table=$(printf '%s\n' "$table" | grep -E '^[0-9]+:')
  [[ -n $protected_partition_table ]] || return 1
  protected_disk="$1"
}

protect_install_media_partitions() {
  local disk="$1" source="$2" table number entry device type label source_label loader_count=0
  table=$(parted -ms "$disk" unit B print) || return 1
  [[ $table == *':gpt:'* ]] || return 1
  number=$(lsblk -dnro PARTN "$source" 2>/dev/null) || return 1
  source_label=$(lsblk -dnro LABEL "$source" 2>/dev/null) || return 1
  [[ $number =~ ^[0-9]+$ ]] || return 1
  protected_partition_table=$(printf '%s\n' "$table" | grep -E "^${number}:")
  [[ $(printf '%s\n' "$protected_partition_table" | wc -l) -eq 1 ]] || return 1
  while IFS= read -r entry; do
    [[ $entry =~ ^[0-9]+: ]] || continue
    device=$(partition_path "$disk" "${entry%%:*}")
    type=$(lsblk -dnro PARTTYPE "$device" 2>/dev/null || true)
    label=$(lsblk -dnro LABEL "$device" 2>/dev/null || true)
    if [[ ${entry%%:*} != "$number" && ${type,,} == c12a7328-f81f-11d2-ba4b-00a0c93ec93b && $label == OMARCHY_TMP ]]; then
      protected_partition_table+=$'\n'"$entry"
      ((loader_count += 1))
    fi
  done <<<"$table"
  # Our staged NTFS source has a companion EFI loader with this volume label.
  # If it is missing or ambiguous, do not allow editing this disk.
  if [[ $source_label == OMARCHY_TMP && $loader_count -ne 1 ]]; then return 1; fi
  protected_disk="$disk"
}

verify_existing_partitions() {
  [[ "$1" == "$protected_disk" ]] || return 0
  local table entry
  table=$(parted -ms "$1" unit B print) || return 1
  [[ $table == *':gpt:'* ]] || return 1
  while IFS= read -r entry; do
    grep -Fxq "$entry" <<<"$table" || return 1
  done <<<"$protected_partition_table"
}

is_existing_partition() {
  [[ "$1" == "$protected_disk" ]] &&
    grep -q "^$2:" <<<"$protected_partition_table"
}

# The live-media editor only deletes an explicitly selected, unmounted GPT
# entry. It cannot open cfdisk on the source disk, where cfdisk could erase the
# mounted ISO before a post-edit safety check runs.
delete_unprotected_partition() {
  local disk="$1" num="$2" expected="$3" device current mounts
  [[ $disk == "$protected_disk" && $num =~ ^[0-9]+$ ]] || return 1
  verify_existing_partitions "$disk" || return 1
  is_existing_partition "$disk" "$num" && return 1
  current=$(parted -ms "$disk" unit B print | grep -E "^${num}:") || return 1
  [[ $current == "$expected" ]] || return 1
  device=$(partition_path "$disk" "$num")
  # Descendant mountpoints count too (for example, a LUKS mapping).
  mounts=$(lsblk -nr -o MOUNTPOINTS "$device" 2>/dev/null) || return 1
  [[ -z $(tr -d '[:space:]' <<<"$mounts") ]] || return 1
  parted --script "$disk" rm "$num" || return 1
  partprobe "$disk" 2>/dev/null || true
  sync
  verify_existing_partitions "$disk"
}

verify_partition_device() {
  local disk="$1" num="$2" device="$3" start size kernel_start kernel_size
  is_existing_partition "$disk" "$num" && return 1
  [[ " ${created_parts[*]} " == *" $num "* ]] || return 1
  read -r start size < <(parted -ms "$disk" unit B print |
    awk -F: -v n="$num" '$1 == n { gsub(/B/, "", $2); gsub(/B/, "", $4); print $2, $4 }')
  # sysfs reports these in 512-byte sectors, including on 4K-sector disks.
  kernel_start=$(cat "/sys/class/block/${device##*/}/start") || return 1
  kernel_size=$(cat "/sys/class/block/${device##*/}/size") || return 1
  [[ $start =~ ^[0-9]+$ && $size =~ ^[0-9]+$ &&
    $kernel_start =~ ^[0-9]+$ && $kernel_size =~ ^[0-9]+$ ]] || return 1
  (( start == kernel_start * 512 && size == kernel_size * 512 ))
}

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

  verify_existing_partitions "$disk" || return 1
  if [[ $disk == "$protected_disk" ]]; then
    # Check the proposed extent explicitly, as well as letting parted reject
    # overlap. Endpoints in parted's byte output are inclusive.
    local entry existing_start existing_end
    while IFS=: read -r entry existing_start existing_end _; do
      existing_start=${existing_start%B}
      existing_end=${existing_end%B}
      (( end < existing_start || start > existing_end )) || return 1
    done <<<"$protected_partition_table"
  fi

  # Lexicographic sort on both sides: comm needs its inputs ordered the same
  # way it compares them, and `sort -n` (1, 2, 10) is not that order.
  before=$(partition_numbers "$disk" | sort)

  parted --script "$disk" mkpart primary "$fstype" "${start}B" "${end}B" || return 1
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true

  after=$(partition_numbers "$disk" | sort)
  num=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1)
  [[ -n $num ]] || return 1

  verify_existing_partitions "$disk" || return 1

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
  # If somebody changed the layout, partition numbers may have been reused.
  # Leave recovery to the user rather than risk deleting existing data.
  verify_existing_partitions "$disk" || return 1
  for n in $(printf '%s\n' "${created_parts[@]}" | sort -rn); do
    is_existing_partition "$disk" "$n" && return 1
    parted --script "$disk" rm "$n" >/dev/null 2>&1 || true
  done
  partprobe "$disk" 2>/dev/null || true
  created_parts=()
}
