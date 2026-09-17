# LVM discovery helpers, shared by the ISO configurator and its tests.
#
# The rule here is: never offer a volume that something is already using. LVM
# hands out device-mapper paths that look identical whether the volume is a
# spare the owner carved out for us or the root of the system they booted to
# run this installer. Nothing about /dev/pool/root says "do not format me", so
# every candidate is checked against the live mount table before it reaches
# the picker.
#
# Sourced, not executed. The four lvm_*_report functions are the only place
# these helpers touch the system, so tests override those and exercise
# everything above them without root, LVM, or a disk.

# Physical volumes and the group they belong to, one "pv_name|vg_name" per
# line. A PV not yet in a group reports an empty vg_name and is skipped.
lvm_pv_report() {
  pvs --noheadings --separator '|' -o pv_name,vg_name 2>/dev/null
}

# Logical volumes in a group, one "lv_path|lv_name|size_in_bytes" per line.
lvm_lv_report() {
  lvs --noheadings --separator '|' --units b --nosuffix \
    -o lv_path,lv_name,lv_size --select "vg_name=$1" 2>/dev/null
}

# Filesystem type and label on a device, as "fstype|label". Empty when the
# device holds no recognized filesystem, which is the normal state for the
# spare volume this mode expects to be pointed at.
lvm_fs_report() {
  lsblk -nro FSTYPE,LABEL "$1" 2>/dev/null | head -1 | tr ' ' '|'
}

# Where the kernel publishes block devices. Overridable so tests can point it
# at a fixture tree instead of the running machine's.
LVM_SYSFS_BLOCK="${LVM_SYSFS_BLOCK:-/sys/class/block}"

# Where those devices appear as nodes. Holders are reported by kernel name, so
# they have to be rejoined to a directory to be comparable with a mount source.
LVM_DEV_DIR="${LVM_DEV_DIR:-/dev}"

# Every device the live system currently has mounted, one per line, plus
# anything it is using as swap. findmnt covers mounts; /proc/swaps covers the
# swap volume, which is in use just as surely but appears in no mount table.
lvm_busy_devices() {
  findmnt -rno SOURCE 2>/dev/null
  awk 'NR > 1 { print $1 }' /proc/swaps 2>/dev/null
}

# Trim the leading and trailing whitespace lvs and pvs pad their columns with.
_lvm_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Does this partition belong to the disk we are installing to?
#
# Plain prefix matching is wrong here, and wrong in a way that picks the wrong
# disk rather than failing: /dev/nvme0n10p1 starts with /dev/nvme0n1 followed
# by a digit, so a naive "$disk"[0-9]* claims another disk's partitions — and
# /dev/nvme0n10 itself, a whole disk, matches too. What is left after the disk
# name must be a partition number and nothing else, and on nvme/mmcblk it must
# carry the p separator that partition_path() writes.
_lvm_on_disk() {
  local part="$1" disk="$2" suffix
  [[ $part == "$disk" ]] && return 0

  suffix="${part#"$disk"}"
  [[ $suffix != "$part" ]] || return 1

  if [[ $disk == *nvme* || $disk == *mmcblk* ]]; then
    [[ $suffix == p* ]] || return 1
    suffix="${suffix#p}"
  fi

  [[ -n $suffix && $suffix != *[![:digit:]]* ]]
}

# Volume groups with at least one physical volume on this disk, deduplicated
# and sorted. A group spanning several disks is reported for each of them.
volume_groups_on_disk() {
  local disk="$1" pv vg
  while IFS='|' read -r pv vg; do
    pv=$(_lvm_trim "$pv")
    vg=$(_lvm_trim "$vg")
    [[ -n $pv && -n $vg ]] || continue
    _lvm_on_disk "$pv" "$disk" || continue
    printf '%s\n' "$vg"
  done < <(lvm_pv_report) | sort -u
}

disk_has_lvm() {
  [[ -n $(volume_groups_on_disk "$1") ]]
}

