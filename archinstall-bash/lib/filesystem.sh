# shellcheck shell=bash
# Port of lib/disk/filesystem.py (FilesystemHandler) and the partitioning,
# formatting, encryption and btrfs parts of lib/disk/device_handler.py
# (DeviceHandler) for wiped disks. pyparted is replaced by sfdisk: the
# partition table is written declaratively and read back to learn the device
# nodes.

FS_TMP_BTRFS_MOUNT=/mnt/arch_btrfs

# DeviceHandler._partition_table: GPT on UEFI systems, MBR otherwise.
fs_partition_table() {
  if sysinfo_has_uefi; then printf 'gpt'; else printf 'dos'; fi
}

fs_type_known() {
  case $1 in
    btrfs|ext2|ext3|ext4|f2fs|fat12|fat16|fat32|ntfs|xfs|linux-swap|crypto_LUKS) return 0 ;;
    *) return 1 ;;
  esac
}

fs_installation_pkg() {
  case $1 in
    btrfs) printf 'btrfs-progs' ;;
    xfs) printf 'xfsprogs' ;;
    f2fs) printf 'f2fs-tools' ;;
    *) return 1 ;;
  esac
}

# FilesystemHandler.perform_filesystem_operations()
fs_perform_filesystem_operations() {
  if disk_is_pre_mount; then
    debug 'Disk layout configuration is set to pre-mount, not performing any operations'
    return 0
  fi

  local -a device_mods=()
  local d i
  for d in "${!DEV_PATH[@]}"; do
    disk_device_has_partitions "$d" && device_mods+=("$d")
  done
  if ((${#device_mods[@]} == 0)); then
    debug 'No modifications required'
    return 0
  fi

  for d in "${device_mods[@]}"; do
    fs_umount_all_existing "${DEV_PATH[d]}"
  done

  for d in "${device_mods[@]}"; do
    fs_partition_device "$d"
  done

  udev_sync

  for d in "${device_mods[@]}"; do
    fs_format_partitions "$d"
    for i in $(disk_partition_indexes_sorted "$d"); do
      [[ ${PART_FS[i]} == btrfs ]] && fs_create_btrfs_volumes "$i"
    done
  done
  return 0
}

# DeviceHandler.umount_all_existing()
fs_umount_all_existing() {
  local disk=$1 path fstype
  debug "Unmounting all existing partitions: $disk"
  while read -r path fstype; do
    [[ -n $path && $path != "$disk" ]] || continue
    debug "Unmounting: $path"
    if [[ $fstype == crypto_LUKS ]]; then
      luks_lock "$path"
    else
      disk_umount_dev "$path" recursive
    fi
  done < <(lsblk -rnpo PATH,FSTYPE -- "$disk" 2>/dev/null | awk '{ print $1, $2 }')
}

# DeviceHandler.wipe_dev(): erase LUKS headers, zero the first KiB of every
# partition and of the disk. Not secure erasure, just enough that nothing
# auto-detects the old layout.
fs_wipe_dev() {
  local disk=$1 path type
  info "Wiping partitions and metadata: $disk"
  while read -r path type; do
    [[ $type == part ]] || continue
    luks_is_luks "$path" && luks_erase "$path"
    fs_wipe_head "$path"
  done < <(lsblk -rnpo PATH,TYPE -- "$disk" 2>/dev/null)
  fs_wipe_head "$disk"
}

fs_wipe_head() {
  dd if=/dev/zero of="$1" bs=1024 count=1 conv=notrunc status=none 2>/dev/null || die "could not wipe $1"
}

# The partition type sfdisk should write (what _setup_partition expresses with
# parted flags, filesystem and the Linux root GUID).
fs_part_type_code() {
  local i=$1 table=$2
  if [[ $table == gpt ]]; then
    if part_is_efi "$i" || part_is_boot "$i"; then
      printf '%s' "$GPT_TYPE_ESP"
    elif list_contains "${PART_FLAGS[i]}" xbootldr; then
      printf '%s' "$GPT_TYPE_XBOOTLDR"
    elif part_is_root "$i"; then
      linux_root_guid
    elif list_contains "${PART_FLAGS[i]}" linux-home || part_is_home "$i"; then
      printf '%s' "$GPT_TYPE_LINUX_HOME"
    elif part_is_swap "$i" || list_contains "${PART_FLAGS[i]}" swap; then
      printf '%s' "$GPT_TYPE_LINUX_SWAP"
    else
      printf '%s' "$GPT_TYPE_LINUX_FS"
    fi
  else
    case ${PART_FS[i]} in
      fat12|fat16) printf 'e' ;;
      fat32) printf 'c' ;;
      linux-swap) printf '82' ;;
      ntfs) printf '7' ;;
      *) printf '83' ;;
    esac
  fi
}

