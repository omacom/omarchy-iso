#!/bin/bash
#
# Runs inside the live image after pacstrap, as archiso's customize_airootfs
# step, on generic aarch64 builds. It makes Arch Linux ARM's linux-aarch64 the
# live kernel under the names mkarchiso and GRUB expect:
#
#   /boot/vmlinuz-linux-aarch64         the package's /boot/Image
#   /boot/initramfs-linux-aarch64.img   built here with the archiso hooks
#
# This cannot be staged before pacstrap the way the N1x preset is. The package
# owns /etc/mkinitcpio.d/linux-aarch64.preset, its preset names /boot/Image,
# and its install script builds an installed-system initramfs that cannot boot
# live media. The approach is the dragon branch's customize_airootfs.sh.
set -euo pipefail

fail() { echo "linux-aarch64-live: $*" >&2; exit 1; }

image=/boot/Image
[[ -s $image ]] || fail "no kernel at $image; is linux-aarch64 installed?"
# GRUB's arm64 loader takes the uncompressed EFI-stub Image: ARMd at offset 56.
magic=$(dd if="$image" bs=1 skip=56 count=4 status=none | od -An -tx1 | tr -d ' \n')
[[ $magic == 41524d64 ]] || fail "$image is not an uncompressed arm64 Image"

releases=()
for modules in /usr/lib/modules/*/modules.builtin; do
  [[ -e $modules ]] && releases+=("$(basename "$(dirname "$modules")")")
done
(( ${#releases[@]} == 1 )) || fail "expected one kernel's modules, found: ${releases[*]:-none}"
release=${releases[0]}

cp -a "$image" /boot/vmlinuz-linux-aarch64

# The early-input modules are listed for the N1x kernel. Keep the ones this
# kernel has, as modules or built in; mkinitcpio fails on a name it cannot find.
config=/etc/mkinitcpio.conf.d/archiso.conf
if listed=$(grep -E '^MODULES=\(' "$config"); then
  listed=${listed#MODULES=\(}
  listed=${listed%\)}
  kept=()
  for module in $listed; do
    if modinfo -k "$release" "$module" >/dev/null 2>&1; then
      kept+=("$module")
    else
      echo "linux-aarch64-live: $release has no $module; leaving it out of the live initramfs"
    fi
  done
  sed -i "s|^MODULES=.*$|MODULES=(${kept[*]})|" "$config"
fi

cat >/etc/mkinitcpio.d/linux-aarch64.preset <<PRESET
# mkinitcpio preset for the generic aarch64 live kernel.

PRESETS=('archiso')

ALL_kver='$release'
archiso_config='$config'

archiso_image='/boot/initramfs-linux-aarch64.img'
PRESET

# mkarchiso copies every /boot/initramfs-*.img onto the ISO, twice.
rm -f /boot/initramfs-linux*.img
mkinitcpio -p linux-aarch64

initramfs=/boot/initramfs-linux-aarch64.img
[[ -s $initramfs ]] || fail "no live initramfs was produced; the ISO would not boot"
contents=$(lsinitcpio "$initramfs")
for hook in archiso archiso_loop_mnt; do
  grep -Eq "(^|/)hooks/$hook\$" <<<"$contents" || fail "the live initramfs is missing the $hook hook"
done
echo "linux-aarch64-live: $release, vmlinuz $(stat -c %s /boot/vmlinuz-linux-aarch64) bytes, initramfs $(stat -c %s "$initramfs") bytes"
