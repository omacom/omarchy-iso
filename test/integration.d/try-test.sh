#!/bin/bash
#
# Try Omarchy: Just try on the installer's welcome must bring up the real
# desktop from the medium, with pacman usable, and leave the machine's disk
# untouched.
#
# The ISO boots alone with a disk of random bytes for the machine's own. No
# key goes to GRUB, which reads keys through the firmware: it boots the
# installer by itself, whose welcome takes Space for Just try and Return for
# Start Install. Space is pressed there and the desktop waited for. A terminal there fetches a
# bootstrap that authorizes the harness's key and starts sshd, and the rest
# is checked over SSH. Runs on the default variant only: Try boots the ISO,
# which no install variant changes.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

if [[ ${VARIANT:-default} != default ]]; then
  log "Try Omarchy runs on the default variant only; skipping for ${VARIANT:-default}"
  exit 0
fi

# The installer's welcome, reached with no key pressed since the VM started.
# GRUB draws a menu it shows on the serial console too, under a "GNU GRUB"
# header; it must have drawn none, so a keyboard the firmware cannot read
# misses no choice there.
installer_greets_without_a_key() {
  OCR_KMSCON=1 wait_for_screen "Linux by DHH" 300 || return 1
  capture_console "success-try-greeter"
  ! grep -aq "GNU GRUB" "$SERIAL_LOG"
}

# The welcome offers Just try under Start Install, and left alone it waits:
# nothing picks Try, or Install, by itself.
welcome_waits() {
  sleep 15
  OCR_KMSCON=1 ocr_screen | grep -qi "Linux by DHH"
}

# Space on the welcome, as a key through QEMU: Linux reads it, where the
# firmware could not read every keyboard.
# The NIC's link up ($1 true) or down (false). qmp() sends qmp_capabilities
# first, so both its replies must be returns.
nic_link() {
  local reply
  reply=$(qmp "\"set_link\", \"arguments\": {\"name\": \"nic0\", \"up\": $1}")
  [[ $(grep -c '"return"' <<<"$reply") == 2 ]] && ! grep -q '"error"' <<<"$reply"
}

pick_try() {
  capture_console "success-try-welcome"
  press spc
}

# The network comes up only once Try runs (see start_vm below).
network_up() {
  nic_link true
}

# Omarchy's first-login notifications: any of them is the desktop. They are
# light text on dark cards over the wallpaper, which the harness's
# thresholded OCR turns to noise once the wallpaper is up; read the plain
# screendump instead.
wait_for_desktop() {
  local shot="$RUN_DIR/.desktop.ppm" waited=0
  until screendump "$shot" && tesseract "$shot" - 2>/dev/null | grep -qi "Keybindings\|Setup Git\|Update System"; do
    if ! vm_running || ((waited >= 300)); then
      capture_console "failure-try-desktop"
      return 1
    fi
    sleep 3
    ((waited += 3))
  done
}

# The Try user's graphical session on the seat, if any. SDDM's greeter has a
# seat session too, of class greeter, under its own user.
seat_session() {
  ssh_guest 'for s in $(loginctl list-sessions --no-legend | awk "\$4 == \"seat0\" { print \$1 }"); do
      [ "$(loginctl show-session "$s" -p Class --value)" = user ] &&
        [ "$(loginctl show-session "$s" -p Name --value)" = "$(id -un)" ] && { echo "$s"; break; }
    done' </dev/null
}

