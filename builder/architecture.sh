#!/bin/bash

# Architecture and media-target selection for the ISO build. Sourced by
# build-iso.sh (inside the container) and by the unit tests (on the host), so
# it only sets variables and defines functions; the caller decides what to do.
#
# Two targets exist: x86_64/pc (the ISO shipped today) and aarch64/generic
# (vanilla UEFI + ACPI ARM64: Ampere, Graviton, Snapdragon X, dev kits).
# Apple Silicon and U-Boot SBCs are out of scope — see plans/aarch64-support.md.

source "${BASH_SOURCE[0]%/*}/package-architecture.sh"

OMARCHY_ARCH=${OMARCHY_ARCH:-x86_64}
OMARCHY_MIRROR=${OMARCHY_MIRROR:-stable}
# build-iso.sh selects the settings package before sourcing this; the default
# only serves callers (tests) that source the selection on its own.
OMARCHY_SETTINGS_PACKAGE=${OMARCHY_SETTINGS_PACKAGE:-omarchy-settings}
if [[ -z ${OMARCHY_MEDIA_TARGET:-} ]]; then
  if [[ $OMARCHY_ARCH == "x86_64" ]]; then
    OMARCHY_MEDIA_TARGET=x86_64/pc
  else
    OMARCHY_MEDIA_TARGET=aarch64/generic
  fi
fi

case "$OMARCHY_ARCH:$OMARCHY_MEDIA_TARGET" in
  x86_64:x86_64/pc)
    OMARCHY_PLATFORM=pc
    ;;
  aarch64:aarch64/generic)
    OMARCHY_PLATFORM=generic
    ;;
  *)
    echo "Unsupported architecture/media target: $OMARCHY_ARCH:$OMARCHY_MEDIA_TARGET" >&2
    echo "Supported targets: x86_64/pc, aarch64/generic" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac
# Both targets install Limine on the target; the live ISO boots via GRUB on
# both (plus syslinux for BIOS on x86_64, see profiledef.sh).
OMARCHY_BOOT_BACKEND=limine
export OMARCHY_ARCH OMARCHY_MEDIA_TARGET OMARCHY_PLATFORM OMARCHY_BOOT_BACKEND

configure_package_architecture

case "$OMARCHY_ARCH" in
  x86_64)
    LIVE_KERNEL=linux-t2
    LIVE_KERNEL_BOOT_NAME=vmlinuz-linux-t2
    LIVE_INITRAMFS_BOOT_NAME=initramfs-linux-t2.img
    MKARCHISO=(mkarchiso)
    ;;
  aarch64)
    # ALARM kernels install /boot/Image rather than vmlinuz-*, and their
    # presets name the initramfs initramfs-linux.img regardless of pkgbase.
    LIVE_KERNEL=linux-aarch64
    LIVE_KERNEL_BOOT_NAME=Image
    LIVE_INITRAMFS_BOOT_NAME=initramfs-linux.img
    # A copy of the submodule's mkarchiso with archiso-aarch64.patch applied;
    # build-iso.sh creates it. ALARM ships no archiso package.
    MKARCHISO=(/tmp/omarchy-mkarchiso-aarch64)
    ;;
esac
export LIVE_KERNEL LIVE_KERNEL_BOOT_NAME LIVE_INITRAMFS_BOOT_NAME

# Adjust the seeded archiso profile (releng + configs/) for the selected
# architecture, after both have been copied into $profile. x86_64 is left
# untouched so the shipped ISO cannot change under this refactor.
prepare_media_profile() {
  local profile=$1
  local archiso_config="$profile/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
  local grub_config="$profile/grub/grub.cfg"
  local loopback_config="$profile/grub/loopback.cfg"

  [[ $OMARCHY_ARCH == aarch64 ]] || return 0

  prepare_package_profile "$profile"

  # The preset filename is the pkgbase, and that is load-bearing (see the
  # comment in airootfs/etc/mkinitcpio.d/linux-t2.preset). Neither releng's
  # linux.preset nor our linux-t2.preset matches the linux-aarch64 package.
  # Unlike Arch's kernels, ALARM's linux-aarch64 ships its own preset, and
  # pacman refuses a file the profile put there first (NoExtract does not
  # help: the conflict check runs before it). So the package's preset stays,
  # ours go, and the live initramfs is shaped through the config instead --
  # see the drop-in below.
  rm -f \
    "$profile/airootfs/etc/mkinitcpio.d/linux.preset" \
    "$profile/airootfs/etc/mkinitcpio.d/linux-t2.preset"

  # No CPU microcode on ARM, and archiso's memdisk hook is x86 PXE plumbing.
  sed -i.bak -e 's/ microcode / /' -e 's/ memdisk / /' "$archiso_config"
  rm -f -- "$archiso_config.bak"

  # ALARM's preset builds /boot/initramfs-linux.img from the default config,
  # which is /etc/mkinitcpio.conf plus every /etc/mkinitcpio.conf.d/*.conf in
  # name order, last HOOKS= wins. The x86 presets sidestep that by pinning
  # archiso.conf as the config; here omarchy-settings' omarchy_hooks.conf
  # sorts after archiso.conf and would replace the live-boot hooks with the
  # installed-system ones (autodetect then fails in the chroot and the ISO
  # drops to an emergency shell). Re-assert archiso's config from a name that
  # sorts last.
  # omarchy-settings' thunderbolt_module.conf also forces MODULES=(thunderbolt),
  # which the generic ARM kernel does not build, and mkinitcpio treats a
  # missing forced module as an error. The live image needs no forced modules.
  {
    cat "$archiso_config"
    echo
    echo "# Reset any module list a package drop-in forced; the live initramfs"
    echo "# relies on hooks alone."
    echo "MODULES=()"
  } >"$profile/airootfs/etc/mkinitcpio.conf.d/zz-archiso-live.conf"

  # The GRUB menu entries name the x86 live kernel; point them at ALARM's.
  # %ARCH% and the x86-only memtest/shell fragments are handled by mkarchiso
  # and grub_cpu guards respectively, so nothing else in the files changes.
  sed -i.bak \
    -e "s/vmlinuz-linux-t2/$LIVE_KERNEL_BOOT_NAME/g" \
    -e "s/initramfs-linux-t2\\.img/$LIVE_INITRAMFS_BOOT_NAME/g" \
    "$grub_config" "$loopback_config"
  rm -f -- "$grub_config.bak" "$loopback_config.bak"
}

# Produce the mkarchiso this build runs. On aarch64 that is the submodule's
# script with archiso-aarch64.patch applied (kernel named Image, no edk2-shell
# in the EFI image, only the GRUB modules the arm64-efi target actually ships).
prepare_mkarchiso() {
  [[ $OMARCHY_ARCH == aarch64 ]] || return 0
  cp /archiso/archiso/mkarchiso "${MKARCHISO[0]}"
  patch --forward --silent "${MKARCHISO[0]}" /builder/archiso-aarch64.patch
  chmod +x "${MKARCHISO[0]}"
}
