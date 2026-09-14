# shellcheck shell=bash
# Omarchy's own Limine setup: the bootloader files, the EFI boot entry, the
# /etc/default/limine + kernel cmdline the final limine-update consumes, and
# the pre-reboot validation. Full-disk installs take partitions and the
# cmdline from archinstall-bash's parsed state; protected installs from
# omarchy_install.storage.

configure_limine_boot() {
  arch_bootloader_enabled || return 0
  arch_is_limine || fail 'Omarchy installs only support Limine bootloader setup'

  info '› installing bootloader (Limine)'
  if disk_is_pre_mount; then
    install_pre_mounted_limine
  else
    install_limine_omarchy
  fi

  info '› writing Limine config'
  if disk_is_pre_mount; then
    write_pre_mounted_limine_defaults
  else
    write_limine_defaults_from_config
  fi
}

install_limine_omarchy() {
  local boot efi root
  boot=$(installer_get_boot_partition) || fail "Could not detect boot at mountpoint $CTX_TARGET"
  root=$(installer_get_root) || fail "Could not detect root at mountpoint $CTX_TARGET"

  if arch_has_uefi; then
    efi=$(installer_get_efi_partition) || fail 'Could not detect EFI partition'
    [[ -n ${PART_MOUNTPOINT[efi]} ]] || fail 'EFI partition is not mounted'
    install_limine_efi "${PART_MOUNTPOINT[efi]}" "$(get_parent_device_path "${PART_DEVPATH[efi]}")" \
      "${PART_PARTN[efi]}" "$CFG_BOOT_REMOVABLE"
  else
    install_limine_bios "${PART_DEVPATH[boot]}"
  fi
}

install_pre_mounted_limine() {
  local esp_device disk part pre_state windows_before windows_after
  esp_device=$(storage_intent esp_device)
  [[ -n $esp_device ]] || fail 'omarchy_install.storage.esp_device missing'

  pre_state=$(read_efibootmgr)
  windows_before=$(find_label_entries "$pre_state" Windows)
  read -r disk part < <(split_partition_device "$esp_device")
  install_limine_efi "$(boot_intent esp_mount)" "$disk" "$part" false \
    "$(boot_intent esp_path)" "$(boot_intent efi_binary)" "$pre_state"

  windows_after=$(find_label_entries "$(read_efibootmgr)" Windows)
  if [[ -n $windows_before && -z $windows_after ]]; then
    fail 'Windows boot entry disappeared during Limine install — aborting'
  fi
}

# install_limine_efi <esp_mount> <disk> <part> <removable> [esp_path] [efi_binary] [pre_state]
install_limine_efi() {
  local esp_mount=$1 disk=$2 part=$3 removable=${4:-false} esp_path=${5:-/EFI/limine} efi_binary=${6:-limine_x64.efi} pre_state=${7:-}
  if [[ $removable == true ]]; then
    esp_path=/EFI/BOOT
    efi_binary=BOOTX64.EFI
  fi

  local source_name=BOOTX64.EFI
  local target_path="${esp_mount%/}/${esp_path#/}/$efi_binary"
  copy_required "$CTX_TARGET/usr/share/limine/$source_name" "$CTX_TARGET/${target_path#/}"

  write_limine_pacman_hook "/usr/bin/cp /usr/share/limine/$source_name $target_path"

  local loader="${esp_path#/}/$efi_binary"
  loader="\\${loader//\//\\}"
  register_limine_efi_entry "$disk" "$part" "$loader" "$pre_state"
}