# One sfdisk script line for partition $i on a disk with $2-byte sectors.
fs_sfdisk_line() {
  local i=$1 sector_size=$2 table=$3 line
  ((PART_START[i] % sector_size == 0)) || die "partition start ${PART_START[i]} is not a multiple of the sector size $sector_size"
  line="start=$((PART_START[i] / sector_size)), size=$(((PART_LENGTH[i] + sector_size - 1) / sector_size)), type=$(fs_part_type_code "$i" "$table")"
  if [[ $table == dos ]] && part_is_boot "$i"; then
    line+=', bootable'
  fi
  printf '%s\n' "$line"
}

# DeviceHandler.partition() for a wiped device: write the table and record the
# created partitions' device nodes.
fs_partition_device() {
  local d=$1 disk=${DEV_PATH[$1]} table sector_size i script='' n=0
  table=$(fs_partition_table)
  sector_size=$(disk_sector_size "$disk")

  local -a created=()
  for i in $(disk_partition_indexes_sorted "$d"); do
    created+=("$i")
    n=$((n + 1))
  done
  if [[ $table == dos ]] && ((n > 3)); then
    die 'Too many partitions on disk, MBR disks can only have 3 primary partitions'
  fi

  fs_wipe_dev "$disk"
  script="label: $table"$'\n'"unit: sectors"$'\n'
  for i in "${created[@]}"; do
    script+=$(fs_sfdisk_line "$i" "$sector_size" "$table")$'\n'
  done
  info "Creating partitions: $disk"
  debug "sfdisk script for $disk:"$'\n'"$script"
  fs_sfdisk "$disk" "$script" --wipe always --wipe-partitions always

  udev_sync
  fs_partprobe "$disk"

  # Read the table back and map each created partition to its node by start
  # sector (never predict a partition number).
  local start_sector node start
  for i in "${created[@]}"; do
    start_sector=$((PART_START[i] / sector_size))
    node=''
    while IFS=$'\x1f' read -r node start; do
      [[ $start == "$start_sector" ]] && break
      node=''
    done < <(sfdisk -J "$disk" | jq -r '.partitiontable.partitions[] | [.node, .start] | map(tostring) | join("\u001f")')
    [[ -n $node ]] || die "partition starting at sector $start_sector not found on $disk after partitioning"
    [[ -b $node ]] || { udev_sync; [[ -b $node ]] || die "partition device $node did not appear"; }
    PART_DEVPATH[i]=$node
    debug "Wiping signatures from: $node"
    sys_cmd wipefs --all "$node" || die "wipefs $node failed: $SYS_CMD_OUTPUT"
  done
  udev_sync
}

# Run sfdisk with a script on stdin. Writing the table races udev: probes
# triggered by the wipe can hold the disk open so the kernel refuses to
# re-read the new table ("Re-reading the partition table failed"). The table
# is on disk in that case; only the kernel's view is stale, so settle udev and
# ask for a re-read instead of failing (what Omarchy's orchestrator retried
# around with pyparted).
fs_sfdisk() {
  local disk=$1 script=$2 attempt
  shift 2
  if sys_cmd_input "$script" sfdisk "$@" "$disk"; then
    return 0
  fi
  case $SYS_CMD_OUTPUT in
    *'Re-reading the partition table failed'*|*'unable to inform the kernel'*|*'Device or resource busy'*)
      warn "kernel did not re-read the partition table of $disk immediately; retrying the re-read"
      for attempt in 1 2 3 4 5; do
        udev_sync
        sleep 1
        sys_cmd blockdev --rereadpt "$disk" && return 0
        debug "blockdev --rereadpt $disk attempt $attempt failed: $SYS_CMD_OUTPUT"
      done
      die "Unable to partition $disk: the kernel still uses the old partition table"
      ;;
  esac
  die "Unable to partition $disk: $SYS_CMD_OUTPUT"
}

# DeviceHandler.partprobe(): best effort.
fs_partprobe() {
  debug "Calling partprobe: partprobe $1"
  if ! sys_cmd partprobe "$1"; then
    if [[ $SYS_CMD_OUTPUT == *'have been written, but we have been unable to inform the kernel'* ]]; then
      info "Partprobe was not able to inform the kernel of the new disk state (ignoring error): $SYS_CMD_OUTPUT"
    else
      error "\"partprobe $1\" failed to run (continuing anyway): $SYS_CMD_OUTPUT"
    fi
  fi
}

