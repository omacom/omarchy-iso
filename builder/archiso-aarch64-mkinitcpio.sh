#!/usr/bin/env bash

configure_archiso_aarch64_mkinitcpio() {
  local config=$1
  local hook hook_body hook_line modules_line replacement
  local -a filtered_hooks=() hook_lines=() hooks=() module_lines=() modules=()
  local -a early_input_modules=(
    i2c_mt65xx
    i2c_tegra
    i2c_hid
    i2c_hid_acpi
    hid_generic
    hid_multitouch
  )
  # What a Snapdragon X1 or X2 laptop needs before its USB ports, keyboard and
  # panel work, on a kernel that builds these as modules. Arch Linux ARM's
  # kernel builds them in, and the ? skips one that a kernel does not have. The
  # DSP driver stays out (see grub.cfg).
  local -a snapdragon_platform_modules=(
    gcc-x1e80100? tcsrcc-x1e80100? dispcc-x1e80100? gpucc-x1e80100?
    # The X2 (Glymur) chips. The Surface Laptop 8's panel also waits for the
    # USB-C mux that thunderbolt registers.
    gcc-glymur? tcsrcc-glymur? dispcc-glymur? gpucc-glymur?
    pinctrl-glymur? qnoc-glymur? thunderbolt?
    pinctrl-x1e80100? qnoc-x1e80100? qcom-rpmh-regulator? fixed? spmi-pmic-arb?
    qcom-spmi-pmic? pinctrl-spmi-gpio? gpio-shared-proxy? reset-gpio?
    qcom_hwspinlock? smem? smp2p? socinfo? llcc-qcom? qcom_aoss? icc-bwmon?
    qcom-cpucp-mbox? nvmem_qfprom? nvmem_qcom-spmi-sdam? qcom-pon? rtc-pm8xxx?
    qcom_tsens? qcom-spmi-temp-alarm? i2c-qcom-geni? i2c-hid-of?
    phy-qcom-qmp-pcie? phy-qcom-qmp-combo? phy-qcom-eusb2-repeater?
    phy-qcom-qmp-usb? phy-qcom-m31-eusb2?
    phy-snps-eusb2? phy-qcom-edp? dwc3-qcom? xhci-plat-hcd? ps883x? pmic_glink?
    pmic_glink_altmode? pci-pwrctrl-pwrseq? pwrseq-qcom-wcn?
  )
  local -i memdisk_count=0 microcode_count=0 plymouth_count=0

  mapfile -t hook_lines < <(grep -E '^HOOKS=\([^)]*\)$' "$config")
  if (( ${#hook_lines[@]} != 1 )); then
    echo "ERROR: unexpected Archiso mkinitcpio hook layout: $config" >&2
    return 1
  fi

  # The live configuration's own modules (loop) stay, ahead of these.
  mapfile -t module_lines < <(grep -E '^MODULES=' "$config")
  if (( ${#module_lines[@]} > 1 )) || [[ ${#module_lines[@]} == 1 && ! ${module_lines[0]} =~ ^MODULES=\([^\)]*\)$ ]]; then
    echo "ERROR: unexpected Archiso mkinitcpio module layout: $config" >&2
    return 1
  fi
  if (( ${#module_lines[@]} == 1 )); then
    modules_line=${module_lines[0]#MODULES=\(}
    read -r -a modules <<<"${modules_line%\)}"
    sed -i '/^MODULES=/d' "$config"
  fi

  hook_line=${hook_lines[0]}
  hook_body=${hook_line#HOOKS=\(}
  hook_body=${hook_body%\)}
  read -r -a hooks <<<"$hook_body"

  for hook in "${hooks[@]}"; do
    case "$hook" in
      microcode) ((microcode_count += 1)) ;;
      memdisk) ((memdisk_count += 1)) ;;
      plymouth) ((plymouth_count += 1)); filtered_hooks+=("$hook") ;;
      *) filtered_hooks+=("$hook") ;;
    esac
  done
  if (( microcode_count != 1 || memdisk_count != 1 || plymouth_count != 1 )); then
    echo "ERROR: expected exactly one microcode, memdisk, and plymouth hook: $config" >&2
    return 1
  fi

  # CPU microcode packages and memdiskfind are x86-only. Keeping memdisk after
  # excluding memtest86+ makes mkinitcpio report an incomplete ARM64 image.
  # Plymouth stays: 26.134.222-2 aborted in the GB10 initramfs, but -3 runs
  # there.
  printf -v replacement 'HOOKS=(%s)' "${filtered_hooks[*]}"
  sed -i "s|^HOOKS=.*$|$replacement|" "$config"

  # N1x firmware exposes the built-in keyboard to Limine, but Linux needs the
  # I2C controller (MediaTek MT8901 IP on the N1x, ACPI NVDA0200; Tegra on
  # other NVIDIA boards) and the I2C-HID transport before the live root is
  # mounted. The generic keyboard hook does not include drivers under
  # hid/i2c-hid.
  modules+=("${early_input_modules[@]}" "${snapdragon_platform_modules[@]}")
  printf -v modules_line 'MODULES=(%s)' "${modules[*]}"
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