# register_limine_efi_entry <disk> <part> <loader> [pre_state]: replace any
# stale Limine entry and put the new one first in the boot order.
register_limine_efi_entry() {
  local disk=$1 part=$2 loader=$3 pre_state=${4:-} num stale limine_num post_state keep=() order
  [[ -n $pre_state ]] || pre_state=$(read_efibootmgr)
  stale=$(find_label_entries "$pre_state" Limine)
  for num in $stale; do
    efibootmgr --bootnum "$num" --delete-bootnum >/dev/null 2>&1 || true
  done

  efibootmgr --create --disk "$disk" --part "$part" --label Limine --loader "$loader" --unicode --verbose

  post_state=$(read_efibootmgr)
  limine_num=$(find_label_entries "$post_state" Limine | head -n1)
  [[ -n $limine_num ]] || fail 'efibootmgr --create reported success but no Limine entry found'

  order=$(efibootmgr_order "$pre_state")
  for num in ${order//,/ }; do
    list_contains "$stale" "$num" && continue
    [[ $num == "$limine_num" ]] && continue
    efibootmgr_has_entry "$pre_state" "$num" || continue
    keep+=("$num")
  done
  efibootmgr --bootorder "$(IFS=,; echo "$limine_num${keep[*]:+,${keep[*]}}")" >/dev/null 2>&1
}

install_limine_bios() {
  local boot_dev=$1 boot_limine="$CTX_TARGET/boot/limine" parent unique
  mkdir -p "$boot_limine"
  parent=$(get_parent_device_path "$boot_dev")
  unique=$(get_unique_path_for_device "$parent") && parent=$unique
  copy_required "$CTX_TARGET/usr/share/limine/limine-bios.sys" "$boot_limine/limine-bios.sys"
  arch-chroot "$CTX_TARGET" limine bios-install "$parent"
  write_limine_pacman_hook "/usr/bin/limine bios-install $parent && /usr/bin/cp /usr/share/limine/limine-bios.sys /boot/limine/"
}

copy_required() {
  local src=$1 dst=$2
  [[ -e $src ]] || fail "Required Limine file missing: $src"
  mkdir -p "${dst%/*}"
  cp -p "$src" "$dst"
}

write_limine_pacman_hook() {
  local hook_command=$1 hooks_dir="$CTX_TARGET/etc/pacman.d/hooks"
  mkdir -p "$hooks_dir"
  cat >"$hooks_dir/99-omarchy-limine.hook" <<HOOK
[Trigger]
Operation = Upgrade
Type = Package
Target = limine

[Action]
Description = Deploying Omarchy Limine after upgrade...
When = PostTransaction
Exec = /bin/sh -c "$hook_command"
HOOK
}

write_limine_defaults_from_config() {
  arch_is_limine || return 0
  local root cmdline
  root=$(installer_get_root) || fail "Could not detect root at mountpoint $CTX_TARGET"
  cmdline=$(installer_get_kernel_params "$root")
  write_limine_defaults "$cmdline" "$(installer_esp_mount)"
}

# write_limine_defaults <cmdline> <esp_mount> [enable_fallback true|false]
write_limine_defaults() {
  local cmdline=$1 esp_mount=$2 enable_fallback=${3:-} default_text
  [[ -n ${cmdline// /} ]] || fail 'Could not compute kernel cmdline from install config'
  [[ $cmdline == *root=* ]] || fail "Computed cmdline has no root=: '$cmdline'"

  default_text=$(<"$(limine_template default.conf)")
  default_text=${default_text//@@CMDLINE@@/$cmdline}
  default_text=$(sed -E "s|^ESP_PATH=.*$|ESP_PATH=\"$esp_mount\"|" <<<"$default_text")
  if [[ -n $enable_fallback ]]; then
    default_text+=$'\n'"ENABLE_LIMINE_FALLBACK=$([[ $enable_fallback == true ]] && printf yes || printf no)"
  fi
  if ! arch_has_uefi; then
    default_text+=$'\nENABLE_UKI=no\nENABLE_LIMINE_FALLBACK=no'
  fi

  mkdir -p "$CTX_TARGET/etc/default" "$CTX_TARGET/etc/kernel"
  printf '%s\n' "$default_text" >"$CTX_TARGET/etc/default/limine"
  printf '%s\n' "$cmdline" >"$CTX_TARGET/etc/kernel/cmdline"

  local limine_conf="$CTX_TARGET/${esp_mount#/}/limine.conf"
  mkdir -p "${limine_conf%/*}"
  cp -p "$(limine_template limine.conf)" "$limine_conf"
}

installer_esp_mount() {
  local efi
  if efi=$(installer_get_efi_partition) && [[ -n ${PART_MOUNTPOINT[efi]} ]]; then
    printf '%s' "${PART_MOUNTPOINT[efi]}"
  else
    printf '/boot'
  fi
}

limine_template() {
  local filename=$1 candidate
  for candidate in \
    "$CTX_TARGET/usr/share/omarchy/install/assets/limine/$filename" \
    "$CTX_TARGET/usr/share/omarchy/default/limine/$filename" \
    "$CTX_OMARCHY_PATH/install/assets/limine/$filename" \
    "$CTX_OMARCHY_PATH/default/limine/$filename"; do
    [[ -e $candidate ]] && { printf '%s' "$candidate"; return 0; }
  done
  fail "Limine template $filename not found. Searched: $CTX_TARGET/usr/share/omarchy/{install/assets,default}/limine/$filename, $CTX_OMARCHY_PATH/{install/assets,default}/limine/$filename"
}

# ── efibootmgr ───────────────────────────────────────────────────────────────
# A snapshot is the text: one "NNNN<TAB>label" line per entry, then
# "ORDER<TAB>a,b,c".

read_efibootmgr() {
  local out
  out=$(efibootmgr) || fail 'efibootmgr failed'
  awk '
    match($0, /^Boot([0-9A-Fa-f]{4})\*?[[:space:]]+(.*)$/, m) { printf "%s\t%s\n", toupper(m[1]), m[2]; next }
    match($0, /^BootOrder:[[:space:]]*(.*)$/, m) { order = toupper(m[1]) }
    END { gsub(/ /, "", order); printf "ORDER\t%s\n", order }
  ' <<<"$out"
}

# Entry numbers whose label contains the needle (case-insensitive).
find_label_entries() {
  awk -F'\t' -v needle="$(tr '[:upper:]' '[:lower:]' <<<"$2")" '$1 != "ORDER" && index(tolower($2), needle) { print $1 }' <<<"$1"
}

efibootmgr_order() {
  awk -F'\t' '$1 == "ORDER" { print $2 }' <<<"$1"
}

efibootmgr_has_entry() {
  awk -F'\t' -v n="$2" '$1 == n { found = 1 } END { exit !found }' <<<"$1"
}

split_partition_device() {
  local part_dev=$1 parent num
  parent=$(lsblk -ndo PKNAME "$part_dev") && [[ -n $parent ]] || fail "could not find parent disk for $part_dev"
  num=$(lsblk -ndo PARTN "$part_dev") && [[ -n $num ]] || fail "could not find partition number for $part_dev"
  printf '/dev/%s %s\n' "$parent" "$num"
}

# ─────────────────────────────────────────────────────────────────────────────
# finalize_limine_boot: after target system setup has written all dynamic
# boot drop-ins (hibernation, hardware quirks, protected-mode ESP settings).
# ─────────────────────────────────────────────────────────────────────────────

finalize_limine_boot() {
  [[ -e $CTX_TARGET/usr/bin/limine-update ]] || fail '/usr/bin/limine-update missing in target'

  local default_limine="$CTX_TARGET/etc/default/limine" default_text config_text cmdline esp_path esp_root
  [[ -e $default_limine ]] || fail "$default_limine missing"
  default_text=$(<"$default_limine")
  [[ $default_text != *@@CMDLINE@@* ]] || fail "$default_limine still contains @@CMDLINE@@"

  config_text=$(limine_combined_config_text "$default_text")
  cmdline=$(limine_kernel_cmdline "$config_text")
  [[ -n ${cmdline// /} ]] || fail "$default_limine has no KERNEL_CMDLINE[default]+= line"
  [[ $cmdline == *root=* ]] || fail "cmdline parsed from $default_limine has no root=: $cmdline"

  esp_path=$(limine_setting "$config_text" ESP_PATH /boot)
  [[ -n $esp_path ]] || esp_path=/boot
  esp_root="$CTX_TARGET/${esp_path#/}"
  [[ -d $esp_root ]] || fail "Limine ESP_PATH does not exist in target: $esp_root"

  [[ -e $CTX_TARGET/etc/snapper/configs/root ]] || fail "$CTX_TARGET/etc/snapper/configs/root missing"

  local limine_conf="$esp_root/limine.conf"
  [[ -e $limine_conf ]] || fail "$limine_conf missing"

  arch-chroot "$CTX_TARGET" limine-update

  arch-chroot "$CTX_TARGET" btrfs quota disable / >/dev/null 2>&1 || true
  grep -q Omarchy "$limine_conf" || fail "$limine_conf has no Omarchy entry"
  if [[ $cmdline == *cryptdevice=* ]] && ! grep -q 'cryptdevice=' "$limine_conf"; then
    fail "encrypted install but $limine_conf has no cryptdevice="
  fi
}

strip_shell_quotes() {
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  if ((${#v} >= 2)) && [[ ${v:0:1} == "${v: -1}" && ( ${v:0:1} == '"' || ${v:0:1} == "'" ) ]]; then
    v=${v:1:${#v}-2}
  fi
  printf '%s' "$v"
}

# limine-entry-tool's config stack, lowest priority first; /etc/default/limine last.
limine_combined_config_text() {
  local default_text=$1 path
  for path in "$CTX_TARGET"/usr/share/limine-entry-tool.d/*.conf; do
    [[ -f $path ]] && { cat "$path"; echo; }
  done
  [[ -f $CTX_TARGET/etc/limine-entry-tool.conf ]] && { cat "$CTX_TARGET/etc/limine-entry-tool.conf"; echo; }
  for path in "$CTX_TARGET"/etc/limine-entry-tool.d/*.conf; do
    [[ -f $path ]] && { cat "$path"; echo; }
  done
  printf '%s\n' "$default_text"
}

# limine_setting <config_text> <name> [fallback]: the last assignment wins.
limine_setting() {
  local config_text=$1 name=$2 value=${3:-} line
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*"$name"[[:space:]]*=(.*)$ ]]; then
      value=$(strip_shell_quotes "${BASH_REMATCH[1]}")
    fi
  done <<<"$config_text"
  printf '%s' "$value"
}

limine_kernel_cmdline() {
  local config_text=$1 line part parts=()
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*KERNEL_CMDLINE\[default\]\+=(.*)$ ]]; then
      part=$(strip_shell_quotes "${BASH_REMATCH[1]}")
      part=${part#"${part%%[![:space:]]*}"}
      part=${part%"${part##*[![:space:]]}"}
      [[ -n $part ]] && parts+=("$part")
    fi
  done <<<"$config_text"
  printf '%s' "${parts[*]:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# validate_boot: hard checks before reboot. If the install ran but produced a
# boot config or UKI that can't actually boot, halt here rather than surprise
# the user.
# ─────────────────────────────────────────────────────────────────────────────

validate_boot() {
  assert_boot_hooks_restored

  local esp_mount limine_conf
  esp_mount="$CTX_TARGET/$(boot_intent_rel esp_mount)"
  limine_conf="$esp_mount/limine.conf"
  [[ -e $limine_conf ]] || fail "$limine_conf missing"
  grep -q Omarchy "$limine_conf" || fail "$limine_conf has no Omarchy entry"
  if [[ $CTX_ENCRYPT == true ]] && ! grep -q 'cryptdevice=' "$limine_conf"; then
    fail "Encrypted install but $limine_conf has no cryptdevice="
  fi

  [[ -e $CTX_TARGET/etc/kernel/cmdline ]] || fail "$CTX_TARGET/etc/kernel/cmdline missing — UKI would have no cmdline"

  local config_text uki_prefix kernel
  config_text=$(limine_combined_config_text "$(<"$CTX_TARGET/etc/default/limine")")
  uki_prefix=$(limine_setting "$config_text" CUSTOM_UKI_NAME omarchy)
  [[ -n $uki_prefix ]] || uki_prefix=omarchy
  kernel=$(storage_intent kernel)
  [[ -n $kernel ]] || kernel=$(user_configuration_get '.kernels[0]')
  [[ -n $kernel ]] || kernel=linux

  if arch_has_uefi; then
    local limine_binary
    limine_binary="$esp_mount/$(boot_intent_rel esp_path)/$(boot_intent efi_binary)"
    [[ -s $limine_binary ]] || fail "$limine_binary missing or empty"

    # Hardware packages (omarchy-hw-intel-ptl, …) can swap the kernel out from
    # under us mid-install, so trust what's on disk over what we asked for and
    # only fall back to the configured name when nothing's there.
    local -a candidates ukis=()
    mapfile -t candidates < <(installed_kernels)
    ((${#candidates[@]})) || candidates=("$kernel")
    local name found=0
    for name in "${candidates[@]}"; do
      ukis+=("$esp_mount/EFI/Linux/${uki_prefix}_$name.efi")
      [[ -s $esp_mount/EFI/Linux/${uki_prefix}_$name.efi ]] && found=1
    done
    ((found)) || fail "$(IFS=' / '; echo "${ukis[*]}") missing or empty"

    [[ -n $(find_label_entries "$(read_efibootmgr)" Limine) ]] || fail "no 'Limine' entry registered in efibootmgr"
  fi

  if [[ $CTX_IS_PROTECTED == true ]]; then
    validate_pre_mounted_filesystems
  fi
  if [[ $CTX_DEFER_PROVISIONING == true ]]; then
    validate_provisioning_state
  fi
}

# A deferred-provisioning install that boots without a working first-boot
# setup is a user-less brick; insist the armed state is complete before reboot.
validate_provisioning_state() {
  local provisioning_dir="$CTX_TARGET/$PROVISION_STATE_DIR"
  [[ -e $provisioning_dir/pending ]] || fail "deferred-provisioning install but $provisioning_dir/pending is missing"
  [[ -L $CTX_TARGET/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service ]] ||
    fail 'deferred-provisioning install but omarchy-provision-owner.service is not enabled'
  compgen -G "$provisioning_dir/packages/node-v*.tar.gz" >/dev/null ||
    fail "deferred-provisioning install but no Node tarball staged in $provisioning_dir/packages"

  if provision_install_encrypted; then
    local required
    for required in "$provisioning_dir/luks-key" "$CTX_TARGET/$PROVISION_KEYFILE"; do
      [[ -e $required ]] || fail "encrypted deferred-provisioning install but $required is missing"
    done
    grep -q 'cryptkey=rootfs:' "$CTX_TARGET/$(boot_intent_rel esp_mount)/limine.conf" ||
      fail 'encrypted deferred-provisioning install but limine.conf has no cryptkey= for auto-unlock'
  fi
}

# Never hand over a system whose UKI rebuild hook is still masked.
#
# run_system_finalizer defers 90-mkinitcpio-install.hook inside the target and
# restores it afterwards, but a mask that survived would be invisible until
# the first kernel update shipped a UKI-less boot. Repair, then insist.
assert_boot_hooks_restored() {
  cleanup_target_hook_masks

  local hooks_dir="$CTX_TARGET/etc/pacman.d/hooks" name path backup
  for name in "${TARGET_DEFERRED_BOOT_HOOKS[@]}"; do
    path="$hooks_dir/$name"
    backup="$hooks_dir/$name.omarchy-backup"
    ! is_devnull_symlink "$path" || fail "$path is still masked to /dev/null"
    [[ ! -e $backup && ! -L $backup ]] || fail "$backup left behind by the install-time hook mask"
    # limine-mkinitcpio-hook is a hard dependency of the Omarchy runtime
    # package, so the real hook is on disk before the mask ever goes up and
    # must be on disk again now.
    [[ -f $path ]] || fail "$path is missing — future kernel updates would ship no UKI"
  done
}

# Every kernel package leaves its pkgbase next to its modules, which is also
# the name limine-mkinitcpio-hook builds the UKI under.
installed_kernels() {
  local pkgbase name seen=''
  for pkgbase in "$CTX_TARGET"/usr/lib/modules/*/pkgbase; do
    [[ -f $pkgbase ]] || continue
    name=$(ctx_read_env_file "$pkgbase")
    [[ -n $name ]] || continue
    list_contains "$seen" "$name" && continue
    seen+="$name "
    printf '%s\n' "$name"
  done
}

validate_pre_mounted_filesystems() {
  local fstab="$CTX_TARGET/etc/fstab" btrfs_uuid esp_uuid luks_uuid
  [[ -e $fstab ]] || fail "$fstab missing"
  btrfs_uuid=$(blkid_uuid "$(btrfs_root_device)")
  esp_uuid=$(blkid_uuid "$(esp_device)")
  grep -qF "$btrfs_uuid" "$fstab" || fail "$fstab missing btrfs UUID $btrfs_uuid"
  grep -qF "$esp_uuid" "$fstab" || fail "$fstab missing ESP UUID $esp_uuid"

  luks_uuid=$(storage_intent luks_uuid)
  if [[ -n $luks_uuid ]]; then
    local crypttab="$CTX_TARGET/etc/crypttab.initramfs"
    [[ -e $crypttab ]] || fail "$crypttab missing"
    grep -qF "$luks_uuid" "$crypttab" || fail "$crypttab missing LUKS UUID $luks_uuid"
  fi
}
