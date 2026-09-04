#!/bin/bash

# Adapt the x86_64-authored Omarchy package manifests to aarch64. The kernel
# names are swapped for the platform kernel, and packages that only exist for
# x86 are dropped with an explicit log line. The list is deliberately closed:
# anything not named here that is missing from Arch Linux ARM or the bundle
# still fails the build when pacman cannot resolve it.
filter_aarch64_packages() {
  local kernel=$1
  shift
  local package

  for package in "$@"; do
    case "$package" in
      linux|linux-t2)
        echo "aarch64: replacing $package with $kernel" >&2
        printf '%s\n' "$kernel"
        ;;
      linux-headers|linux-t2-headers)
        echo "aarch64: replacing $package with $kernel-headers" >&2
        printf '%s\n' "$kernel-headers"
        ;;
      mise-bin)
        # The aarch64 bundle carries mise built from source under its own name.
        echo "aarch64: replacing $package with mise" >&2
        printf '%s\n' mise
        ;;
      amd-ucode|intel-ucode|syslinux|broadcom-wl|memtest86+|memtest86+-efi|edk2-shell|\
      apple-bcm-firmware|apple-t2-audio-config|t2fanrd|tiny-dfr|macbook12-spi-driver-dkms|\
      asusctl|dell-xps-touchpad-haptics|dell-xps13-sidecar-amps|intel-ipu7-camera|intel-lpmd|intel-media-driver|libva-intel-driver|vpl-gpu-rt|thermald|\
      linux-ptl|linux-ptl-headers|qmk-hid|tuxedo-drivers-nocompatcheck-dkms|yt6801-dkms|\
      nvidia-580xx-dkms|nvidia-580xx-utils|nvidia-dkms|lib32-*|vulkan-intel|vulkan-radeon|vulkan-asahi|\
      tzupdate|tensaku)
        echo "aarch64: excluding x86-only package $package" >&2
        ;;
      *)
        printf '%s\n' "$package"
        ;;
    esac
  done
}
