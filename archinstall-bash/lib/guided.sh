# shellcheck shell=bash
# Port of scripts/guided.py: the installation sequence driven by a loaded
# configuration. The interactive menu is not ported — a configuration file is
# required. No bootloader is installed (the caller does that, as Omarchy's
# orchestrator installs Limine itself from installer_get_kernel_params and the
# partition lookups) and archinstall's sanity-check waits (NTP, reflector,
# keyring WKD) are skipped, which is how Omarchy runs archinstall (offline,
# skip_ntp, skip_wkd).

ARGS_MOUNTPOINT=/mnt
ARGS_DRY_RUN=0

# perform_installation()
guided_perform_installation() {
  local start=$SECONDS
  info 'Starting installation...'

  if [[ $DISK_CONFIG_PRESENT != true ]]; then
    error 'No disk configuration provided'
    return 1
  fi

  local mountpoint=${DISK_MOUNTPOINT:-$ARGS_MOUNTPOINT}

  installer_init "$mountpoint" "${CFG_KERNELS[@]}"

  disk_is_pre_mount || installer_mount_ordered_layout

  [[ $CFG_HAS_MIRROR_CONFIG == true ]] && installer_set_mirrors live

  installer_minimal_installation

  [[ $CFG_HAS_MIRROR_CONFIG == true ]] && installer_set_mirrors on_target

  [[ $CFG_SWAP_ENABLED == true ]] && installer_setup_swap

  if [[ -n $CFG_BOOTLOADER && $CFG_BOOTLOADER != no_bootloader ]]; then
    warn "bootloader $CFG_BOOTLOADER requested but this port installs no bootloader; the caller must (Omarchy's orchestrator installs Limine itself)"
  fi

  [[ -n $CFG_NETWORK_TYPE ]] && network_install_config "$CFG_NETWORK_TYPE"

  ((${#USER_NAME[@]})) && installer_create_users

  [[ $CFG_HAS_APP_CONFIG == true ]] && applications_install

  if ((${#CFG_PACKAGES[@]})) && [[ -n ${CFG_PACKAGES[0]} ]]; then
    installer_add_additional_packages "${CFG_PACKAGES[@]}"
  fi

  [[ -n $CFG_TIMEZONE ]] && { installer_set_timezone "$CFG_TIMEZONE" || true; }

  [[ $CFG_NTP == true ]] && installer_activate_time_synchronization

  accessibility_tools_in_use && installer_enable_espeakup

  [[ -n $CFG_ROOT_ENC_PASSWORD ]] && { installer_set_user_password root "$CFG_ROOT_ENC_PASSWORD" || true; }

  ((${#CFG_SERVICES[@]})) && installer_enable_service "${CFG_SERVICES[@]}"

  ((${#CFG_CUSTOM_COMMANDS[@]})) && installer_run_custom_user_commands "${CFG_CUSTOM_COMMANDS[@]}"

  installer_genfstab

  debug "Disk states after installing:"$'\n'"$(lsblk 2>/dev/null)"

  local rc=0
  installer_finish || rc=$?
  info "Installation took $((SECONDS - start)) seconds."
  return $rc
}

# main()
guided_main() {
  config_save

  if ((ARGS_DRY_RUN)); then
    info 'Dry run: configuration parsed, nothing was written to disk.'
    config_summary
    return 0
  fi

  if [[ $DISK_CONFIG_PRESENT == true ]]; then
    fs_perform_filesystem_operations
  fi

  guided_perform_installation
}
