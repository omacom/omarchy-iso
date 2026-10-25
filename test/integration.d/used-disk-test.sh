#!/bin/bash
#
# Installing over a disk that has had a life: the base install always starts
# from a blank disk, and a machine people actually install on rarely has one.
# The live ISO's udev assembles an old RAID member and activates an old LVM
# volume group the moment it sees the disk, and anything left holding a
# partition keeps the kernel on the old partition table, so archinstall cannot
# partition the disk it was given.
#
# Boots the live ISO once to leave an Ubuntu-server-style disk behind (an ESP,
# then a RAID1 member carrying LVM with swap and an ext4 root), installs
# unattended over it, and checks the installed system boots with nothing of
# the old stack left.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

USED_DISK="$RUN_DIR/used.qcow2"
qemu-img create -f qcow2 "$USED_DISK" 40G >/dev/null
cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"

mkdir -p "$RUN_DIR/www"
cat >"$RUN_DIR/www/old-install" <<'EOF'
exec >/dev/ttyS0 2>&1
set -ex
disk=/dev/vda
sgdisk --zap-all $disk
sgdisk -n1:0:+512M -t1:ef00 -n2:0:0 -t2:fd00 $disk
partprobe $disk
udevadm settle
mkfs.fat -F32 ${disk}1
mdadm --create /dev/md0 --level=1 --raid-devices=2 --metadata=1.2 --run ${disk}2 missing
pvcreate -ff -y /dev/md0
vgcreate oldvg /dev/md0
lvcreate -y -L 1G -n swap oldvg
lvcreate -y -l 100%FREE -n root oldvg
mkswap /dev/oldvg/swap
mkfs.ext4 -q /dev/oldvg/root
echo "old-install:"; lsblk -rno NAME,TYPE $disk
sync
poweroff
EOF
(cd "$RUN_DIR/www" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
HTTP_PID=$!

log "Boot 1: leaving an old RAID and LVM install on the disk"
start_vm "$USED_DISK" "$RUN_DIR/old-install-serial.log" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2

# The installer owns tty1; tty2 is a root login with no password.
waited=0
until { press ctrl-alt-f2; sleep 3; ocr_screen | grep -qi "login:"; }; do
  if ((waited >= 300)); then
    capture_console "failure-old-install-console"
    echo "Timed out waiting for a console login prompt" >&2
    exit 1
  fi
  sleep 5
  ((waited += 8))
done
type_text "root"
press ret
sleep 3
type_text "curl -fsS http://10.0.2.2:$HTTP_PORT/old-install -o /tmp/old-install && bash /tmp/old-install"
press ret

waited=0
while vm_running; do
  if ((waited >= 300)); then
    capture_console "failure-old-install-timeout"
    echo "Timed out laying down the old install" >&2
    exit 1
  fi
  sleep 5
  ((waited += 5))
done
kill "$HTTP_PID" 2>/dev/null || true
HTTP_PID=""

old_layout=$(grep -a -A10 '^old-install:' "$RUN_DIR/old-install-serial.log" || true)
printf '%s\n' "$old_layout"
if ! grep -q ' raid1' <<<"$old_layout" || ! grep -q ' lvm' <<<"$old_layout"; then
  echo "The old install was not laid down; nothing here would test the installer" >&2
  exit 1
fi

log "Boot 2: installing unattended over it"
cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
if ! install_unattended "$USED_DISK" "$RUN_DIR/install-serial.log"; then
  echo "--- last lines of the serial console ---" >&2
  tail -n 40 "$RUN_DIR/install-serial.log" >&2 2>/dev/null || true
  exit 1
fi

ssh_sudo "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
ssh_guest "lsblk -o NAME,TYPE,FSTYPE,MOUNTPOINTS" >"$RUN_DIR/lsblk.txt" 2>/dev/null || true

# An empty answer is a failed query, not a clean disk.
types=$(ssh_guest "lsblk -rno TYPE" 2>/dev/null | tr -d '\r' || true)
check "the installer stopped the old RAID array" grep -q "Stopping /dev/md" "$RUN_DIR/omarchy-install.log"
check "the root filesystem is btrfs" test "$(ssh_guest "findmnt -no FSTYPE /" 2>/dev/null | tr -d '\r')" = btrfs
check "the installed system lists its partitions" grep -qx part <<<"$types"
check "no RAID array survived" bash -c '! grep -q "^raid" <<<"$1"' _ "$types"
check "no LVM volume survived" bash -c '! grep -qx lvm <<<"$1"' _ "$types"
capture_console "success-used-disk"

stop_vm
finish
