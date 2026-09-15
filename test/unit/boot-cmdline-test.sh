#!/bin/bash
#
# Every boot entry that loads the live system must pin copytoram=n. The
# archiso hook defaults to copytoram=auto, which copies the airootfs to RAM
# and unmounts the boot medium whenever the image is under 4 GiB and the
# machine has RAM to spare -- the root image the installer streams from that
# medium then vanishes (seen on a ThinkPad X200s booting from USB; the QEMU
# tests never hit it because they boot the ISO as an optical drive).
#
# loopback.cfg counts: mkarchiso ships it at /boot/grub/loopback.cfg, which is
# how Ventoy and a hand-written GRUB entry boot the ISO as a file on a disk.
# That path loop-mounts the image, so archisodevice is /dev/loopN rather than
# /dev/sr*, and the auto rule fires there too. It is matched on archisobasedir
# rather than archisosearchuuid because it finds the medium by img_dev/img_loop.
#
# The PXE entries count too: the NBD and NFS hooks force copytoram=y unless
# the cmdline says exactly n, and both keep the server's image tree mounted,
# so pinned they can still stream the root image. HTTP cannot -- its hook only
# downloads the airootfs into a tmpfs -- so no entry may use archiso_http_srv.
#
# No entry may carry cms_verify either: these ISOs are not codesigned
# (mkarchiso is never given a certificate), and the archiso hook aborts into
# an emergency shell when the flag is set with no .cms.sig on the medium. The
# releng profile the build seeds from ships it on the PXE entries, so a
# config resync would quietly reintroduce it.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

entries=$(grep -rhE '^\s*(APPEND|linux|options)\s.*archisobasedir=' \
  configs/syslinux/archiso_sys-linux.cfg configs/syslinux/archiso_pxe-linux.cfg \
  configs/grub/grub.cfg configs/grub/loopback.cfg configs/efiboot/loader/entries)

count=$(printf '%s\n' "$entries" | wc -l)
[ "$count" -ge 9 ] || { echo "expected at least 9 boot entries, found $count"; exit 1; }

if grep -rq archiso_http_srv configs/syslinux configs/grub configs/efiboot; then
  echo "HTTP PXE entry found: that path copies only the airootfs to RAM, so the root image is never on the medium and an install can never succeed"
  exit 1
fi

if grep -rhE '^[^#]*cms_verify' configs/syslinux configs/grub configs/efiboot | grep -q .; then
  echo "cms_verify found: the ISO is not codesigned, so any boot entry carrying it aborts into an emergency shell"
  exit 1
fi

fail=0
while IFS= read -r line; do
  if ! grep -qE '(^|[[:space:]])copytoram=n([[:space:]]|$)' <<<"$line"; then
    echo "boot entry without copytoram=n: $line"
    fail=1
  fi
done <<<"$entries"

[ "$fail" -eq 0 ] && echo "ok: $count boot entries pin copytoram=n"
exit "$fail"