# End the desktop session with $1, as Omarchy's Logout does (uwsm stop). SDDM
# must log the session in again rather than stop at its greeter. Two stand-ins
# do not reach SDDM: loginctl terminate-session kills sddm-helper too, which
# SDDM reads as a failed login and so shows nothing, and a killed Hyprland is
# restarted inside the same session in Hyprland's crash recovery.
relogin_after() {
  local old new
  old=$(seat_session)
  [[ -n $old ]] || return 1
  try_ssh "$1" || true
  for _ in $(seq 1 30); do
    sleep 2
    new=$(seat_session)
    if [[ -n $new && $new != "$old" ]] && try_ssh 'pgrep -u "$(id -u)" -x Hyprland >/dev/null && pgrep -u "$(id -u)" -x quickshell >/dev/null'; then
      return 0
    fi
  done
  capture_console "failure-try-relogin"
  { echo "== after: $1"; ssh_guest 'loginctl list-sessions; echo; journalctl -b -o short-monotonic -u sddm --no-pager | tail -60' </dev/null; } \
    >>"$RUN_DIR/failure-try-relogin.txt" 2>&1 || true
  return 1
}

# In the session's environment, for hyprctl.
try_ssh() {
  ssh_guest "export XDG_RUNTIME_DIR=/run/user/\$(id -u) \
    HYPRLAND_INSTANCE_SIGNATURE=\$(ls -t /run/user/\$(id -u)/hypr | head -1); $1" </dev/null
}

# The units that failed, and why, are kept for a run that has any.
no_unit_failed() {
  try_ssh 'systemctl is-system-running --wait >/dev/null; ! systemctl --failed --no-legend | grep -q .' && return 0
  try_ssh 'systemctl --failed; for u in $(systemctl --failed --no-legend --plain | cut -d" " -f1); do journalctl -b -u "$u" -o short-monotonic --no-pager | tail -30; done' \
    >"$RUN_DIR/failure-try-units.txt" 2>&1 || true
  # The whole boot, the installer's part and the soft reboot included.
  try_ssh 'sudo journalctl -b -o short-monotonic --no-pager' >"$RUN_DIR/failure-try-journal.txt" 2>&1 || true
  return 1
}