# DeviceHandler.format()
fs_format() {
  local fs_type=$1 path=$2
  shift 2
  local -a cmd
  case $fs_type in
    btrfs|xfs) cmd=("mkfs.$fs_type" -f) ;;
    f2fs) cmd=(mkfs.f2fs -f -O extra_attr) ;;
    ext2|ext3|ext4) cmd=("mkfs.$fs_type" -F) ;;
    fat12|fat16|fat32) cmd=(mkfs.fat -F "${fs_type#fat}") ;;
    linux-swap) cmd=(mkswap) ;;
    *) die "Filetype \"$fs_type\" is not supported" ;;
  esac
  cmd+=("$@" "$path")
  debug "Formatting filesystem: ${cmd[*]}"
  sys_cmd "${cmd[@]}" || die "Could not format $path with $fs_type: $SYS_CMD_OUTPUT"
}

# DeviceHandler.format_encrypted(): luksFormat, open, mkfs on the mapper, close.
fs_format_encrypted() {
  local dev=$1 mapper=$2 fs_type=$3
  [[ -n $ENC_PASSWORD ]] || die 'No encryption password provided'
  luks_format "$dev" "$ENC_PASSWORD" "$ENC_ITER_TIME"
  udev_sync
  luks_unlock "$dev" "$mapper" "$ENC_PASSWORD"
  info "luks2 formatting mapper dev: /dev/mapper/$mapper"
  fs_format "$fs_type" "/dev/mapper/$mapper"
  info "luks2 locking device: $dev"
  luks_lock "$dev"
}

# FilesystemHandler._format_partitions()
fs_format_partitions() {
  local d=$1 i dev
  for i in $(disk_partition_indexes_sorted "$d"); do
    [[ -n ${PART_DEVPATH[i]} ]] || die 'When formatting, all partitions must have a path set'
    [[ ${PART_FS[i]} != crypto_LUKS ]] || die 'Crypto luks cannot be set as a filesystem type'
    [[ -n ${PART_FS[i]} ]] || die 'File system type must be set for modification'
  done
  for i in $(disk_partition_indexes_sorted "$d"); do
    dev=${PART_DEVPATH[i]}
    if part_is_encrypted "$i"; then
      fs_format_encrypted "$dev" "$(part_mapper_name "$i")" "${PART_FS[i]}"
    else
      fs_format "${PART_FS[i]}" "$dev"
    fi
    udev_sync
    fs_fetch_part_info "$i"
  done
}

# DeviceHandler.fetch_part_info(): partition number, PARTUUID and UUID.
fs_fetch_part_info() {
  local i=$1 dev=${PART_DEVPATH[$1]}
  PART_PARTN[i]=$(lsblk_value "$dev" PARTN)
  PART_PARTUUID[i]=$(lsblk_value "$dev" PARTUUID)
  PART_UUID[i]=$(lsblk_value "$dev" UUID)
  [[ -n ${PART_PARTN[i]} ]] || die "Unable to determine new partition number: $dev"
  [[ -n ${PART_PARTUUID[i]} ]] || die "Unable to determine new partition uuid: $dev"
  [[ -n ${PART_UUID[i]} ]] || die "Unable to determine new uuid: $dev"
  debug "partition information found: $dev partn=${PART_PARTN[i]} partuuid=${PART_PARTUUID[i]} uuid=${PART_UUID[i]}"
}

# DeviceHandler.create_btrfs_volumes()
fs_create_btrfs_volumes() {
  local i=$1 dev mapper='' sv name
  info "Creating subvolumes: ${PART_DEVPATH[i]}"
  if part_is_encrypted "$i"; then
    mapper=$(part_mapper_name "$i")
    [[ -n $mapper ]] || die 'No device path specified for modification'
    luks_unlock_if_needed "${PART_DEVPATH[i]}" "$mapper" "$ENC_PASSWORD"
    dev=/dev/mapper/$mapper
  else
    dev=${PART_DEVPATH[i]}
  fi

  disk_mount "$dev" "$FS_TMP_BTRFS_MOUNT" "${PART_MOUNT_OPTIONS[i]}"
  for sv in $(printf '%s\n' ${PART_SUBVOLS[i]} | sort); do
    name=${sv%%=*}
    debug "Creating subvolume: $name"
    sys_cmd btrfs subvolume create -p "$FS_TMP_BTRFS_MOUNT/$name" || die "Could not create subvolume $name: $SYS_CMD_OUTPUT"
  done
  disk_umount_dev "$dev"

  [[ -n $mapper ]] && luks_lock "${PART_DEVPATH[i]}"
  return 0
}
