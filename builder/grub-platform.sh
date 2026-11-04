#!/usr/bin/env bash

# The N1x recovery entry boots the hardware probe that only an aarch64 image
# can run, so it stays in that image's menu and leaves the x86_64 one. The
# x86_64 menu shows for 3 s, for Try Omarchy.
configure_grub_platform() {
  local config=$1
  local arch=${2:-}

  case "$arch" in
    aarch64)
      sed -i \
        -e '/^%N1X_ONLY_BEGIN%$/d' \
        -e '/^%N1X_ONLY_END%$/d' \
        "$config"
      ;;
    *)
      # x86_64 has a Try Omarchy entry, so its menu shows for 3 s; left alone
      # it installs, as on every other platform.
      sed -i \
        -e '/^%N1X_ONLY_BEGIN%$/,/^%N1X_ONLY_END%$/d' \
        -e 's/^timeout=0$/timeout=3/' \
        -e 's/^timeout_style=hidden$/timeout_style=menu/' \
        "$config"
      ;;
  esac

  if grep -Eq '^%N1X_ONLY_(BEGIN|END)%$' "$config"; then
    echo "ERROR: GRUB kernel markers remain in $config" >&2
    return 1
  fi
}
