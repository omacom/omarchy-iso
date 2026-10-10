#!/bin/bash

# Packages unavailable or inapplicable on aarch64.
OMARCHY_ARCH_DROP=(
  # x86 platform hardware
  amd-ucode intel-ucode
  apple-bcm-firmware apple-bcm-firmware-fetcher apple-t2-audio-config t2fanrd linux-t2 linux-t2-headers
  macbook12-spi-driver-dkms macbook8-spi-pxa2xx-nodma-dkms
  asusctl supergfxctl rog-control-center
  dell-xps-touchpad-haptics dell-xps13-sidecar-amps linux-firmware-cirrus-dx13260
  tuxedo-drivers-nocompatcheck-dkms
  intel-ipu7-camera intel-lpmd intel-media-driver libva-intel-driver
  thermald linux-ptl linux-ptl-headers vpl-gpu-rt libvpl
  vulkan-intel vulkan-radeon
  nvidia-dkms nvidia-open-dkms nvidia-utils nvidia-580xx-dkms nvidia-580xx-utils
  libva-nvidia-driver lib32-nvidia-utils lib32-nvidia-580xx-utils
  broadcom-wl broadcom-wl-dkms yt6801-dkms qmk-hid xpadneo-dkms
  edk2-shell memtest86+ memtest86+-efi syslinux refind

  # x86 virtualization guests
  hyperv open-vm-tools virtualbox-guest-utils-nox qemu-user-static-binfmt

  # Software without an aarch64 build
  obs-studio obsidian pinta dotnet-runtime asdcontrol gliff superwhisper-bin

  # Build artifacts not carried by Arch Linux ARM
  yay-debug reflector
)

# Use equivalent packages available on aarch64, including the headers that
# the installer requires before installing DKMS packages.
OMARCHY_ARCH_SUBST_FROM=(quickshell-git mise linux-omarchy linux-omarchy-headers)
OMARCHY_ARCH_SUBST_TO=(quickshell mise-bin linux-aarch64 linux-aarch64-headers)

# Transform both the shipped package lists and the offline dependency set.
filter_arch_packages() {
  if [[ $ISO_ARCH != aarch64 ]]; then
    cat
    return
  fi

  local package excluded index
  while IFS= read -r package || [[ -n $package ]]; do
    for excluded in "${OMARCHY_ARCH_DROP[@]}"; do
      [[ $package == "$excluded" ]] && continue 2
    done
    for index in "${!OMARCHY_ARCH_SUBST_FROM[@]}"; do
      if [[ $package == "${OMARCHY_ARCH_SUBST_FROM[$index]}" ]]; then
        package=${OMARCHY_ARCH_SUBST_TO[$index]}
        break
      fi
    done
    printf '%s\n' "$package"
  done
}

# Shared by the build and inventory tests; platform opt-ins are added afterward.
offline_package_roots() {
  {
    grep -hv '^#\|^$' "$@"
    printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"
  } | filter_arch_packages | sort -u
}
