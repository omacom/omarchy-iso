#!/bin/bash
#
# Networking for the configurator.
#
# The mirrored ISO carries every package it installs, so it has never needed a
# connection and the wizard has never asked for one. netinstall media install
# from the network mirrors instead (see builder/build-iso.sh), which turns a
# working connection into a precondition of the install rather than a nicety.
# This is the step that gets one, from the keyboard the user is already typing
# on.
#
# iwd is what the live environment runs — archiso's releng profile enables
# iwd.service — and iwctl is how it is driven. There is no NetworkManager on
# the medium, so there is no nmtui or nmcli to lean on, and the wizard cannot
# assume the machine has a cable.
#
# Shared with test/unit/netinstall-network-test.sh, which stubs pacman, iwctl
# and gum and drives the whole step through a fake connection.

MEDIA_MODE_FILE="${OMARCHY_MEDIA_FILE:-/root/omarchy_media}"
PACMAN_CONF="${OMARCHY_PACMAN_CONF:-/etc/pacman.conf}"
NETWORK_CHECK_DB="${OMARCHY_NETWORK_CHECK_DB:-/tmp/omarchy-network-check}"
SYSFS_NET="${OMARCHY_SYSFS_NET:-/sys/class/net}"
WIFI_SCAN_WAIT="${OMARCHY_WIFI_SCAN_WAIT:-4}"

# Only netinstall media install from the network; every other medium carries
# what it needs and must not be held up by this.
installs_from_network() {
  [[ -r $MEDIA_MODE_FILE ]] || return 1
  [[ $(<"$MEDIA_MODE_FILE") == netinstall ]]
}

# Reachability is decided by doing the install's own first network operation:
# fetching the package databases over TLS from the Omarchy mirrors, into a
# scratch database directory so nothing else is disturbed. A resolver answer
# alone passes on a captive portal, and this is the check whose failure would
# otherwise surface minutes into pacstrap.
network_reachable() {
  command -v pacman >/dev/null 2>&1 || return 0

  # pacman resolves --dbpath before it will use it, so the scratch directory
  # has to exist first.
  rm -rf "$NETWORK_CHECK_DB"
  mkdir -p "$NETWORK_CHECK_DB"
  pacman -Sy --config "$PACMAN_CONF" --dbpath "$NETWORK_CHECK_DB" --noconfirm \
    >/dev/null 2>&1
}

# The first wireless interface, asked of the kernel rather than of iwd: a
# machine whose Wi-Fi firmware never came up is then still told apart from one
# with no radio at all, which are different problems with different fixes.
wireless_device() {
  local dev

  for dev in "$SYSFS_NET"/*/wireless; do
    [[ -e $dev ]] || continue
    basename "$(dirname "$dev")"
    return 0
  done

  return 1
}

# The SSIDs iwd can see, one per line. iwd's table is the interface here — the
# live environment has no other way to enumerate networks — so a format the
# parsing does not recognise yields nothing and the step falls back to its
# manual options rather than pretending there is no Wi-Fi.
wifi_networks() {
  local dev=$1

  iwctl device "$dev" set-property Powered on >/dev/null 2>&1 || true
  iwctl station "$dev" scan >/dev/null 2>&1 || true
  iwctl station "$dev" get-networks 2>/dev/null |
    sed -e 's/\x1b\[[0-9;]*m//g' |
    awk '
      /Network name/ { header = 1; next }
      header && /^-+$/ { body = 1; next }
      body && /^[[:space:]]*[^[:space:]]/ {
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]{2,}.*$/, "")
        print
      }' |
    grep -v '^$' |
    sort -u
}

join_wifi() {
  local dev=$1 ssid=$2 passphrase=$3

  if [[ -n $passphrase ]]; then
    iwctl --passphrase "$passphrase" station "$dev" connect "$ssid"
  else
    iwctl station "$dev" connect "$ssid"
  fi
}

# STEP: NETWORK — ask for a connection until there is one that pacman can use.
network_step() {
  installs_from_network || return 0

  local dev choice ssid passphrase prompted=0
  local networks=()

  while :; do
    # Checked at the top of every pass, so a cable plugged in while the wizard
    # waits is picked up by the retry rather than by asking anything again. On
    # a machine that is already online the step returns before drawing.
    if network_reachable; then
      ((prompted)) && notice "Network is up" 1
      return 0
    fi

    prompted=1
    step "Network"
    say "This ISO installs from the network: no packages are bundled on the stick."
    say "Join a wireless network below, or connect a cable and retry."
    echo

    dev=$(wireless_device)
    if [[ -z $dev ]]; then
      say "No wireless interface found on this machine."
      echo
      gum confirm --affirmative "Retry" --negative "Quit to shell" \
        "Is a network cable connected?" ||
        abort "This ISO needs a network connection to install."
      continue
    fi

    notice "Scanning for wireless networks" "$WIFI_SCAN_WAIT"
    mapfile -t networks < <(wifi_networks "$dev")

    choice=$(printf '%s\n' "${networks[@]}" "Rescan" "Open iwctl" "Quit to shell" |
      gum choose --header "Wireless networks on $dev") ||
      abort "This ISO needs a network connection to install."

    case $choice in
    Rescan) continue ;;
    "Open iwctl") iwctl && continue ;;
    "Quit to shell") abort "This ISO needs a network connection to install." ;;
    esac

    ssid=$choice
    passphrase=$(gum input --password \
      --placeholder "Password for $ssid (empty for an open network)") ||
      abort "This ISO needs a network connection to install."

    notice "Connecting to $ssid" 1
    join_wifi "$dev" "$ssid" "$passphrase" ||
      say "Could not join $ssid. Check the password and try again."
  done
}