[[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
disk="$RUN_DIR/machine.qcow2"
head -c $((64 << 20)) /dev/urandom >"$RUN_DIR/machine.raw"
qemu-img convert -f raw -O qcow2 "$RUN_DIR/machine.raw" "$disk"
rm "$RUN_DIR/machine.raw"
cp "$disk" "$RUN_DIR/machine-pristine.qcow2"
if [[ $FIRMWARE == uefi ]]; then
  cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
fi

log "Booting the ISO alone and picking Try in the installer"
# The live system runs with no network, as on a laptop whose Wi-Fi it has no
# firmware for, and Try gets one: the NIC's link stays down until Try's
# desktop shows. The live system's network state must not reach Try, whose
# clock then never synchronized. The NIC has
# an id because set_link on the netdev does not tell the guest.
NIC_EXTRA=",id=nic0"
start_vm "$disk" "$RUN_DIR/serial.log" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2 \
  -device intel-hda -device hda-duplex,audiodev=noaudio -audiodev none,id=noaudio
nic_link false ||
  { echo "Could not take the NIC's link down" >&2; exit 1; }
check "GRUB shows no menu, and the installer greets with no key pressed" installer_greets_without_a_key
check "the welcome waits for a key" welcome_waits
check "Space picks Just try" pick_try
check "Try Omarchy reaches the desktop" wait_for_desktop
check "the network comes up in Try" network_up
capture_console "success-try-desktop"

mkdir -p "$BASE_DIR/www"
cat >"$BASE_DIR/www/bootstrap-try" <<EOF
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "$(cat "$SSH_KEY.pub")" >>~/.ssh/authorized_keys
sudo systemctl start sshd.service
EOF
(cd "$BASE_DIR/www" && exec python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
HTTP_PID=$!
press meta_l-ret
sleep 4
type_text "curl -fsS http://10.0.2.2:$HTTP_PORT/bootstrap-try -o /tmp/bs && bash /tmp/bs"
press ret
check "the Try session answers SSH" wait_for_ssh 120 failure-try-ssh

check "the root is the Try overlay" try_ssh '[ "$(findmnt -no FSTYPE,SOURCE /)" = "overlay omarchy-try" ]'
# Started from the installer without the firmware, the boot loader or kexec:
# one soft reboot of the kernel the ISO booted.
check "Try started by a soft reboot of the installer" try_ssh \
  '[ "$(systemctl show -p SoftRebootsCount --value)" = 1 ] && grep -q "archisobasedir=" /proc/cmdline'
# The installer lets its Wi-Fi and audio controllers go, and the session
# probes driverless devices again (omarchy-try, omarchy-try-reprobe). The
# VM's HDA controller went through that; the tablet's HID interface, released
# by hand, shows the probe itself.
check "the audio controller the installer let go has a driver again" try_ssh \
  'for d in /sys/bus/pci/devices/*; do case $(cat "$d/class") in 0x0403*) [ -e "$d/driver" ] || exit 1; found=1 ;; esac; done; [ -n "$found" ] && [ -e /proc/asound/card0 ]'
check "the session probed again the devices left without a driver" try_ssh \
  '[ "$(systemctl show -p ExecMainExitTimestampMonotonic --value omarchy-try-reprobe.service)" != 0 ] &&
    [ "$(systemctl show -p Result --value omarchy-try-reprobe.service)" = success ] &&
    i=$(ls /sys/bus/usb/drivers/usbhid | grep : | head -1) && [ -n "$i" ] &&
    echo "$i" | sudo tee /sys/bus/usb/drivers/usbhid/unbind >/dev/null && [ ! -e "/sys/bus/usb/devices/$i/driver" ] &&
    sudo /usr/local/lib/omarchy-try/omarchy-try-reprobe && [ -e "/sys/bus/usb/devices/$i/driver" ]'
check "systemd-gpt-auto-generator is off" try_ssh \
  '[ "$(readlink /etc/systemd/system-generators/systemd-gpt-auto-generator)" = /dev/null ]'
check "no unit failed" no_unit_failed
# The soft reboot ends on tty1 (systemd's reduce_vt()), and the starting screen
# is drawn there until SDDM takes the screen.
check "Try drew the starting screen again on tty1" try_ssh \
  'sudo journalctl -b -u omarchy-try-console -o cat | grep -qx "Drew the starting screen on tty1"'
# The hardware setup an install runs for this machine ran in the session
# (omarchy-try-hardware), from the stick's offline repository.
# The system part runs beside the desktop's start, so it may still run here.
check "Try ran this machine's hardware setup" try_ssh \
  'for u in omarchy-try-hardware.service omarchy-try-hardware-user.service; do
     timeout 600 bash -c "until [ \"\$(systemctl show -p ExecMainExitTimestampMonotonic --value $u)\" != 0 ]; do sleep 2; done" &&
       [ "$(systemctl show -p Result --value "$u")" = success ] || exit 1
   done'
# --active exits 1 for no grant; a missing or broken helper exits otherwise.
check "the bar shows no passwordless sudo warning" try_ssh 'omarchy-sudo-passwordless --active; [ $? = 1 ]'
check "Try idles as an install does" try_ssh '[ "$(omarchy-toggle-idle status | jq -r .enabled)" = false ]'
check "a reboot from Try arms no watchdog" try_ssh '[ "$(systemctl show -p RebootWatchdogUSec --value)" = 0 ]'
# The welcome waits up to 120 s for the shell, then up to 180 s for
# first-run's notifications (omarchy-try-welcome).
check "Try says once what the session is" try_ssh \
  'timeout 330 bash -c "until [ -e ~/.local/state/omarchy/try-welcomed ]; do sleep 2; done"'
# The layers are stamped as updated (build-try-layer.sh), so the boot redid
# none of pacman's work: ldconfig alone is seconds from a USB stick.
check "the boot skipped the ConditionNeedsUpdate= units" try_ssh \
  '! systemctl show ldconfig.service systemd-hwdb-update.service systemd-journal-catalog-update.service systemd-sysusers.service -p ConditionResult | grep -q yes'
check "Hyprland runs with a monitor" try_ssh "hyprctl -j monitors | jq -e 'length > 0'"
check "the Omarchy shell runs" try_ssh "pgrep -x quickshell"
# An install adds these only on the machines that need them, so the root
# image leaves them out; Try runs on whatever machine it boots.
check "the session has the audio firmware" try_ssh "pacman -Q sof-firmware alsa-firmware >/dev/null"
check "Bluetooth is enabled for the live desktop" try_ssh "systemctl is-enabled -q bluetooth.service"
check "disk and host-hibernate units are masked" try_ssh \
  'for u in systemd-hibernate-clear.service lvm2-monitor.service lvm2-lvmpolld.socket systemd-boot-random-seed.service; do [ "$(systemctl is-enabled "$u" 2>/dev/null || true)" = masked ] || exit 1; done'
check "nothing on the machine's disk is mounted" try_ssh '! lsblk -nro MOUNTPOINTS /dev/vda | grep -q .'
# The session has no password, so nothing may ask for one.
# Try asks no questions, so it keeps its clock right by itself: NTP, and the
# timezone geo.omarchy.org gives for this network. It never writes the
# machine's RTC: timesyncd keeps the kernel's STA_UNSYNC set, which turns off
# the kernel's 11-minute RTC write (kernel/time/ntp.c). NTPSynchronized
# ignores that bit; it reads the kernel's maximum error.
# Try's own timesyncd got an answer, not only the kernel state the
# installer's left.
check "the clock synchronizes over NTP" try_ssh \
  'timeout 90 bash -c "until [ \"\$(timedatectl show -p NTPSynchronized --value)\" = yes ] && [ -n \"\$(timedatectl show-timesync -p NTPMessage --value)\" ]; do sleep 2; done"'
check "NTP never writes the machine's RTC" try_ssh \
  '[ "$(timedatectl show -p LocalRTC --value)" = yes ] && python3 -c "import ctypes; t = ctypes.create_string_buffer(256); ctypes.CDLL(None).adjtimex(t); raise SystemExit(0 if int.from_bytes(t[40:44], \"little\") & 0x40 else 1)"'
check "the timezone is the one geo.omarchy.org gives" try_ssh \
  'for i in 1 2 3 4 5; do geo=$(curl -fsS --max-time 10 https://geo.omarchy.org/ | jq -r ".timezone // empty") && [ -n "$geo" ] && break; sleep 3; done; [ -n "$geo" ] && timeout 90 bash -c "until [ \"\$(readlink -f /etc/localtime)\" = \"/usr/share/zoneinfo/\$1\" ]; do sleep 2; done" _ "$geo"'
check "no lock is asked for before a suspend" try_ssh \
  '[ "$(systemctl --user show -p ConditionResult --value omarchy-sleep-lock.service)" = no ]'
check "a logout logs straight back in" relogin_after 'uwsm stop'
check "SDDM state and passwordless Try theme are installed" try_ssh \
  'sudo grep -qx "User=omarchy" /var/lib/sddm/state.conf && grep -qx "Current=omarchy-try" /etc/sddm.conf.d/99-omarchy-login.conf && [ -x /usr/local/bin/omarchy-try-session ]'
# Nothing waits for the keyring at boot; wait for it here.
check "the session made its own pacman keyring" try_ssh \
  'timeout 120 bash -c "while systemctl is-active -q omarchy-try-keyring; do sleep 1; done" && [ "$(systemctl show -p Result --value omarchy-try-keyring)" = success ]'
check "pacman installs a package" try_ssh "sudo pacman -S --noconfirm --needed cowsay >/dev/null && cowsay try"

stop_vm
check "the machine's disk is unchanged" qemu-img compare -q "$RUN_DIR/machine-pristine.qcow2" "$disk"
finish
