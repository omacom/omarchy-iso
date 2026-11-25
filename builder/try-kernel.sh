#!/bin/bash

# Just try boots the ISO's live kernel over the root image, so the session
# loads its modules from the root image's /usr/lib/modules. With any other
# version of the kernel there, nothing that is a module loads: no Wi-Fi, no
# touchpad, no USB network, and binfmt_misc fails to mount. A build takes both
# kernels from one mirror, so they agree unless a step reuses older output, as
# a stale mkarchiso work directory once did with the previous live system.
#
# check_try_kernel <live root> <root image pacman dbpath> <kernel package>
check_try_kernel() {
  local live_root=$1 image_db=$2 kernel=$3
  local live image

  live=$(pacman -Q --root "$live_root" "$kernel" 2>/dev/null | cut -d' ' -f2) || true
  image=$(pacman -Q --dbpath "$image_db" "$kernel" 2>/dev/null | cut -d' ' -f2) || true

  if [[ -n $live && $live == "$image" ]]; then
    echo "Just try: $kernel $live in both the live system and the root image"
  else
    echo "ERROR: Just try boots $kernel ${live:-(none)} over a root image with $kernel ${image:-(none)}; no kernel module would load in the session" >&2
    return 1
  fi
}
