# The aarch64 UEFI firmware pair QEMU boots from: read-only code and the
# template of the writable vars. Sourced by bin/omarchy-iso-boot and by
# test/arm64-live-boot and test/arm64-install, so the launcher boots with the
# firmware the tests prove.
#
# Arch's edk2-aarch64 ships edk2/aarch64/QEMU_EFI.fd and QEMU_VARS.fd, with
# AAVMF/AAVMF_CODE.fd and AAVMF_VARS.fd as links to them; Debian's
# qemu-efi-aarch64 ships only the AAVMF names. There is no QEMU_CODE.fd. A QEMU
# installed on its own, which is how macOS gets one, ships the pair under its
# own share directory as edk2-aarch64-code.fd and edk2-arm-vars.fd.
#
# Sets AARCH64_UEFI_CODE and AARCH64_UEFI_VARS, or returns 1 when no pair is
# installed. $1 is the only directory to look in; with no argument, /usr/share
# and the QEMU installation's share directory are searched.
aarch64_uefi_firmware() {
  local share dir shares=() pair code vars
  if [[ -n ${1:-} ]]; then
    shares=("$1")
  else
    shares=(/usr/share)
    if dir=$(command -v qemu-system-aarch64 2>/dev/null); then
      dir=$(cd -- "$(dirname -- "$dir")/../share/qemu" 2>/dev/null && pwd) && shares+=("$dir")
    fi
  fi
  for share in "${shares[@]}"; do
    for pair in AAVMF/AAVMF_CODE.fd:AAVMF/AAVMF_VARS.fd edk2/aarch64/QEMU_EFI.fd:edk2/aarch64/QEMU_VARS.fd edk2-aarch64-code.fd:edk2-arm-vars.fd; do
      code=$share/${pair%%:*} vars=$share/${pair##*:}
      if [[ -f $code && -f $vars ]]; then
        AARCH64_UEFI_CODE=$code AARCH64_UEFI_VARS=$vars
        return 0
      fi
    done
  done
  return 1
}
