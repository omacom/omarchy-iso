#!/usr/bin/env bash

configure_archiso_aarch64_mkinitcpio() {
  local config=$1
  local hook hook_body hook_line modules_line replacement
  local -a filtered_hooks=() hook_lines=() hooks=() module_lines=()
  local -a early_input_modules=(
    i2c_tegra
    i2c_hid
    i2c_hid_acpi
    hid_generic
    hid_multitouch
  )
  local -i memdisk_count=0 microcode_count=0 plymouth_count=0

  mapfile -t hook_lines < <(grep -E '^HOOKS=\([^)]*\)$' "$config")
  if (( ${#hook_lines[@]} != 1 )); then
    echo "ERROR: unexpected Archiso mkinitcpio hook layout: $config" >&2
    return 1
  fi

  mapfile -t module_lines < <(grep -E '^MODULES=' "$config")
  if (( ${#module_lines[@]} != 0 )); then
    echo "ERROR: unexpected Archiso mkinitcpio module layout: $config" >&2
    return 1
  fi

  hook_line=${hook_lines[0]}
  hook_body=${hook_line#HOOKS=\(}
  hook_body=${hook_body%\)}
  read -r -a hooks <<<"$hook_body"

  for hook in "${hooks[@]}"; do
    case "$hook" in
      microcode) ((microcode_count += 1)) ;;
      memdisk) ((memdisk_count += 1)) ;;
      plymouth) ((plymouth_count += 1)) ;;
      *) filtered_hooks+=("$hook") ;;
    esac
  done
  if (( microcode_count != 1 || memdisk_count != 1 || plymouth_count != 1 )); then
    echo "ERROR: expected exactly one microcode, memdisk, and plymouth hook: $config" >&2
    return 1
  fi

  # CPU microcode packages and memdiskfind are x86-only. Keeping memdisk after
  # excluding memtest86+ makes mkinitcpio report an incomplete ARM64 image.
  # Plymouth 26.134.222-2 aborts in the GB10 initramfs while initializing its
  # console and boot-server event sources, so the live image boots without it.
  printf -v replacement 'HOOKS=(%s)' "${filtered_hooks[*]}"
  sed -i "s|^HOOKS=.*$|$replacement|" "$config"

  # N1x firmware exposes the built-in keyboard to Limine, but Linux needs the
  # Tegra I2C controller and I2C-HID transport before the live root is mounted.
  # The generic keyboard hook does not include drivers under hid/i2c-hid.
  printf -v modules_line 'MODULES=(%s)' "${early_input_modules[*]}"
  printf '%s\n' "$modules_line" >>"$config"

  mapfile -t hook_lines < <(grep -E '^HOOKS=\([^)]*\)$' "$config")
  if (( ${#hook_lines[@]} != 1 )) || [[ ${hook_lines[0]} != "$replacement" ]]; then
    echo "ERROR: failed to remove x86-only Archiso mkinitcpio hooks: $config" >&2
    return 1
  fi
  mapfile -t module_lines < <(grep -E '^MODULES=' "$config")
  if (( ${#module_lines[@]} != 1 )) || [[ ${module_lines[0]} != "$modules_line" ]]; then
    echo "ERROR: failed to add AArch64 early input modules: $config" >&2
    return 1
  fi
}
