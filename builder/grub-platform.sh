#!/bin/bash

# Board-specific GRUB branches and recovery entries run only from an aarch64
# image.
#
# Only an x86_64 image picks its live kernel at boot: linux-t2 on a Mac,
# %KERNEL% everywhere else. An aarch64 image has no linux-t2, so it drops that
# choice and its entries name %KERNEL% outright. Ventoy boots an ISO by
# hooking the initramfs it finds by literal path in grub.cfg; given
# initramfs-${live_kernel}.img it hooks nothing, and the live system can't find
# the ISO on the stick. So an x86_64 entry loads its initramfs through
# live_initrd, which names both in full.
configure_grub_platform() {
  local config=$1
  local arch=${2:-}

  case "$arch" in
    aarch64)
      sed -i \
        -e '/^%N1X_ONLY_BEGIN%$/d' \
        -e '/^%N1X_ONLY_END%$/d' \
        -e '/^%ORION_ONLY_BEGIN%$/d' \
        -e '/^%ORION_ONLY_END%$/d' \
        -e '/^%X86_ONLY_BEGIN%$/,/^%X86_ONLY_END%$/d' \
        -e 's/%LIVE_KERNEL%/%KERNEL%/g' \
        -e 's|%LIVE_INITRD%|initrd /%INSTALL_DIR%/boot/%ARCH%/initramfs-%KERNEL%.img|g' \
        "$config"
      ;;
    *)
      sed -i \
        -e '/^%N1X_ONLY_BEGIN%$/,/^%N1X_ONLY_END%$/d' \
        -e '/^%ORION_ONLY_BEGIN%$/,/^%ORION_ONLY_END%$/d' \
        -e '/^%X86_ONLY_BEGIN%$/d' \
        -e '/^%X86_ONLY_END%$/d' \
        -e 's/ ${orion_kernel_options}//g' \
        -e 's/%LIVE_KERNEL%/${live_kernel}/g' \
        -e 's/%LIVE_INITRD%/live_initrd/g' \
        "$config"
      ;;
  esac

  if grep -Eq '^%(ORION|N1X|X86)_ONLY_(BEGIN|END)%$|%LIVE_(KERNEL|INITRD)%' "$config"; then
    echo "ERROR: GRUB template markers remain in $config" >&2
    return 1
  fi
}
