# shellcheck shell=bash
# Port of lib/applications/application_handler.py with the audio
# (applications/audio.py) and bluetooth (applications/bluetooth.py) installers.

PIPEWIRE_PACKAGES=(pipewire pipewire-alsa pipewire-jack pipewire-pulse gst-plugin-pipewire libpulse wireplumber)
BLUETOOTH_PACKAGES=(bluez bluez-utils)

# ApplicationHandler.install_applications(): users get the PipeWire units.
applications_install() {
  [[ $CFG_BLUETOOTH == true ]] && applications_install_bluetooth
  if [[ -n $CFG_AUDIO && $CFG_AUDIO != 'No audio server' ]]; then
    applications_install_audio "$CFG_AUDIO" "${USER_NAME[@]}"
  fi
  return 0
}

# BluetoothApp.install()
applications_install_bluetooth() {
  debug 'Installing Bluetooth'
  installer_add_additional_packages "${BLUETOOTH_PACKAGES[@]}"
  installer_enable_service bluetooth.service
}

# AudioApp.install(audio, users...)
applications_install_audio() {
  local audio=$1
  shift
  debug "Installing audio server: $audio"
  sysinfo_requires_sof_fw && installer_add_additional_packages sof-firmware
  sysinfo_requires_alsa_fw && installer_add_additional_packages alsa-firmware
  [[ $audio == pipewire ]] || die "audio server $audio is not supported by this port (pipewire only)"
  installer_add_additional_packages "${PIPEWIRE_PACKAGES[@]}"
  applications_enable_pipewire "$@"
}

# AudioApp._enable_pipewire(): pipewire-pulse in each user's default.target.
applications_enable_pipewire() {
  local user dir
  for user in "$@"; do
    dir="$INST_TARGET/home/$user/.config/systemd/user/default.target.wants"
    mkdir -p "$dir"
    chroot_cmd chown -R "$user:$user" "/home/$user" || die "chown /home/$user failed: $SYS_CMD_OUTPUT"
    chroot_cmd_as "$user" "ln -sf /usr/lib/systemd/user/pipewire-pulse.service /home/$user/.config/systemd/user/default.target.wants/pipewire-pulse.service" ||
      die "could not enable pipewire-pulse.service for $user: $SYS_CMD_OUTPUT"
    chroot_cmd_as "$user" "ln -sf /usr/lib/systemd/user/pipewire-pulse.socket /home/$user/.config/systemd/user/default.target.wants/pipewire-pulse.socket" ||
      die "could not enable pipewire-pulse.socket for $user: $SYS_CMD_OUTPUT"
  done
}
