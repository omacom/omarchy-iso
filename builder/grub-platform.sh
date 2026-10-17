#!/usr/bin/env bash

# The N1x recovery entry boots the hardware probe that only linux-omarchy
# can run, so it stays in the menu of an image on that kernel and leaves every
# other one.
configure_grub_kernel() {
  local config=$1
  local kernel=${2:-}

  case "$kernel" in
    linux-omarchy)
      sed -i \
        -e '/^%N1X_ONLY_BEGIN%$/d' \
        -e '/^%N1X_ONLY_END%$/d' \
        "$config"
      ;;
    *)
      sed -i \
        -e '/^%N1X_ONLY_BEGIN%$/,/^%N1X_ONLY_END%$/d' \
        "$config"
      ;;
  esac

  if grep -Eq '^%N1X_ONLY_(BEGIN|END)%$' "$config"; then
    echo "ERROR: GRUB kernel markers remain in $config" >&2
    return 1
  fi
}
