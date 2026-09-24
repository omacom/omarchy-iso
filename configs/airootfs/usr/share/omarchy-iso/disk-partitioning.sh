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
# On-disk GPT identity for each partition this run created. A partition number
# can be reused, so cleanup must not treat that number alone as ownership.
declare -A created_part_identities=()
# A successful mkpart is uncertain until the new number and stable identity are
# known. Rollback must report incomplete cleanup rather than guess after a
# post-write discovery failure.
created_partition_write_uncertain=false

# Set by create_partition() instead of being printed: a command substitution
# would run it in a subshell and lose the created_parts bookkeeping.
created_partition_number=""

# Keep protected entries, including their byte ranges, for checks before writes
# and rollback. On BitLocker disks this is the whole original table. On a
# live-media disk it is the mounted source and every ESP, so the restricted
# editor can free data partitions without removing a possible boot loader.
protected_disk=""
protected_partition_table=""
declare -A protected_part_identities=()

gpt_partition_uuid() {
  local id
  id=$(sfdisk --part-uuid "$1" "$2" 2>/dev/null) || return 1
  [[ $id =~ ^[[:xdigit:]-]{36}$ ]] || return 1
  printf '%s\n' "${id,,}"
}

protect_existing_partitions() {
  local table entry num identity
  table=$(parted -ms "$1" unit B print) || return 1
  [[ $table == *':gpt:'* ]] || return 1
  protected_partition_table=$(printf '%s\n' "$table" | grep -E '^[0-9]+:')
  [[ -n $protected_partition_table ]] || return 1
  protected_part_identities=()
  while IFS= read -r entry; do
    num=${entry%%:*}
    identity=$(gpt_partition_uuid "$1" "$num") || return 1
    protected_part_identities[$num]="$identity"
  done <<<"$protected_partition_table"
  protected_disk="$1"
}

protect_install_media_partitions() {
  local disk="$1" source="$2" table number entry type identity
  table=$(parted -ms "$disk" unit B print) || return 1
  [[ $table == *':gpt:'* ]] || return 1
  number=$(lsblk -dnro PARTN "$source" 2>/dev/null) || return 1
  [[ $number =~ ^[0-9]+$ ]] || return 1
  protected_partition_table=$(printf '%s\n' "$table" | grep -E "^${number}:") || return 1
  [[ -n $protected_partition_table && $protected_partition_table != *$'\n'* ]] || return 1
  protected_part_identities=()
  identity=$(gpt_partition_uuid "$disk" "$number") || return 1
  protected_part_identities[$number]="$identity"
  while IFS= read -r entry; do
    [[ $entry =~ ^[0-9]+: ]] || continue
    # Read the on-disk GPT type, not a filesystem label or stale kernel node.
    type=$(sfdisk --part-type "$disk" "${entry%%:*}" 2>/dev/null) || return 1
    if [[ ${entry%%:*} != "$number" && ${type,,} == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]]; then
      identity=$(gpt_partition_uuid "$disk" "${entry%%:*}") || return 1
      protected_partition_table+=$'\n'"$entry"
      protected_part_identities[${entry%%:*}]="$identity"
    fi
  done <<<"$table"
  protected_disk="$disk"
}

verify_existing_partitions() {
  [[ "$1" == "$protected_disk" ]] || return 0
  local table entry num identity
  table=$(parted -ms "$1" unit B print) || return 1
  [[ $table == *':gpt:'* ]] || return 1
  while IFS= read -r entry; do
    grep -Fxq "$entry" <<<"$table" || return 1
    num=${entry%%:*}
    [[ -n ${protected_part_identities[$num]:-} ]] || return 1
    identity=$(gpt_partition_uuid "$1" "$num") || return 1
    [[ $identity == "${protected_part_identities[$num]}" ]] || return 1
  done <<<"$protected_partition_table"
}

is_existing_partition() {
  [[ "$1" == "$protected_disk" ]] &&
    grep -q "^$2:" <<<"$protected_partition_table"
}

# The live-media editor only deletes an explicitly selected, inactive GPT
# entry. It cannot open cfdisk on the source disk, where cfdisk could erase the
# mounted ISO before a post-edit safety check runs.
partition_is_idle() {
  local device="$1" mounts holders
  # Descendant mountpoints count too (for example, a LUKS mapping).
  mounts=$(lsblk -nr -o MOUNTPOINTS "$device" 2>/dev/null) || return 1
  [[ -z $(tr -d '[:space:]' <<<"$mounts") ]] || return 1
  # An unmounted partition may still back dm-crypt, LVM, or MD. Failure to
  # inspect the kernel holder directory is also unsafe.
  holders=$(find "/sys/class/block/${device##*/}/holders" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) || return 1
  [[ -z $holders ]]
}

delete_unprotected_partition() {
  local disk="$1" num="$2" expected="$3" expected_identity="$4"
  local device current identity
  [[ $disk == "$protected_disk" && $num =~ ^[0-9]+$ && -n $expected_identity ]] || return 1
  verify_existing_partitions "$disk" || return 1
  is_existing_partition "$disk" "$num" && return 1
  current=$(parted -ms "$disk" unit B print | grep -E "^${num}:") || return 1
  [[ $current == "$expected" ]] || return 1
  identity=$(created_partition_identity "$disk" "$num") || return 1
  [[ $identity == "$expected_identity" ]] || return 1
  device=$(partition_path "$disk" "$num")
  partition_is_idle "$device" || return 1
  parted --script "$disk" rm "$num" || return 1
  partprobe "$disk" 2>/dev/null || true
  sync
  verify_existing_partitions "$disk"
}

