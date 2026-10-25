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
  local table
  table=$(parted -ms "$1" unit B print 2>/dev/null) || return 1
  printf '%s\n' "$table" | tail -n +3 | cut -d: -f1
}

partition_size_bytes() {
  parted -ms "$1" unit B print 2>/dev/null |
    awk -F: -v n="$2" '$1 == n { gsub(/B/, "", $4); print $4; exit }'
}

# The disk's partition table type ("gpt", "msdos", ...), or nothing on a disk
# with no table, which the free-space install answers with mklabel gpt over
# the whole disk: a partitioned disk taken for a blank one loses every
# partition. parted decides, because it is what runs mklabel and reads the
# table from the disk itself ("unknown" when there is none). blkid's probe and
# lsblk are witnesses after it, so a disk counts as blank only when none of the
# three finds a table. lsblk alone answers from udev's database, which has no
# PTTYPE for a disk udev has not finished probing, and both lsblk and blkid
# skip the table on a disk that carries a stale RAID member signature.
partition_table_type() {
  local pt_type
  pt_type=$(parted -ms "$1" print 2>/dev/null | sed -n 2p | cut -d: -f6)
  [[ $pt_type == unknown ]] && pt_type=""
  [[ -n $pt_type ]] || pt_type=$(blkid -p -s PTTYPE -o value "$1" 2>/dev/null || true)
  [[ -n $pt_type ]] || pt_type=$(lsblk -dno PTTYPE "$1" 2>/dev/null || true)
  printf '%s\n' "$pt_type"
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

  # Both reads must succeed. If only the first failed, every existing
  # partition would look new, and one the size of the requested partition (an
  # earlier install's 2GiB ESP) would be taken for it and formatted.
  before=$(partition_numbers "$disk") || return 1

  parted --script "$disk" mkpart primary "$fstype" "${start}B" "${end}B" || return 1
  partprobe "$disk" 2>/dev/null || true
  udevadm settle 2>/dev/null || true

  after=$(partition_numbers "$disk") || return 1
  # Exactly one partition more than before, or something else moved.
  (( $(grep -c . <<<"$after") == $(grep -c . <<<"$before") + 1 )) || return 1

  # Lexicographic sort on both sides: comm needs its inputs ordered the same
  # way it compares them, and `sort -n` (1, 2, 10) is not that order.
  num=$(comm -13 <(sort <<<"$before") <(sort <<<"$after") | head -1)
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

# The disks the installer offers, one per line, in the order the disk screen
# lists them. gum highlights the first entry, so that is the default a user
# confirms with Enter: internal disks come first, then removable and USB ones
# (a stick or a KVM's virtual storage left plugged in, an SD card), each group
# in lsblk's order. Leaves out the boot medium's disk ($1), disks with no
# medium, which report size 0 (an empty card reader, a KVM's virtual optical
# drive), and an eMMC's boot and RPMB areas. An SD card in a PCIe reader
# reports RM 0 and TRAN mmc, like the eMMC a laptop boots from; only its MMC
# card type, SD, tells them apart. TRAN is the last column because it is
# empty for some disks (xvd, hd).
install_disk_candidates() {
  local exclude=${1:-} sysfs=${SYSFS_BLOCK:-/sys/block}
  local name type size removable tran external n=0
  lsblk -dbpno NAME,TYPE,SIZE,RM,TRAN |
    while read -r name type size removable tran; do
      n=$((n + 1))
      [[ $type == disk && $size -gt 0 && $name != "$exclude" ]] || continue
      [[ $name =~ ^/dev/(sd|hd|vd|nvme|mmcblk|xv) ]] || continue
      [[ $name =~ ^/dev/mmcblk[0-9]+(boot[0-9]+|rpmb)$ ]] && continue
      external=0
      if [[ $removable == 1 || $tran == usb ]] ||
        [[ $(cat "$sysfs/${name##*/}/device/type" 2>/dev/null) == SD ]]; then
        external=1
      fi
      printf '%s\t%s\t%s\n' "$external" "$n" "$name"
    done |
    sort -k1,1n -k2,2n | cut -f3
}

# The install modes for the disk screen's choice, the default first, as the
# names select_installation acts on. On a disk that already holds partitions
# ($2 of them) the default is the free-space install, which keeps them; the
# full-disk install, which erases them, is one key away. $1 is whether the
# free-space mode is on offer at all (UEFI, a partition table and room for
# Omarchy).
install_mode_choices() {
  local free_space_offered=$1 partitions=${2:-0}
  if [[ $free_space_offered == true ]] && ((partitions > 0)); then
    printf '%s\n' free_space full_disk
  elif [[ $free_space_offered == true ]]; then
    printf '%s\n' full_disk free_space
  else
    printf '%s\n' full_disk
  fi
  printf '%s\n' other_disk
}
