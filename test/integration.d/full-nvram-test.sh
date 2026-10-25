#!/bin/bash
#
# Firmware whose NVRAM will not take another boot entry: Samsung ships some
# laptops with very little, and a machine coming off another install can have
# its store full of that install's entries. The firmware reads fine and refuses
# the write, so the install reaches Limine's efibootmgr --create and nothing
# before it notices. Every UEFI boots EFI/BOOT/BOOT<arch>.EFI when no entry
# matches, so a whole-disk install carries on and boots from that (#127). The
# unit tests fake efibootmgr; this is the firmware actually refusing.
#
# The NVRAM is filled in the install's own boot, since firmware compacts its
# store at the next boot and a store filled before a reboot is no longer full
# when the installer writes. The ISO boots with the cidata stick unplugged, so
# the installer waits at its greeter on tty1; Ctrl-C leaves its root shell, which fills the
# NVRAM, and only then is the stick plugged in and the installer started, as the
# configurator's own abort message says to.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }
if [[ $FIRMWARE != uefi ]]; then
  log "full-nvram skipped: legacy BIOS has no NVRAM boot entries"
  exit 0
fi

DISK="$RUN_DIR/disk.qcow2"
qemu-img create -f qcow2 "$DISK" "${DISK_GB}G" >/dev/null
cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"

# efivarfs takes a variable in one write: attributes (non-volatile, boot and
# runtime access) then the data. The kernel refuses writes once the store is
# down to its reserve, which is what a full NVRAM looks like from Linux.
mkdir -p "$RUN_DIR/www"
cat >"$RUN_DIR/www/fill-nvram" <<'EOF'
exec >/dev/ttyS0 2>&1
guid=4f6d6172-6368-7946-696c-6c4e56524d00
# Fixed-width names, so the probe asks for exactly what the last filler did: the
# kernel counts a variable's name against the space left, not only its data.
write() {
  { printf '\x07\x00\x00\x00'; head -c "$2" /dev/urandom; } >/tmp/payload
  cat /tmp/payload >"/sys/firmware/efi/efivars/$1-$guid" 2>/tmp/err
}
n=0
for size in 8000 2000 500 100; do
  while write "$(printf 'OmarchyFill%04d' "$n")" "$size"; do
    n=$((n + 1))
  done
done
# Only running out of space counts: a read-only efivarfs refuses every write too.
if ((n > 0)) && ! write OmarchyFill9999 100 && grep -q "No space left on device" /tmp/err; then
  state=full
else
  state="not full ($(cat /tmp/err))"
fi
echo "nvram-filled: $n variables, $state"
EOF
(cd "$RUN_DIR/www" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
HTTP_PID=$!

log "Booting the ISO with the cidata stick unplugged"
start_vm "$DISK" "$RUN_DIR/install-serial.log" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2 \
  -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata"

wait_for_screen "Linux by DHH" 300
# The prompt it leaves is coloured past what OCR reads; the fill's own line on
# the serial console is what confirms the command ran.
press ctrl-c
sleep 3

log "Filling the NVRAM"
type_text "curl -fsS http://10.0.2.2:$HTTP_PORT/fill-nvram -o /tmp/fill-nvram && bash /tmp/fill-nvram"
press ret
waited=0
until grep -aq 'nvram-filled: ' "$RUN_DIR/install-serial.log"; do
  if ((waited >= 120)); then
    capture_console "failure-fill-timeout"
    echo "Timed out filling the NVRAM" >&2
    exit 1
  fi
  sleep 2
  ((waited += 2))
done
kill "$HTTP_PID" 2>/dev/null || true
HTTP_PID=""

filled=$(grep -a -o 'nvram-filled: .*' "$RUN_DIR/install-serial.log" | tr -d '\r')
printf '%s\n' "$filled"
if [[ $filled != *", full" ]]; then
  echo "The NVRAM was not filled; nothing here would test the installer" >&2
  exit 1
fi

log "Plugging in the cidata stick and starting the installer"
qmp '"device_add", "arguments": {"driver": "usb-storage", "drive": "cidata", "id": "cidata0"}' >/dev/null
sleep 3
type_text "./.automated_script.sh"
press ret
if ! wait_for_unattended_install install "$RUN_DIR/install-serial.log"; then
  echo "--- last lines of the serial console ---" >&2
  tail -n 40 "$RUN_DIR/install-serial.log" >&2 2>/dev/null || true
  exit 1
fi

ssh_sudo "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
ssh_sudo "efibootmgr" >"$RUN_DIR/efibootmgr.txt" 2>/dev/null || true

check "the installer was refused a boot entry" grep -q "would not register a 'Limine' UEFI boot entry" "$RUN_DIR/omarchy-install.log"
check "efibootmgr answered" grep -q "^BootOrder" "$RUN_DIR/efibootmgr.txt"
check "no Limine entry is in NVRAM" bash -c '! grep -q "Limine" "$1"' _ "$RUN_DIR/efibootmgr.txt"
check "the fallback loader is installed" ssh_sudo "test -s /boot/EFI/BOOT/BOOTX64.EFI"
capture_console "success-full-nvram"

stop_vm
finish