# Is this device backing the running system? A true answer disqualifies it from
# every role: formatting the live root destroys the installer mid-run, and
# mounting a device twice corrupts the filesystem on it. Takes any block
# device, not only a logical volume — the ESP is checked through here too.
# A device and everything stacked on top of it, as canonical paths.
#
# Comparing mount sources against the device alone is not enough: a logical
# volume with a LUKS mapping opened on it is not itself mounted — its child is.
# findmnt reports /dev/mapper/data while the volume is /dev/pool/data, two
# different dm nodes, so a check that stops at the volume clears it and mkfs
# runs underneath a live filesystem. Holders are how the kernel records that
# relationship, and they nest: LUKS on LV, LVM on LUKS, bcache, raid.
device_and_holders() {
  local device="$1" resolved name queue current holder
  resolved=$(readlink -f "$device" 2>/dev/null || printf '%s' "$device")
  printf '%s\n' "$resolved"

  name="${resolved##*/}"
  [[ -n $name && -d "$LVM_SYSFS_BLOCK/$name" ]] || return 0

  queue=("$name")
  while ((${#queue[@]} > 0)); do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    for holder in "$LVM_SYSFS_BLOCK/$current"/holders/*; do
      [[ -e $holder ]] || continue
      holder="${holder##*/}"
      printf '%s/%s\n' "$LVM_DEV_DIR" "$holder"
      queue+=("$holder")
    done
  done
}

device_is_busy() {
  local candidates busy_list candidate busy
  candidates=$(device_and_holders "$1")
  busy_list=$(lvm_busy_devices)

  while IFS= read -r busy; do
    [[ -n $busy ]] || continue
    busy=$(readlink -f "$busy" 2>/dev/null || printf '%s' "$busy")
    while IFS= read -r candidate; do
      [[ -n $candidate ]] || continue
      [[ $busy == "$candidate" ]] && return 0
    done <<<"$candidates"
  done <<<"$busy_list"
  return 1
}

# Filesystems an adopted volume can actually be mounted from. An allow-list
# rather than "the type is not empty": crypto_LUKS and LVM2_member are
# non-empty types naming a container, not a filesystem, and mounting either
# fails — after run_lvm_execute has already formatted the root volume.
LVM_MOUNTABLE_FSTYPES="ext2 ext3 ext4 btrfs xfs f2fs"

fstype_is_mountable() {
  [[ -n $1 ]] && [[ " $LVM_MOUNTABLE_FSTYPES " == *" $1 "* ]]
}

# Logical volumes in a group, one record per line:
#
#   lv_path|lv_name|size_bytes|fstype|label|busy
#
# busy is "busy" or empty. Callers filter on it rather than re-deriving it,
# so the picker and the validation that follows agree on one answer.
logical_volumes() {
  local vg="$1" path name size fstype label busy
  while IFS='|' read -r path name size; do
    path=$(_lvm_trim "$path")
    name=$(_lvm_trim "$name")
    size=$(_lvm_trim "$size")
    [[ -n $path ]] || continue

    IFS='|' read -r fstype label < <(lvm_fs_report "$path")
    busy=""
    device_is_busy "$path" && busy="busy"

    printf '%s|%s|%s|%s|%s|%s\n' "$path" "$name" "$size" "$fstype" "$label" "$busy"
  done < <(lvm_lv_report "$vg")
}

# One line of a logical_volumes record, formatted for the gum picker. The path
# leads so the caller can recover it with awk '{print $1}', the way disk_form
# already recovers a disk from its display string.
describe_lv() {
  local record="$1" path name size fstype label busy display
  IFS='|' read -r path name size fstype label busy <<<"$record"

  display="$path"
  [[ -n $size ]] && display+=" ($(awk -v b="$size" 'BEGIN { printf "%.1fGB", b / 1024 / 1024 / 1024 }'))"
  if [[ -n $fstype ]]; then
    display+=" - $fstype"
    [[ -n $label ]] && display+=" \"$label\""
  else
    display+=" - empty"
  fi
  [[ -n $busy ]] && display+=" [in use — cannot select]"

  printf '%s\n' "$display"
}
