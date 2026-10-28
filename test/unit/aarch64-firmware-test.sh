#!/bin/bash
#
# The aarch64 UEFI firmware lookup that bin/omarchy-iso-boot and the arm64
# boot tests share, run against the file layouts the packages ship.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

source "$ROOT/bin/lib/aarch64-firmware.sh"

found() { # share directory, expected code, expected vars
  AARCH64_UEFI_CODE="" AARCH64_UEFI_VARS=""
  aarch64_uefi_firmware "$1" || fail "no firmware found in ${1#$fixture/}"
  [[ $AARCH64_UEFI_CODE == "$1/$2" && $AARCH64_UEFI_VARS == "$1/$3" ]] \
    || fail "${1#$fixture/}: found ${AARCH64_UEFI_CODE#$1/} and ${AARCH64_UEFI_VARS#$1/}, not $2 and $3"
}

# Arch's edk2-aarch64 202608-1: the images under edk2/aarch64, the AAVMF
# names as links to them.
arch=$fixture/arch
mkdir -p "$arch/edk2/aarch64" "$arch/AAVMF"
truncate -s 64M "$arch/edk2/aarch64/QEMU_EFI.fd" "$arch/edk2/aarch64/QEMU_VARS.fd"
ln -s ../edk2/aarch64/QEMU_EFI.fd "$arch/AAVMF/AAVMF_CODE.fd"
ln -s ../edk2/aarch64/QEMU_VARS.fd "$arch/AAVMF/AAVMF_VARS.fd"
found "$arch" AAVMF/AAVMF_CODE.fd AAVMF/AAVMF_VARS.fd
[[ $(realpath "$AARCH64_UEFI_CODE") == "$arch/edk2/aarch64/QEMU_EFI.fd" ]] || fail "the AAVMF code link does not lead to QEMU_EFI.fd"

# The same package without its links.
rm "$arch"/AAVMF/*
found "$arch" edk2/aarch64/QEMU_EFI.fd edk2/aarch64/QEMU_VARS.fd

# Debian's qemu-efi-aarch64: the AAVMF names only.
debian=$fixture/debian
mkdir -p "$debian/AAVMF"
truncate -s 64M "$debian/AAVMF/AAVMF_CODE.fd" "$debian/AAVMF/AAVMF_VARS.fd"
found "$debian" AAVMF/AAVMF_CODE.fd AAVMF/AAVMF_VARS.fd

# Code without vars is no firmware, and neither is nothing.
rm "$debian/AAVMF/AAVMF_VARS.fd"
aarch64_uefi_firmware "$debian" && fail "code without vars counts as firmware"
aarch64_uefi_firmware "$fixture/empty" && fail "an empty directory has firmware"

# The launcher and both boot tests take their firmware from this lookup and
# name none of their own.
for caller in bin/omarchy-iso-boot test/arm64-live-boot test/arm64-install; do
  grep -Fq 'lib/aarch64-firmware.sh' "$ROOT/$caller" || fail "$caller does not use the shared firmware lookup"
  grep -Eq 'QEMU_(EFI|CODE|VARS)\.fd|AAVMF_(CODE|VARS)\.fd' "$ROOT/$caller" && fail "$caller names aarch64 firmware of its own"
done
bash -n "$ROOT/bin/lib/aarch64-firmware.sh" "$ROOT/bin/omarchy-iso-boot" "$ROOT/test/arm64-live-boot" "$ROOT/test/arm64-install"
