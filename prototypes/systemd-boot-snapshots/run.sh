#!/bin/bash

# QEMU prototype: systemd-boot + signed multi-profile UKIs + btrfs snapshots
# under UEFI Secure Boot. Runs unprivileged on an Omarchy host.
#
#   prototypes/systemd-boot-snapshots/run.sh [WORKDIR]
#
# Builds a test key, two kernel versions and three boot images, a btrfs root
# with snapper-style snapshots, runs omarchy-boot-sync to produce the UKIs,
# then boots OVMF in Secure Boot Setup Mode: systemd-boot enrolls the key,
# and every later boot runs with Secure Boot enforcing. Each case boots one
# menu entry, and the guest reports over serial what actually came up.
#
# Takes about a minute; needs qemu, edk2-ovmf, KVM access, an older
# linux-omarchy package in the pacman cache, and nothing run as root.
#
#   SPLASH=logo.bmp       embed a systemd-stub splash in every UKI
#   SDBOOT_EFI=boot.efi   boot a different systemd-boot (e.g. a recolored one)

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=${1:-${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-sdboot-prototype}
OVMF=/usr/share/edk2/x64
SDBOOT_EFI=${SDBOOT_EFI:-/usr/lib/systemd/boot/efi/systemd-bootx64.efi}
SBSIGN=/usr/lib/systemd/systemd-sbsign
LIVE_KVER=${LIVE_KVER:-$(uname -r)}
OLD_KVER_PKG=${OLD_KVER_PKG:-$(ls /var/cache/pacman/pkg/linux-omarchy-[0-9]*.pkg.tar.zst | grep -v "/linux-omarchy-${LIVE_KVER%-omarchy}-" | sort -V | tail -1)}
ROOT_UUID=0a4ac0fe-5eed-4b00-8000-000000000001
export MTOOLS_SKIP_CHECK=1

mkdir -p "$WORK"/{logs,keys,kernels,store,esp,shots}
cd "$WORK"

step() { printf '\n\e[1;34m== %s\e[0m\n' "$*"; }

sign() { "$SBSIGN" sign --private-key=keys/db.key --certificate=keys/db.crt --output="$2" "$1" >/dev/null; }

# --- keys ---------------------------------------------------------------------
step "Test Secure Boot key (stands in for the machine owner key)"
if [[ ! -f keys/db.crt ]]; then
  openssl req -quiet -new -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -subj "/CN=Omarchy Prototype Secure Boot Key/" -keyout keys/db.key -out keys/db.crt
fi
openssl x509 -in keys/db.crt -noout -subject -fingerprint -sha256

# --- kernels and boot images -------------------------------------------------
step "Kernels: live $LIVE_KVER, older from $(basename "$OLD_KVER_PKG")"
OLD_KVER=$(basename "$OLD_KVER_PKG" | sed -E 's/^linux-omarchy-(.*)-x86_64\.pkg\.tar\.zst$/\1-omarchy/')
if [[ ! -f kernels/$OLD_KVER/usr/lib/modules/$OLD_KVER/vmlinuz ]]; then
  mkdir -p "kernels/$OLD_KVER"
  bsdtar -xf "$OLD_KVER_PKG" -C "kernels/$OLD_KVER" usr/lib/modules
fi
ln -sfn usr/lib "kernels/$OLD_KVER/lib" # mkinitcpio -r looks in <root>/lib/modules
# The package carries no modules.dep; pacman's depmod hook writes it on install.
[[ -f kernels/$OLD_KVER/usr/lib/modules/$OLD_KVER/modules.dep ]] || depmod -b "kernels/$OLD_KVER/usr" "$OLD_KVER"

build_initramfs() { # out kver moduleroot extra-file
  local conf=kernels/mkinitcpio-$(basename "$1").conf
  cp "$HERE/guest/mkinitcpio.conf" "$conf"
  [[ -n ${4:-} ]] && echo "FILES=($4)" >>"$conf"
  [[ -f $1 ]] || /usr/bin/mkinitcpio -c "$conf" -k "$2" -r "$3" -g "$1" >"logs/$(basename "$1").log" 2>&1 ||
    { tail -20 "logs/$(basename "$1").log"; exit 1; }
}
# Two builds for the live kernel: image A, then image B after a pretend
# initramfs change (an extra file). Snapshot 2 was taken while A was current.
echo "initramfs A" >kernels/marker-A
echo "initramfs B" >kernels/marker-B
build_initramfs kernels/initramfs-live-A.img "$LIVE_KVER" / "$WORK/kernels/marker-A"
build_initramfs kernels/initramfs-live-B.img "$LIVE_KVER" / "$WORK/kernels/marker-B"
build_initramfs kernels/initramfs-old.img "$OLD_KVER" "$WORK/kernels/$OLD_KVER"
ls -la kernels/*.img

# --- root filesystem -----------------------------------------------------------
step "btrfs root: @ (live) + snapper snapshots 1-4"
rm -rf rootdir && mkdir -p rootdir/@
make_tree() { # dir id kver
  local d=$1
  mkdir -p "$d"/{bin,sbin,etc,proc,sys,dev,run,tmp,usr/lib,lib64,"usr/lib/modules/$3"}
  install -m755 /usr/lib/initcpio/busybox "$d/bin/busybox"
  cp /usr/lib/libc.so.6 /usr/lib/libcrypt.so.2 "$d/usr/lib/"
  cp /usr/lib64/ld-linux-x86-64.so.2 "$d/lib64/"
  ln -sfn usr/lib "$d/lib"
  install -m755 "$HERE/guest/init" "$d/sbin/init"
  echo "$2" >"$d/etc/proto-id"
  echo linux-omarchy >"$d/usr/lib/modules/$3/pkgbase"
}
snapshot() { # num kver description date
  mkdir -p "rootdir/@/.snapshots/$1"
  make_tree "rootdir/@/.snapshots/$1/snapshot" "snapshot-$1" "$2"
  cat >"rootdir/@/.snapshots/$1/info.xml" <<EOF
<?xml version="1.0"?>
<snapshot>
  <type>single</type>
  <num>$1</num>
  <date>$4</date>
  <description>$3</description>
  <cleanup>number</cleanup>
</snapshot>
EOF
}
make_tree rootdir/@ live "$LIVE_KVER"
snapshot 1 "$OLD_KVER" "4.5.2" "2026-10-02 09:14:00"
snapshot 2 "$LIVE_KVER" "4.6.0" "2026-11-03 18:40:00"
snapshot 3 "$LIVE_KVER" "4.6.1" "2026-11-13 08:05:00"
snapshot 4 "$LIVE_KVER" "taken before omarchy-boot-sync existed" "2026-09-01 12:00:00"

# --- omarchy-boot-sync ----------------------------------------------------------
step "omarchy-boot-sync: import images, pin snapshots, build signed UKIs"
rm -rf store esp && mkdir -p store esp
export OMARCHY_BOOT_ESP=$WORK/esp OMARCHY_BOOT_STORE=$WORK/store OMARCHY_BOOT_SNAPSHOTS=$WORK/rootdir/@/.snapshots
export OMARCHY_BOOT_KEY=$WORK/keys/db.key OMARCHY_BOOT_CERT=$WORK/keys/db.crt OMARCHY_BOOT_LIVE=$LIVE_KVER
export OMARCHY_BOOT_CMDLINE="root=UUID=$ROOT_UUID rootflags=subvol=@ rw console=ttyS0 loglevel=3 panic=-1"
[[ -n ${SPLASH:-} ]] && export OMARCHY_BOOT_SPLASH=$SPLASH
sync_tool=$HERE/omarchy-boot-sync

# Replays the order things happen on a real machine.
$sync_tool import "$OLD_KVER" "kernels/$OLD_KVER/usr/lib/modules/$OLD_KVER/vmlinuz" kernels/initramfs-old.img
OMARCHY_BOOT_LIVE=$OLD_KVER $sync_tool pin 1 # snapshot 1, while the old kernel was installed
$sync_tool import "$LIVE_KVER" "/usr/lib/modules/$LIVE_KVER/vmlinuz" kernels/initramfs-live-A.img
$sync_tool pin 2
$sync_tool import "$LIVE_KVER" "/usr/lib/modules/$LIVE_KVER/vmlinuz" kernels/initramfs-live-B.img
$sync_tool pin 3
$sync_tool sync
ls -la esp/EFI/Linux

# --- ESP --------------------------------------------------------------------------
step "ESP: signed systemd-boot, enrollment keys, negative-test images"
mkdir -p esp/EFI/BOOT esp/EFI/systemd esp/loader/keys/auto esp/loader/entries
sign "$SDBOOT_EFI" esp/EFI/BOOT/BOOTX64.EFI
cp esp/EFI/BOOT/BOOTX64.EFI esp/EFI/systemd/systemd-bootx64.efi
python3 -I "$HERE/lib/mkauth.py" keys/db.crt keys/db.key esp/loader/keys/auto

# The sync points loader.conf's default at the live profile, which as the
# first profile of its UKI has the bare file name as its entry id.
live_uki=$(sed -n 's/^default //p' esp/loader/loader.conf)
image_a=$(basename "$(readlink -f "store/images/$(cat rootdir/@/.snapshots/2/omarchy-boot-image)")")

# A signed UKI with one byte of its embedded command line changed afterwards.
python3 -I - "esp/EFI/Linux/$live_uki" esp/EFI/Linux/tampered.efi <<'EOF'
import sys
data = bytearray(open(sys.argv[1], "rb").read())
i = data.index(b"loglevel=3")
data[i + 9] = ord("7")
open(sys.argv[2], "wb").write(data)
EOF
# The same UKI with its signature stripped (rebuilt unsigned).
python3 -I "$HERE/lib/uki_build.py" --stub /usr/lib/systemd/boot/efi/linuxx64.efi.stub --out esp/EFI/Linux/unsigned.efi \
  .osrel=<(printf 'NAME=Unsigned\nID=unsigned\n') .cmdline=<(printf '%s' "$OMARCHY_BOOT_CMDLINE") \
  .initrd=kernels/initramfs-live-B.img .linux="/usr/lib/modules/$LIVE_KVER/vmlinuz"

# A type #1 entry that tries to boot the signed live UKI into snapshot 2 by
# passing its own command line. Under Secure Boot systemd-stub must ignore it.
cat >esp/loader/entries/inject.conf <<EOF
title Injected command line
efi /EFI/Linux/$live_uki
options root=UUID=$ROOT_UUID rootflags=subvol=@/.snapshots/2/snapshot rw console=ttyS0 INJECTED=1
EOF

# --- disks ---------------------------------------------------------------------------
step "Disk images"
rm -f esp.img root.img
truncate -s 400M esp.img
printf 'label: gpt\nstart=2048, type=uefi, name=ESP\n' | sfdisk -q esp.img
esp_sectors=$(sfdisk -d esp.img | sed -n 's/.*size= *\([0-9]*\).*/\1/p')
mkfs.fat -F 32 -n OMARCHYESP --offset 2048 esp.img $((esp_sectors / 2)) >/dev/null
mcopy -s -i esp.img@@1M esp/* ::

truncate -s 512M root.img
mkfs.btrfs -q -U "$ROOT_UUID" -L omarchy-root --rootdir rootdir \
  --subvol rw:@ --subvol rw:@/.snapshots \
  --subvol ro:@/.snapshots/1/snapshot --subvol ro:@/.snapshots/2/snapshot \
  --subvol ro:@/.snapshots/3/snapshot --subvol ro:@/.snapshots/4/snapshot root.img

cp "$OVMF/OVMF_VARS.4m.fd" vars.fd # Setup Mode: no PK yet

# --- boots ---------------------------------------------------------------------------
loader_conf() { # default [timeout]
  printf 'default %s\ntimeout %s\neditor no\nsecure-boot-enroll force\nconsole-mode keep\n' "$1" "${2:-0}" >loader.conf
  mcopy -o -i esp.img@@1M loader.conf ::/loader/loader.conf
}

qemu() { # name seconds [extra qemu args]
  local name=$1 seconds=$2
  shift 2
  timeout "$seconds" qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -machine q35,smm=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF/OVMF_CODE.secboot.4m.fd" \
    -drive if=pflash,format=raw,unit=1,file=vars.fd \
    -drive file=esp.img,format=raw,if=virtio \
    -drive file=root.img,format=raw,if=virtio \
    -serial "file:logs/$name.serial" -display none -no-reboot "$@" || true
}

boot() { # name default-entry [seconds]
  loader_conf "$2"
  qemu "$1" "${3:-60}"
  tr -d '\r' <"logs/$1.serial" | sed 's/\x1b\[[0-9;?]*[A-Za-z]//g' >"logs/$1.log"
  grep '^PROTO-' "logs/$1.log" | grep -v PROTO-DONE | sed "s/^/  [$1] /" || echo "  [$1] (guest never reported)"
}

step "Boot 0: Setup Mode, systemd-boot enrolls the key and reboots"
boot enroll "$live_uki"
step "Boot cases with Secure Boot enforcing"
# Entry ids: a UKI's first profile is the file name, later ones <file>@<profile ID>.
boot live "$live_uki"
boot snapshot3 "$live_uki@snapshot-3"
boot snapshot2 "omarchy-$image_a.efi"
boot snapshot1 "omarchy-$OLD_KVER-*.efi"
boot inject inject.conf
boot tampered tampered.efi 25
boot unsigned unsigned.efi 25

# --- verdict --------------------------------------------------------------------------
step "Results"
pass=0 fail=0
check() { # description command...
  if "${@:2}" >/dev/null 2>&1; then printf '  \e[32mPASS\e[0m %s\n' "$1"; pass=$((pass + 1))
  else printf '  \e[31mFAIL\e[0m %s\n' "$1"; fail=$((fail + 1)); fi
}
has() { grep -qE "$2" "logs/$1.log"; }
lacks() { ! grep -qE "$2" "logs/$1.log"; }

check "sync made the live profile the default entry" test -n "$live_uki" -a -f "esp/EFI/Linux/$live_uki"
check "systemd-boot enrolled the key in Setup Mode" has enroll 'Custom Secure Boot keys successfully enrolled'
check "live boots with Secure Boot on, @ writable" has live 'PROTO-RESULT id=live .*secureboot=1 writable=yes'
check "live root is subvol @" has live 'PROTO-ROOT .* btrfs .*subvol=/@( |,|$)'
check "snapshot 3 (current image, profile 1) boots" has snapshot3 "PROTO-RESULT id=snapshot-3 kernel=$LIVE_KVER secureboot=1 writable=yes"
check "snapshot 3 is a profile of the live UKI" has snapshot3 "PROTO-ENTRY $live_uki@snapshot-3"
check "read-only snapshot is overlaid writable" has snapshot3 'PROTO-ROOT overlay '
check "snapshot 2 boots its pinned older image A" has snapshot2 "PROTO-ENTRY omarchy-$image_a.efi "
check "snapshot 2 comes up" has snapshot2 "PROTO-RESULT id=snapshot-2 kernel=$LIVE_KVER secureboot=1"
check "snapshot 1 boots the old kernel $OLD_KVER" has snapshot1 "PROTO-RESULT id=snapshot-1 kernel=$OLD_KVER secureboot=1"
check "snapshot 4 (never pinned) is not offered" bash -c '! grep -qa ID=snapshot-4 esp/EFI/Linux/omarchy-*.efi'
check "injected command line is ignored" has inject 'PROTO-RESULT id=live '
check "injected command line never reaches the kernel" lacks inject 'PROTO-CMDLINE .*(INJECTED|snapshots/2)'
check "tampered UKI is refused" lacks tampered 'PROTO-RESULT'
check "firmware reports the tampered UKI as Access denied" has tampered 'tampered.efi: Access denied'
check "unsigned UKI is refused" lacks unsigned 'PROTO-RESULT'
check "firmware reports the unsigned UKI as Access denied" has unsigned 'unsigned.efi: Access denied'
printf '\n%d passed, %d failed. Logs: %s/logs\n' "$pass" "$fail" "$WORK"
((fail == 0))
