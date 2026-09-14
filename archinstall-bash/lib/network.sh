# shellcheck shell=bash
# Port of Installer.copy_iso_network_config() — network_config type "iso", the
# only type Omarchy uses. nm / nm_iwd / iwd / manual are not ported.

# install_network_config(network_config.type)
network_install_config() {
  local type=${1:-$CFG_NETWORK_TYPE}
  case $type in
    iso) installer_copy_iso_network_config enable_services ;;
    '') ;;
    *) die "network_config type \"$type\" is not supported by this port (iso only)" ;;
  esac
}

# Installer.copy_iso_network_config(enable_services)
installer_copy_iso_network_config() {
  local enable_services=${1:-} f
  if compgen -G '/var/lib/iwd/*.psk' >/dev/null; then
    mkdir -p "$INST_TARGET/var/lib/iwd"
    for f in /var/lib/iwd/*.psk; do
      cp -p "$f" "$INST_TARGET/var/lib/iwd/"
    done
    if [[ -n $enable_services ]]; then
      pacman_strap iwd
      installer_enable_service iwd
    fi
  fi

  installer_systemd_resolved_stub_mode

  if compgen -G '/etc/systemd/network/*' >/dev/null; then
    mkdir -p "$INST_TARGET/etc/systemd/network"
    for f in /etc/systemd/network/*; do
      cp -p "$f" "$INST_TARGET/etc/systemd/network/"
    done
    [[ -n $enable_services ]] && installer_enable_service systemd-networkd systemd-resolved
  fi
  return 0
}
