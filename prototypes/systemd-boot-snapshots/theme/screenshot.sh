#!/bin/bash

# Screenshot the systemd-boot menu (and the systemd-stub splash) of a
# prototype run, booting under Secure Boot with an already enrolled vars.fd.
#
#   theme/screenshot.sh WORKDIR NAME BOOTLOADER.efi [SPLASH_FRAMES]
#
# Copies WORKDIR's ESP without the negative-test entries, installs
# BOOTLOADER.efi (signed with the prototype key) as the loader, holds the menu
# for a screenshot, then presses Enter and grabs SPLASH_FRAMES frames 40 ms
# apart while systemd-stub shows the splash. Writes WORKDIR/shots/NAME*.png.

set -euo pipefail
WORK=$1 NAME=$2 LOADER=$3 FRAMES=${4:-0}
OVMF=/usr/share/edk2/x64
export MTOOLS_SKIP_CHECK=1
cd "$WORK"
mkdir -p shots

cp esp.img shot-esp.img
for f in ::/EFI/Linux/tampered.efi ::/EFI/Linux/unsigned.efi ::/loader/entries/inject.conf; do
  mdel -i shot-esp.img@@1M "$f" 2>/dev/null || true
done
/usr/lib/systemd/systemd-sbsign sign --private-key=keys/db.key --certificate=keys/db.crt \
  --output=shot-loader.efi "$LOADER" >/dev/null
mcopy -o -i shot-esp.img@@1M shot-loader.efi ::/EFI/BOOT/BOOTX64.EFI
printf 'default %s\ntimeout menu-force\neditor no\nconsole-mode keep\n' "$(sed -n 's/^default //p' esp/loader/loader.conf)" >shot-loader.conf
mcopy -o -i shot-esp.img@@1M shot-loader.conf ::/loader/loader.conf
cp vars.fd shot-vars.fd

sock=$WORK/shot.qmp
rm -f "$sock"
qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -machine q35,smm=on \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF/OVMF_CODE.secboot.4m.fd" \
  -drive if=pflash,format=raw,unit=1,file=shot-vars.fd \
  -drive file=shot-esp.img,format=raw,if=virtio -drive file=root.img,format=raw,if=virtio,snapshot=on \
  -display none -vga std -serial null -qmp "unix:$sock,server=on,wait=off" -no-reboot &
qemu_pid=$!
trap 'kill $qemu_pid 2>/dev/null || true' EXIT

qmp() { # one or more QMP commands as JSON
  { echo '{"execute":"qmp_capabilities"}'; printf '%s\n' "$@"; sleep 0.2; } | socat - "UNIX-CONNECT:$sock" >/dev/null
}
dump() { qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$WORK/shots/$1.ppm\"}}"; }

for _ in $(seq 50); do [[ -S $sock ]] && break; sleep 0.1; done
sleep 5
dump "$NAME-menu"
if ((FRAMES > 0)); then
  # One connection for the key press and every frame: the guest boots and
  # powers off within a second, too fast for a connection per frame.
  {
    echo '{"execute":"qmp_capabilities"}'
    echo '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"ret"}]}}'
    for i in $(seq "$FRAMES"); do
      sleep 0.04
      echo "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$WORK/shots/$NAME-boot-$i.ppm\"}}"
    done
    sleep 0.3
  } | socat - "UNIX-CONNECT:$sock" >/dev/null 2>&1 || true
fi
qmp '{"execute":"quit"}' || true
wait $qemu_pid 2>/dev/null || true

for ppm in shots/"$NAME"-*.ppm; do
  magick "$ppm" "${ppm%.ppm}.png" && rm -f "$ppm"
done
ls shots/"$NAME"-*.png
