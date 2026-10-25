#!/bin/bash
#
# Firmware whose NVRAM will not take another boot entry: Samsung ships some
# laptops with very little, and a machine coming off another install can have
# its store full of that install's entries. The firmware reads fine and refuses
# the write, so the install reaches Limine's efibootmgr --create and nothing
# before it notices. Every UEFI boots EFI/BOOT/BOOT<arch>.EFI when no entry
# matches, so a whole-disk install still has a way to boot.
#
# Fills the NVRAM from a root shell on tty2 while the unattended install runs on
# tty1, in the same boot: firmware compacts its store at the next boot, so a
# store filled before a reboot is not full by the time the installer writes.
# Then checks the installed system boots from the fallback loader.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

DISK="$RUN_DIR/disk.qcow2"
qemu-img create -f qcow2 "$DISK" 40G >/dev/null
cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"

# efivarfs takes a variable in one write: attributes (non-volatile, boot and
# runtime access) then the data. The kernel refuses writes once the store is
# down to its reserve, which is what a full NVRAM looks like from Linux.
mkdir -p "$RUN_DIR/www"
cat >"$RUN_DIR/www/fill-nvram" <<'EOF'
exec >/dev/ttyS0 2>&1
guid=4f6d6172-6368-7946-696c-6c4e56524d00
n=0
for size in 8000 2000 500 100; do
  { printf '\x07\x00\x00\x00'; head -c $size /dev/urandom; } >/tmp/payload
  while cat /tmp/payload >/sys/firmware/efi/efivars/OmarchyFill$n-$guid 2>/dev/null; do
    n=$((n + 1))
  done
done
{ printf '\x07\x00\x00\x00'; head -c 100 /dev/urandom; } >/tmp/payload
cat /tmp/payload >/sys/firmware/efi/efivars/OmarchyProbe-$guid 2>/dev/null && state=accepting || state=full
grep -q "installing bootloader (Limine)" /var/log/omarchy-install.log && order=after-bootloader || order=before-bootloader
echo "nvram-filled: $n variables, $state, $order"
EOF
(cd "$RUN_DIR/www" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
HTTP_PID=$!

# The installer owns tty1; tty2 is a root login with no password.
fill_nvram() {
  local waited=0
  until { press ctrl-alt-f2; sleep 2; ocr_screen | grep -qi "login:"; }; do
    if ((waited >= 120)); then
      capture_console "failure-fill-console"
      echo "Timed out waiting for a console login prompt" >&2
      return 1
    fi
    sleep 2
    ((waited += 4))
  done
  type_text "root"
  press ret
  sleep 2
  type_text "curl -fsS http://10.0.2.2:$HTTP_PORT/fill-nvram -o /tmp/fill-nvram && bash /tmp/fill-nvram"
  press ret
  press ctrl-alt-f1
}

log "Installing unattended while tty2 fills the NVRAM"
INSTALL_ALONGSIDE=fill_nvram
if ! install_unattended "$DISK" "$RUN_DIR/install-serial.log"; then
  echo "--- last lines of the serial console ---" >&2
  tail -n 40 "$RUN_DIR/install-serial.log" >&2 2>/dev/null || true
  exit 1
fi
kill "$HTTP_PID" 2>/dev/null || true
HTTP_PID=""

filled=$(grep -a -o 'nvram-filled: .*' "$RUN_DIR/install-serial.log" | tr -d '\r' || true)
printf '%s\n' "${filled:-nvram-filled: no report}"
if [[ $filled != *", full, "* ]]; then
  echo "The NVRAM was not filled; nothing here would test the installer" >&2
  exit 1
fi
# The fill runs beside the installer, with tens of seconds to spare; a fill that
# still lost the race tested nothing, and says so rather than failing a check.
if [[ $filled != *", before-bootloader" ]]; then
  echo "The installer reached its bootloader before the NVRAM was full; run it again" >&2
  exit 1
fi

ssh_sudo "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
ssh_sudo "efibootmgr" >"$RUN_DIR/efibootmgr.txt" 2>/dev/null || true

check "the installer was refused a boot entry" grep -q "refused a boot entry for Limine" "$RUN_DIR/omarchy-install.log"
check "efibootmgr answered" grep -q "^BootOrder" "$RUN_DIR/efibootmgr.txt"
check "no Limine entry is in NVRAM" bash -c '! grep -q "Limine" "$1"' _ "$RUN_DIR/efibootmgr.txt"
check "the fallback loader is installed" ssh_sudo "test -s /boot/EFI/BOOT/BOOTX64.EFI"
capture_console "success-full-nvram"

stop_vm
finish
