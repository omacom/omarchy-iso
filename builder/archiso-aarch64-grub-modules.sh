#!/usr/bin/env bash

filter_archiso_aarch64_grub_modules() {
  local modules_name=$1
  local -n modules=$modules_name
  local module
  local -a filtered_modules=()

  # arm64-efi receives keyboard and USB input from UEFI and does not ship
  # these legacy x86/native-USB GRUB modules.
  for module in "${modules[@]}"; do
    case "$module" in
      at_keyboard | keylayouts | usb | usbserial_common | usbserial_ftdi | usbserial_pl2303 | usbserial_usbdebug) ;;
      *) filtered_modules+=("$module") ;;
    esac
  done

  modules=("${filtered_modules[@]}")
}
