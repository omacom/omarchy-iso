#!/usr/bin/env bash
# Reconcile Arch Linux ARM kernel paths with the names expected by archiso.
set -uo pipefail

if [[ $(uname -m) != aarch64 ]]; then
  exit 0
fi

# linux-aarch64 does not provide the thunderbolt module.
if [[ -f /etc/mkinitcpio.conf.d/thunderbolt_module.conf ]]; then
  sed -i 's/^MODULES+=(thunderbolt)/#MODULES+=(thunderbolt)  # not built for aarch64/' \
    /etc/mkinitcpio.conf.d/thunderbolt_module.conf
fi

# Give mkarchiso the kernel filename it copies into the ISO.
if [[ ! -e /boot/vmlinuz-linux-aarch64 ]]; then
  if [[ -e /boot/Image ]]; then
    cp -a /boot/Image /boot/vmlinuz-linux-aarch64
  else
    echo "customize_airootfs: no kernel image at /boot/Image or /boot/vmlinuz-linux-aarch64" >&2
    exit 1
  fi
fi

# Drop presets whose kernel image is absent.
for preset in /etc/mkinitcpio.d/*.preset; do
  [[ -e $preset ]] || continue
  kname="$(basename "$preset" .preset)"
  if [[ $kname != linux-aarch64 && ! -e /boot/vmlinuz-$kname ]]; then
    echo "customize_airootfs: dropping $kname.preset (no kernel image)"
    rm -f "$preset"
  fi
done

# Use the filename GRUB loads and the live archiso hook configuration.
cat > /etc/mkinitcpio.d/linux-aarch64.preset <<'PRESET'
# Live-ISO preset for Arch Linux ARM's linux-aarch64.
PRESETS=('archiso')

ALL_kver='/boot/vmlinuz-linux-aarch64'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'

archiso_image="/boot/initramfs-linux-aarch64.img"
PRESET

echo "customize_airootfs: building the live initramfs from archiso.conf"
rm -f /boot/initramfs-linux*.img

# The unsupported memdisk hook can fail after producing a usable image.
mkinitcpio -p linux-aarch64 || \
  echo "customize_airootfs: mkinitcpio reported errors; checking for the image"

# Fail the build if GRUB's initramfs was not produced.
if [[ ! -s /boot/initramfs-linux-aarch64.img ]]; then
  echo "customize_airootfs: no live initramfs was produced; the ISO would not boot" >&2
  exit 1
fi
echo "customize_airootfs: initramfs present ($(stat -c %s /boot/initramfs-linux-aarch64.img) bytes)"

# Build the DTB-carrying UKI before mkarchiso clears /boot.
/root/live-uki.sh || exit 1

exit 0
