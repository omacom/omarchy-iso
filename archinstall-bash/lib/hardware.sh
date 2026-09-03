# shellcheck shell=bash
# Port of lib/hardware.py (SysInfo) — the probes the installer uses.

sysinfo_has_uefi() {
  [[ -d /sys/firmware/efi ]]
}

# CPUVendor: AuthenticAMD → amd-ucode, GenuineIntel → intel-ucode.
sysinfo_cpu_vendor() {
  awk -F': *' '/^vendor_id/ { print $2; exit }' /proc/cpuinfo 2>/dev/null
}

sysinfo_ucode_package() {
  case $(sysinfo_cpu_vendor) in
    AuthenticAMD) printf 'amd-ucode' ;;
    GenuineIntel) printf 'intel-ucode' ;;
    *) return 1 ;;
  esac
}

sysinfo_is_vm() {
  local virt
  virt=$(systemd-detect-virt 2>/dev/null) || return 1
  [[ $virt != none ]]
}

sysinfo_loaded_modules() {
  awk '{ print $1 }' /proc/modules
}

sysinfo_requires_sof_fw() {
  grep -qx 'snd_sof' <(sysinfo_loaded_modules)
}

sysinfo_requires_alsa_fw() {
  local modules='snd_asihpi snd_cs46xx snd_darla20 snd_darla24 snd_echo3g snd_emu10k1 snd_gina20 snd_gina24 snd_hda_codec_ca0132 snd_hdsp snd_indigo snd_indigodj snd_indigodjx snd_indigoio snd_indigoiox snd_layla20 snd_layla24 snd_mia snd_mixart snd_mona snd_pcxhr snd_vx_lib'
  local m
  while read -r m; do
    list_contains "$modules" "$m" && return 0
  done < <(sysinfo_loaded_modules)
  return 1
}

# Installer._get_microcode(): no ucode inside VMs.
installer_get_microcode() {
  sysinfo_is_vm && return 1
  sysinfo_ucode_package
}

# accessibility_tools_in_use()
accessibility_tools_in_use() {
  systemctl is-active --quiet espeakup.service 2>/dev/null
}

# platform.machine()
machine_arch() {
  uname -m
}
