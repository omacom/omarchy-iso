#!/usr/bin/env bash

configure_grub_platform() {
  local config=$1
  local platform=${2:-}

  case "$platform" in
    n1x)
      sed -i \
        -e '/^%N1X_ONLY_BEGIN%$/d' \
        -e '/^%N1X_ONLY_END%$/d' \
        -e '/^%NON_N1X_ONLY_BEGIN%$/,/^%NON_N1X_ONLY_END%$/d' \
        "$config"
      ;;
    ""|gb10)
      sed -i \
        -e '/^%N1X_ONLY_BEGIN%$/,/^%N1X_ONLY_END%$/d' \
        -e '/^%NON_N1X_ONLY_BEGIN%$/d' \
        -e '/^%NON_N1X_ONLY_END%$/d' \
        "$config"
      ;;
    *)
      echo "ERROR: unsupported GRUB platform overlay: $platform" >&2
      return 1
      ;;
  esac

  if grep -Eq '^%(N1X|NON_N1X)_ONLY_(BEGIN|END)%$' "$config"; then
    echo "ERROR: GRUB platform markers remain in $config" >&2
    return 1
  fi
}
