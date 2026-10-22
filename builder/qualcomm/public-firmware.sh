#!/bin/bash
# Sourced during image customization, before either Qualcomm UKI is assembled.
check_public_a16_firmware() {
  local root=$1 file
  if [[ -d $root/var/lib/pacman/local ]] &&
    compgen -G "$root/var/lib/pacman/local/asus-zenbook-a16-firmware-*" >/dev/null; then
    echo 'Private ASUS firmware package must not enter the public ISO' >&2
    return 1
  fi
  if [[ -n $(find "$root" -xdev -name 'asus-zenbook-a16-firmware*' -print -quit) ]]; then
    echo 'Private ASUS firmware archive must not enter the public ISO' >&2
    return 1
  fi
  local -a paths=(
    "$root"/{usr/lib,lib}/firmware/{,updates/}qcom/glymur/ASUSTeK/UX3607OA/*
    "$root"/{usr/lib,lib}/firmware/{,updates/}qca/clnb*
    "$root"/{usr/lib,lib}/firmware/{,updates/}ath12k/QCC2072/hw1.0/board.bin*
  )
  for file in "${paths[@]}"; do
    if [[ -e $file || -L $file ]]; then
      echo "Owner-only A16 firmware must not enter the public ISO: $file" >&2
      return 1
    fi
  done
}
