#!/bin/bash

# Package-only architecture selection: which keyring, which Node.js tarball,
# which archiso package list, which packages the build container and the live
# ISO need, and which online pacman config feeds the offline mirror. Sourced
# by architecture.sh; kept separate so the package inventory of a build can
# be reasoned about without the boot/profile side.

configure_package_architecture() {
  case "$OMARCHY_ARCH" in
    x86_64)
      DISTRO_KEYRING_PACKAGE=archlinux-keyring
      DISTRO_KEYRING_NAME=archlinux
      NODE_DIST_ARCH=x64
      PROFILE_PACKAGES=packages.x86_64
      PACMAN_ONLINE_CONFIG="/configs/pacman-online-${OMARCHY_MIRROR}.conf"
      BUILD_HOST_PACKAGES=(
        archiso git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli
      )
      # The selected omarchy-settings package is needed here so its
      # post_install hook drops Omarchy's plymouthd.conf into /etc/plymouth
      # before mkarchiso builds the live initramfs.
      LIVE_PACKAGES=(
        linux-t2 git gum jq openssl plymouth ttfx tzupdate omarchy-keyring
        "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted
      )
      ;;
    aarch64)
      # Arch Linux ARM is the aarch64 base distribution (see
      # plans/aarch64-support.md, prerequisite 1): vanilla Arch has no
      # core/os/aarch64, so the keyring, mirrors, and kernel all come from ALARM.
      DISTRO_KEYRING_PACKAGE=archlinuxarm-keyring
      DISTRO_KEYRING_NAME=archlinuxarm
      NODE_DIST_ARCH=arm64
      PROFILE_PACKAGES=packages.aarch64
      PACMAN_ONLINE_CONFIG=/configs/pacman-online-arm.conf
      # ALARM does not package archiso itself, so the build container gets
      # mkarchiso's runtime dependencies and runs the submodule's copy instead.
      BUILD_HOST_PACKAGES=(
        arch-install-scripts dosfstools e2fsprogs findutils grub gzip libarchive
        libisoburn mtools openssl pacman sed squashfs-tools git sudo base-devel jq
        imagemagick neovim nodejs npm tree-sitter-cli
      )
      # No ttfx (x86-only package) and no tzupdate on ALARM; the configurator
      # and dashboard skip the logo animation when ttfx is absent.
      LIVE_PACKAGES=(
        linux-aarch64 git gum jq openssl plymouth omarchy-keyring
        "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted
      )
      ;;
    *)
      echo "Unsupported OMARCHY_ARCH: $OMARCHY_ARCH" >&2
      return 1
      ;;
  esac
}

# Rewrite an Omarchy package list (stdin) for the selected architecture. On
# x86_64 this is the identity. On aarch64, microcode does not exist, tzupdate
# is not packaged by ALARM, and the kernel is linux-aarch64.
filter_target_packages() {
  local line excluded
  declare -A excluded=()

  # builder/packages.aarch64-exclude says what is dropped and why.
  if [[ $OMARCHY_ARCH == aarch64 ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      [[ -z $line || $line == \#* ]] && continue
      excluded["$line"]=1
    done <"${BUILDER_ROOT:-/builder}/packages.aarch64-exclude"
  fi

  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $OMARCHY_ARCH == aarch64 ]]; then
      [[ -n $line && -n ${excluded[$line]:-} ]] && continue
      case "$line" in
        linux)
          line=linux-aarch64
          ;;
        linux-headers)
          line=linux-aarch64-headers
          ;;
      esac
    fi
    printf '%s\n' "$line"
  done
}

# The archiso releng profile ships only packages.x86_64. For aarch64, rename it
# and prune the entries that are x86-only (microcode, BIOS/EFI shells,
# memtest, syslinux, x86 guest tools) or replaced by ALARM's kernel (linux,
# and broadcom-wl which is a prebuilt module for stock linux).
prepare_package_profile() {
  local profile=$1

  [[ $OMARCHY_ARCH == aarch64 ]] || return 0
  mv "$profile/packages.x86_64" "$profile/packages.aarch64"
  sed -i.bak -E '/^(amd-ucode|broadcom-wl|edk2-shell|hyperv|intel-ucode|linux|memtest86\+|memtest86\+-efi|open-vm-tools|refind|reflector|syslinux|virtualbox-guest-utils-nox)$/d' \
    "$profile/packages.aarch64"
  rm -f -- "$profile/packages.aarch64.bak"
}
