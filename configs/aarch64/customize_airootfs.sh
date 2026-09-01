#!/usr/bin/env bash
# Runs inside the live-ISO chroot after packages are installed.
#
# WHAT THIS IS FOR
# ----------------
# Arch Linux ARM's kernel packages name things differently from Arch's, and
# archiso and GRUB both look for the Arch names. This reconciles the two.
#
# It is deliberately *not* responsible for generating the initramfs. On Arch
# that happens by itself: the kernel package installs
# usr/lib/modules/<ver>/{vmlinuz,pkgbase}, 90-mkinitcpio-install.hook triggers
# on the former, and /usr/share/libalpm/scripts/mkinitcpio reads the latter to
# learn the kernel's name. ALARM installs neither file, so the hook never fires
# -- proposed upstream as archlinuxarm/PKGBUILDs#2215. With that applied the
# hook does run, but two naming gaps remain and are what this script closes:
#
#   * ALARM's preset is PRESETS=('default') writing /boot/initramfs-linux.img,
#     while the GRUB entries load initramfs-linux-aarch64.img.
#   * Nothing creates /boot/vmlinuz-*, and mkarchiso copies the kernel with
#     `install -- "${pacstrap_dir}/boot/vmlinuz-"*`, which would match nothing.
#
# It also sets archiso_config in the preset, which is how x86's linux-t2.preset
# keeps an installed system's HOOKS out of the live initramfs.
#
# NOTE: mkarchiso prints a deprecation warning for customize_airootfs.sh. There
# is currently no replacement hook that runs inside the chroot after packages
# install, which is required here because the kernel image only exists then.
# Shipping the preset in airootfs/ does not work either: the overlay is copied
# before pacstrap, so linux-aarch64's own preset overwrites it.
set -uo pipefail

# Everything here addresses differences in Arch Linux ARM's kernel packaging.
# On any other architecture this script is a no-op.
if [[ $(uname -m) != aarch64 ]]; then
  exit 0
fi

# Omarchy forces the thunderbolt module; ALARM's aarch64 kernel does not build
# it, and mkinitcpio treats an unresolvable MODULES entry as an error.
if [[ -f /etc/mkinitcpio.conf.d/thunderbolt_module.conf ]]; then
  sed -i 's/^MODULES+=(thunderbolt)/#MODULES+=(thunderbolt)  # not built for aarch64/' \
    /etc/mkinitcpio.conf.d/thunderbolt_module.conf
fi

# ALARM installs the kernel as /boot/Image. mkarchiso copies /boot/vmlinuz-*
# into the ISO, so without this name the kernel never reaches the image.
if [[ ! -e /boot/vmlinuz-linux-aarch64 ]]; then
  if [[ -e /boot/Image ]]; then
    cp -a /boot/Image /boot/vmlinuz-linux-aarch64
  else
    echo "customize_airootfs: no kernel image at /boot/Image or /boot/vmlinuz-linux-aarch64" >&2
    exit 1
  fi
fi

# Drop presets whose kernel image is absent: `mkinitcpio -P` aborts on them.
for preset in /etc/mkinitcpio.d/*.preset; do
  [[ -e $preset ]] || continue
  kname="$(basename "$preset" .preset)"
  if [[ $kname != linux-aarch64 && ! -e /boot/vmlinuz-$kname ]]; then
    echo "customize_airootfs: dropping $kname.preset (no kernel image)"
    rm -f "$preset"
  fi
done

# Replace ALARM's preset, which writes /boot/initramfs-linux.img, with one that
# writes the name the GRUB entries load. archiso_config additionally makes
# mkinitcpio read archiso.conf as its configuration, bypassing
# /etc/mkinitcpio.conf.d entirely -- the same trick x86's linux-t2.preset uses
# to keep omarchy_hooks.conf, which describes an *installed* system, out of the
# *live* initramfs.
cat > /etc/mkinitcpio.d/linux-aarch64.preset <<'PRESET'
# Live-ISO preset for Arch Linux ARM's linux-aarch64.
PRESETS=('archiso')

ALL_kver='/boot/vmlinuz-linux-aarch64'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'

archiso_image="/boot/initramfs-linux-aarch64.img"
PRESET

echo "customize_airootfs: building the live initramfs from archiso.conf"
rm -f /boot/initramfs-linux*.img

# mkinitcpio exits non-zero on this platform even when it produces a complete
# image: archiso's memdisk hook wants the phram module and the memdiskfind
# binary, and neither exists for aarch64 (memdiskfind ships in syslinux, which
# is x86-only). Judge the result on the artefact rather than the exit status.
mkinitcpio -p linux-aarch64 || \
  echo "customize_airootfs: mkinitcpio reported errors; checking for the image"

# The GRUB entries boot this file by name. If it is missing the ISO builds
# cleanly and then fails to boot, so fail the build here instead.
if [[ ! -s /boot/initramfs-linux-aarch64.img ]]; then
  echo "customize_airootfs: no live initramfs was produced; the ISO would not boot" >&2
  exit 1
fi
echo "customize_airootfs: initramfs present ($(stat -c %s /boot/initramfs-linux-aarch64.img) bytes)"

exit 0
