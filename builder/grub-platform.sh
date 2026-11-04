#!/usr/bin/env bash

# The N1x recovery entry boots the hardware probe that only an aarch64 image
# can run, so it stays in that image's menu and leaves the x86_64 one.
#
# Only an x86_64 image picks its live kernel at boot: linux-t2 on a Mac,
# %KERNEL% everywhere else. An aarch64 image has no linux-t2, so it drops that
# choice and its entries name %KERNEL% outright. Ventoy boots an arm64 ISO by
# hooking the initramfs it finds by literal path in grub.cfg; given
# initramfs-${live_kernel}.img it hooks nothing, and the live system can't find
# the ISO on the stick.
configure_grub_platform() {
  local config=$1
  local arch=${2:-}

  case "$arch" in
    aarch64)
      sed -i \
        -e '/^%N1X_ONLY_BEGIN%$/d' \
        -e '/^%N1X_ONLY_END%$/d' \
        -e '/^%X86_ONLY_BEGIN%$/,/^%X86_ONLY_END%$/d' \
        -e 's/%LIVE_KERNEL%/%KERNEL%/g' \
        "$config"
      ;;
    *)
      sed -i \
        -e '/^%N1X_ONLY_BEGIN%$/,/^%N1X_ONLY_END%$/d' \
        -e '/^%X86_ONLY_BEGIN%$/d' \
        -e '/^%X86_ONLY_END%$/d' \
        -e 's/%LIVE_KERNEL%/${live_kernel}/g' \
        "$config"
      ;;
  esac

  if grep -Eq '^%(N1X|X86)_ONLY_(BEGIN|END)%$|%LIVE_KERNEL%' "$config"; then
    echo "ERROR: GRUB template markers remain in $config" >&2
    return 1
  fi
}
