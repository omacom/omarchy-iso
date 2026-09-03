# shellcheck shell=bash
# Port of lib/disk/utils.py: lsblk lookups, mount/umount, udev sync.

LSBLK_COLUMNS='PATH,NAME,PKNAME,TYPE,FSTYPE,SIZE,MOUNTPOINTS,FSROOTS,PARTN,PARTUUID,PARTTYPE,UUID,PTTYPE,LOG-SEC'

udev_sync() {
  udevadm settle 2>/dev/null || debug 'udevadm settle failed'
}

# lsblk_value <dev> <column>: first line of one column for the device itself.
lsblk_value() {
  lsblk -dnro "$2" -- "$1" 2>/dev/null | head -n1
}

# All mountpoints of a device (one per line).
lsblk_mountpoints() {
  lsblk -dnro MOUNTPOINTS -- "$1" 2>/dev/null | tr ' ' '\n' | sed '/^$/d'
}

# get_parent_device_path()
get_parent_device_path() {
  local pk
  pk=$(lsblk_value "$1" PKNAME)
  [[ -n $pk ]] || die "could not determine parent device of $1"
  printf '/dev/%s' "$pk"
}

# get_unique_path_for_device(): prefer /dev/disk/by-id/wwn-* / nvme-eui.*,
# else any by-id link, else nothing.
get_unique_path_for_device() {
  local dev=$1 link target
  local -a matches=()
  [[ -d /dev/disk/by-id ]] || return 1
  for link in /dev/disk/by-id/*; do
    target=$(readlink -f "$link") || continue
    [[ $target == "$dev" ]] || continue
    matches+=("$link")
  done
  ((${#matches[@]})) || return 1
  for link in "${matches[@]}"; do
    case ${link##*/} in
      wwn-*|nvme-eui.*) printf '%s' "$link"; return 0 ;;
    esac
  done
  printf '%s' "${matches[0]}"
}

# disk_mount <dev> <mountpoint> [options,comma,separated] [fstype]
disk_mount() {
  local dev=$1 target=$2 options=${3:-} fstype=${4:-}
  mkdir -p "$target"
  if lsblk_mountpoints "$dev" | grep -qx "$target"; then
    info "Device already mounted at $target"
    return 0
  fi
  local -a cmd=(mount)
  [[ -n $options ]] && cmd+=(-o "$options")
  [[ -n $fstype ]] && cmd+=(-t "$fstype")
  cmd+=("$dev" "$target")
  debug "Mounting $dev: ${cmd[*]}"
  sys_cmd "${cmd[@]}" || die "Could not mount $dev: ${cmd[*]}"$'\n'"$SYS_CMD_OUTPUT"
}

# disk_umount_dev <dev> [recursive]: unmount every mountpoint of a device.
disk_umount_dev() {
  local dev=$1 recursive=${2:-} mp
  local -a cmd=(umount)
  [[ -n $recursive ]] && cmd+=(-R)
  while read -r mp; do
    [[ -n $mp ]] || continue
    debug "Unmounting mountpoint: $mp"
    sys_cmd "${cmd[@]}" "$mp" || die "Could not unmount $mp: $SYS_CMD_OUTPUT"
  done < <(lsblk_mountpoints "$dev")
}

disk_swapon() {
  sys_cmd swapon "$1" || die "Could not enable swap $1: $SYS_CMD_OUTPUT"
}

# Sizes via lsblk (sysfs) so --dry-run works unprivileged.
disk_size_bytes() {
  local n
  n=$(lsblk -dnbro SIZE -- "$1" 2>/dev/null | head -n1)
  [[ -n $n ]] || die "could not determine the size of $1"
  printf '%s' "$n"
}

disk_sector_size() {
  local n
  n=$(lsblk -dnro LOG-SEC -- "$1" 2>/dev/null | head -n1 | tr -d ' ')
  [[ -n $n ]] || n=512
  printf '%s' "$n"
}

# linux_root_guid()
linux_root_guid() {
  if [[ $(machine_arch) == aarch64 ]]; then
    printf 'B921B045-1DF0-41C3-AF44-4C6F280D3FAE'
  else
    printf '4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709'
  fi
}

GPT_TYPE_ESP='C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
GPT_TYPE_XBOOTLDR='BC13C2FF-59E6-4262-A352-B275FD6F7172'
GPT_TYPE_LINUX_HOME='933AC7E1-2EB4-4F13-B844-0E14E2AEF915'
GPT_TYPE_LINUX_SWAP='0657FD6D-A4AB-43C4-84E5-0933C84B4F4F'
GPT_TYPE_LINUX_FS='0FC63DAF-8483-4772-8E79-3D69D8477DE4'
