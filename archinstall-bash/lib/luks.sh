# shellcheck shell=bash
# Port of lib/disk/luks.py (Luks2). Passphrases are piped on stdin as
# --key-file - so they are used byte for byte, exactly as archinstall feeds
# the plaintext on stdin: no trailing newline, so the typed passphrase at boot
# and Omarchy's staged provisioning key match the slot.

luks_is_luks() {
  cryptsetup isLuks "$1" >/dev/null 2>&1
}

luks_erase() {
  debug "Erasing luks partition: $1"
  sys_cmd cryptsetup --batch-mode erase "$1" || warn "cryptsetup erase $1 failed: $SYS_CMD_OUTPUT"
}

luks_is_unlocked() {
  [[ -L /dev/mapper/$1 ]]
}

# The block device behind an open mapper (cryptsetup status).
luks_mapper_backing_device() {
  cryptsetup status "$1" 2>/dev/null | awk '/^[[:space:]]*device:/ { print $2; exit }'
}

# Whether mapper $1 is open *on* device $2. Upstream only checks that the
# mapper path exists, which on a host that already has a /dev/mapper/root
# would mount the host's root into the target.
luks_is_unlocked_on() {
  local mapper=$1 dev=$2 backing
  luks_is_unlocked "$mapper" || return 1
  backing=$(luks_mapper_backing_device "$mapper")
  [[ -n $backing && $(readlink -f "$backing") == $(readlink -f "$dev") ]]
}

# luks_format <dev> <password> [iter_time]
luks_format() {
  local dev=$1 password=$2 iter_time=${3:-$ENC_ITER_TIME}
  [[ -n $password ]] || die 'Password for luks2 device was not specified'
  debug "Luks2 encrypting: $dev"
  sys_cmd_input "$password" cryptsetup --batch-mode --verbose --type luks2 --pbkdf argon2id --hash sha512 \
    --key-size 512 --iter-time "$iter_time" --sector-size 4096 --use-urandom --key-file - luksFormat "$dev" ||
    die "Could not encrypt volume \"$dev\": $SYS_CMD_OUTPUT"
}

# luks_unlock <dev> <mapper_name> <password> [key_file]
luks_unlock() {
  local dev=$1 mapper=$2 password=$3 key_file=${4:-}
  [[ -n $mapper ]] || die 'mapper name missing'
  luks_is_unlocked "$mapper" &&
    die "/dev/mapper/$mapper already exists (backed by $(luks_mapper_backing_device "$mapper")); close it before installing"
  debug "Unlocking luks2 device: $dev"
  if [[ -n $key_file ]]; then
    sys_cmd cryptsetup open "$dev" "$mapper" --key-file "$key_file" --type luks2 ||
      die "Could not unlock luks2 device \"$dev\": $SYS_CMD_OUTPUT"
  else
    [[ -n $password ]] || die 'Password for luks2 device was not specified'
    sys_cmd_input "$password" cryptsetup open "$dev" "$mapper" --key-file - --type luks2 ||
      die "Could not unlock luks2 device \"$dev\": $SYS_CMD_OUTPUT"
  fi
  luks_is_unlocked "$mapper" || die "Failed to open luks2 device: $dev"
}

# unlock_luks2_dev(): unlock unless already open.
luks_unlock_if_needed() {
  local dev=$1 mapper=$2 password=$3
  luks_is_unlocked_on "$mapper" "$dev" && return 0
  luks_is_unlocked "$mapper" &&
    die "/dev/mapper/$mapper already exists and is backed by $(luks_mapper_backing_device "$mapper"), not $dev; close it first"
  luks_unlock "$dev" "$mapper" "$password"
}

# Luks2.lock(): unmount the device, then unmount + close every mapper child.
luks_lock() {
  local dev=$1 child mp
  disk_umount_dev "$dev"
  while read -r child; do
    [[ -n $child ]] || continue
    while read -r mp; do
      [[ -n $mp ]] || continue
      debug "Unmounting $mp"
      sys_cmd umount -R "$mp" || die "Could not unmount $mp: $SYS_CMD_OUTPUT"
    done < <(lsblk_mountpoints "/dev/mapper/$child")
    debug "Closing crypt device $child"
    sys_cmd cryptsetup close "$child" || die "Could not close $child: $SYS_CMD_OUTPUT"
  done < <(lsblk -nro NAME,TYPE -- "$dev" 2>/dev/null | awk '$2 == "crypt" { print $1 }')
}