created_partition_identity() {
  local disk="$1" num="$2" table geometry id
  table=$(parted -ms "$disk" unit B print) || return 1
  geometry=$(awk -F: -v n="$num" '
    $1 == n { gsub(/B/, "", $2); gsub(/B/, "", $4); print $2 ":" $4; found=1; exit }
    END { if (!found) exit 1 }' <<<"$table") || return 1
  [[ $geometry =~ ^[0-9]+:[0-9]+$ ]] || return 1
  if [[ $table == *':gpt:'* ]]; then
    id=$(gpt_partition_uuid "$disk" "$num") || return 1
    printf 'gpt:%s:%s\n' "$id" "$geometry"
  elif [[ $table == *':msdos:'* ]]; then
    # MBR has no per-partition UUID. Disk ID plus geometry is the strongest
    # stable identity available and still catches replaced extents.
    id=$(sfdisk --disk-id "$disk" 2>/dev/null) || return 1
    [[ $id =~ ^0x[[:xdigit:]]{8}$ ]] || return 1
    printf 'mbr:%s:%s\n' "${id,,}" "$geometry"
  else
    return 1
  fi
}

verify_created_partition() {
  local disk="$1" num="$2" identity
  [[ -n ${created_part_identities[$num]:-} ]] || return 1
  identity=$(created_partition_identity "$disk" "$num") || return 1
  [[ $identity == "${created_part_identities[$num]}" ]]
}

verify_partition_device() {
  local disk="$1" num="$2" device="$3" start size kernel_start kernel_size
  is_existing_partition "$disk" "$num" && return 1
  [[ " ${created_parts[*]} " == *" $num "* ]] || return 1
  verify_created_partition "$disk" "$num" || return 1
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

# Create one partition and report the number parted actually assigned. Before
# attempting mkpart, flag the write until its number and identity are known so
# rollback reports incomplete cleanup instead of guessing what to remove.
create_partition() {
  local disk="$1" start="$2" end="$3" fstype="$4" name="$5"
  local before after before_layout after_layout num actual want tolerance identity
  local -a new_parts=()

  created_partition_number=""

  # Never let a later attempt clear unresolved state from an earlier write.
  $created_partition_write_uncertain && return 1

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

  before_layout=$(sfdisk --dump "$disk") || return 1
  created_partition_write_uncertain=true
  if ! parted --script "$disk" mkpart primary "$fstype" "${start}B" "${end}B"; then
    # parted can write the table and then fail to notify the kernel. Only an
    # unchanged table proves that this failed attempt needs no cleanup.
    if after_layout=$(sfdisk --dump "$disk") && [[ $after_layout == "$before_layout" ]]; then
      created_partition_write_uncertain=false
    fi
    return 1
  fi
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true

  after=$(partition_numbers "$disk" | sort)
  mapfile -t new_parts < <(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after"))
  (( ${#new_parts[@]} == 1 )) || return 1
  num=${new_parts[0]}
  [[ $num =~ ^[0-9]+$ ]] || return 1

  # The number must be genuinely new. This is the safety property that keeps a
  # numbering mistake from ever formatting a partition somebody else is using;
  # it is cheaper and more reliable than sniffing the target for signatures,
  # which would false-positive on remnants left in freed space.
  grep -qx "$num" <<<"$before" && return 1

  # From here the number is known, even if a later identity lookup fails.
  # Keeping it in the report does not authorize rollback without an identity.
  created_parts+=("$num")
  identity=$(created_partition_identity "$disk" "$num") || return 1
  created_part_identities[$num]="$identity"
  created_partition_write_uncertain=false

  verify_existing_partitions "$disk" || return 1

  actual=$(partition_size_bytes "$disk" "$num")
  [[ -n $actual ]] || return 1
  want=$((end - start))
  tolerance=$((1024 * 1024))
  (( actual >= want - tolerance && actual <= want + tolerance )) || return 1

  parted --script "$disk" name "$num" "$name" || true

  created_partition_number="$num"
}

# Undo the partitions this run created, highest number first. Scoped strictly
# to created_parts: without this, a failed install leaves the user's freed
# space occupied by orphans, and the retry reports "not enough free space"
# with no way to connect that to what just happened.
rollback_created_parts() {
  local disk="$1" n
  $created_partition_write_uncertain && return 1
  (( ${#created_parts[@]} > 0 )) || return 0
  # Leave recovery to the user if any number now refers to different data.
  verify_existing_partitions "$disk" || return 1
  for n in "${created_parts[@]}"; do
    is_existing_partition "$disk" "$n" && return 1
    verify_created_partition "$disk" "$n" || return 1
  done
  for n in $(printf '%s\n' "${created_parts[@]}" | sort -rn); do
    verify_created_partition "$disk" "$n" || return 1
    parted --script "$disk" rm "$n" >/dev/null 2>&1 || return 1
  done
  partprobe "$disk" 2>/dev/null || true
  created_parts=()
  created_part_identities=()
  created_partition_write_uncertain=false
}
