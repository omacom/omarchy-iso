#!/bin/bash
#
# Static checks for the aarch64 / N1x build overlay. These run without Docker
# and guard the pieces that a wrong edit would silently break: the entrypoint's
# argument contract, the GRUB templating markers, the arm64 archiso patch
# still applying to the pinned submodule, and the manifest filter.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- entrypoint argument contract -------------------------------------------
bash -n "$ROOT/bin/omarchy-iso-make" "$ROOT/builder/build-iso.sh" \
  "$ROOT/builder/aarch64-package-filter.sh" "$ROOT/builder/grub-platform.sh" \
  "$ROOT/builder/archiso-aarch64-mkinitcpio.sh" "$ROOT/builder/archiso-aarch64-grub-modules.sh" \
  "$ROOT/builder/node-release.sh" "$ROOT/builder/arm64-kernel-image.sh"

grep -Fq 'menci/archlinuxarm@sha256:' "$ROOT/bin/omarchy-iso-make" || fail "aarch64 container is not pinned by digest"
grep -Fq -- '--arch aarch64 requires --package-dir DIR' "$ROOT/bin/omarchy-iso-make" || fail "aarch64 builds must require the package bundle"
grep -Fq -- '--arch aarch64 requires --local-source' "$ROOT/bin/omarchy-iso-make" || fail "aarch64 builds must require --local-source"
grep -Fq 'sha256sum --check --strict --quiet SHA256SUMS' "$ROOT/bin/omarchy-iso-make" || fail "bundle checksums are not verified on the host"
grep -Fq -- '-v "$PACKAGE_DIR:/packages:ro"' "$ROOT/bin/omarchy-iso-make" || fail "bundle is not mounted read-only at /packages"
grep -Fq 'OMARCHY_ARCH == x86_64 && -d /var/cache/pacman/pkg' "$ROOT/bin/omarchy-iso-make" || fail "host pacman cache would leak into aarch64 builds"

# --- builder wiring -----------------------------------------------------------
grep -Fq 'online_pacman_conf=/configs/pacman-online-aarch64.conf' "$ROOT/builder/build-iso.sh" || fail "aarch64 does not use its own online pacman config"
if grep -Fq 'pacman-online-${OMARCHY_MIRROR}.conf --noconfirm' "$ROOT/builder/build-iso.sh"; then
  fail "a pacman call still hardcodes the x86 mirror config"
fi
grep -Fq 'configure_archiso_aarch64_mkinitcpio' "$ROOT/builder/build-iso.sh" || fail "live initramfs is not adapted for aarch64"
grep -Fq 'kernel_options="plymouth.enable=0 console=tty0 acpi=nospcr initramfs_async=0"' "$ROOT/builder/build-iso.sh" || fail "aarch64 live boot does not pin the panel console"
grep -Fq '"$mkarchiso_command" -v -w' "$ROOT/builder/build-iso.sh" || fail "builder does not use the patched mkarchiso on aarch64"
grep -Fq 'Server = file:///packages' "$ROOT/configs/pacman-online-aarch64.conf" || fail "aarch64 [omarchy] repo does not point at the bundle"
grep -Fq 'arch="${OMARCHY_ARCH:-x86_64}"' "$ROOT/configs/profiledef.sh" || fail "profiledef ignores OMARCHY_ARCH"

# --- GRUB templating -----------------------------------------------------------
for cfg in grub.cfg loopback.cfg; do
  src="$ROOT/configs/grub/$cfg"
  grep -Fq 'vmlinuz-%KERNEL%' "$src" || fail "$cfg does not template the kernel"
  grep -Fq '%BOOT_SPLASH_KERNEL_OPTIONS%%KERNEL_OPTIONS%' "$src" || fail "$cfg does not template boot options"
  grep -Fq -- "--id 'n1x-recovery'" "$src" || fail "$cfg lacks the N1x recovery entry"
  grep -Fq 'omarchy.n1x_recovery=1 acpi=nospcr' "$src" || fail "$cfg recovery entry lacks acpi=nospcr"
  source "$ROOT/builder/grub-platform.sh"
  for platform in "" n1x; do
    cp "$src" "$fixture/$platform-$cfg"
    configure_grub_platform "$fixture/$platform-$cfg" "$platform"
    sed -i -e 's|%KERNEL%|linux-n1x|g' -e 's|%BOOT_SPLASH_KERNEL_OPTIONS%||g' -e 's|%KERNEL_OPTIONS%|plymouth.enable=0|g' \
      -e 's|%INSTALL_DIR%|arch|g' -e 's|%ARCH%|aarch64|g' -e 's|%ARCHISO_UUID%|x|g' "$fixture/$platform-$cfg"
    if command -v grub-script-check >/dev/null; then
      grub-script-check "$fixture/$platform-$cfg" || fail "$cfg ($platform) is not valid GRUB script"
    fi
    if [[ $platform == n1x ]]; then
      grep -Fq 'n1x-recovery' "$fixture/$platform-$cfg" || fail "n1x overlay lost the recovery entry in $cfg"
    else
      grep -Fq 'n1x-recovery' "$fixture/$platform-$cfg" && fail "recovery entry leaked into the generic $cfg"
    fi
    grep -Eq '^%(N1X|NON_N1X)_ONLY' "$fixture/$platform-$cfg" && fail "template markers remain in $cfg"
  done
done

# --- arm64 archiso patch still applies to the pinned submodule ---------------
if [[ -f "$ROOT/archiso/archiso/mkarchiso" ]]; then
  cp "$ROOT/archiso/archiso/mkarchiso" "$fixture/mkarchiso"
  patch --batch --forward --fuzz=0 --dry-run "$fixture/mkarchiso" <"$ROOT/builder/archiso-v87-aarch64-grub.patch" >/dev/null \
    || fail "archiso arm64 GRUB patch no longer applies to the pinned submodule"
fi

# --- manifest filter -----------------------------------------------------------
source "$ROOT/builder/aarch64-package-filter.sh"
result=$(filter_aarch64_packages linux-n1x linux linux-headers amd-ucode tzupdate lib32-nvidia-utils dell-xps13-sidecar-amps mise-bin hyprland omarchy-dev 2>/dev/null | tr '\n' ' ')
[[ $result == "linux-n1x linux-n1x-headers mise hyprland omarchy-dev " ]] || fail "manifest filter produced: $result"

# --- live initramfs overlay -------------------------------------------------
source "$ROOT/builder/archiso-aarch64-mkinitcpio.sh"
cp "$ROOT/configs/airootfs/etc/mkinitcpio.conf.d/archiso.conf" "$fixture/archiso.conf"
configure_archiso_aarch64_mkinitcpio "$fixture/archiso.conf"
grep -Eq '^HOOKS=\(' "$fixture/archiso.conf" || fail "live HOOKS line lost"
grep -Eq 'plymouth|microcode|memdisk' "$fixture/archiso.conf" && fail "x86-only or Plymouth hooks remain in the aarch64 live initramfs"
grep -Fq 'MODULES=(i2c_mt65xx i2c_tegra i2c_hid i2c_hid_acpi hid_generic hid_multitouch)' "$fixture/archiso.conf" || fail "early keyboard modules missing"

echo "aarch64 build overlay tests passed"
