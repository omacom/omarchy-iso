#!/bin/bash
#
# test/integration.d/base-test.sh without a VM: its functions are taken out
# of the harness and run against stubs for QEMU, QMP, OCR and SSH, so what
# the harness decides from what it sees can be checked here.

# shellcheck disable=SC2034,SC2329 # the variables and stubs are used by the functions taken out of the harness

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
harness="$ROOT/test/integration.d/base-test.sh"
bash -n "$harness"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The harness is a script that starts a VM when it is read; take only the
# functions under test.
take_from() {
  local file="$1" name
  shift
  for name; do
    eval "$(sed -n "/^$name() {\$/,/^}\$/p" "$file")"
    declare -F "$name" >/dev/null || fail "${file#"$ROOT"/} no longer has $name"
  done
}
take() { take_from "$harness" "$@"; }

# The scenarios run these under set -e, outside any condition, so a failing
# step ends the scenario there. Run them the same way: an `if` around one
# would switch set -e off inside it and hide that.
run() {
  set +e
  (set -e; "$@") >"$work/out" 2>&1
  status=$?
  set -e
}

log() { :; }
vm_running() { true; }
capture_console() { :; }
capture_vm_state() { :; }
type_text() { :; }
press() { echo "$1" >>"$work/pressed"; }
# Time passes only in sleep, and is kept in a file because the functions
# run in a subshell; SECONDS moves with it for the waits that read the
# clock. A loop that sleeps far past its budget is stopped here instead of
# hanging the test.
sleep() {
  local slept
  slept=$(($(<"$work/slept") + ${1%.*}))
  echo "$slept" >"$work/slept"
  SECONDS=$((SECONDS + ${1%.*}))
  ((slept <= 100000)) || { echo "still waiting after ${slept}s" >&2; exit 99; }
}
echo 0 >"$work/slept"

# ---------------------------------------------- console login on the next VT
#
# bootstrap_ssh logs in on tty3, then tty4, then tty5. When the VT switches
# before the password prompt shows, that attempt is lost, not the scenario.

take bootstrap_ssh
BASE_DIR="$work/base"
SSH_KEY="$work/id_ed25519"
HTTP_PORT=2323
GUEST_USER=omarchy GUEST_PASSWORD=omarchy
echo "ssh-ed25519 AAAA test" >"$SSH_KEY.pub"
mkdir -p "$work/bin"
printf '#!/bin/sh\nexit 0\n' >"$work/bin/python3" # the bootstrap's HTTP server
chmod +x "$work/bin/python3"
PATH="$work/bin:$PATH"
ocr_screen() { echo "omarchy-test login:"; }
# The first attempt's password prompt never shows; the second one's does.
wait_for_screen() { [[ $(grep ctrl-alt-f "$work/pressed" | tail -n1) != ctrl-alt-f3 ]]; }
wait_for_ssh() { true; }

: >"$work/pressed"
run bootstrap_ssh
((status == 0)) || fail "a lost password prompt on tty3 ended the scenario: $(cat "$work/out")"
grep -qx ctrl-alt-f4 "$work/pressed" || fail "the second attempt did not use tty4: $(paste -sd' ' "$work/pressed")"
echo "ok - a console login whose password prompt never shows is retried on the next VT"

# --------------------------------------- the install wait keeps to its budget
#
# An encrypted BIOS install whose Plymouth prompt is typed into blind, sample
# after sample, still times out after INSTALL_TIMEOUT, not later.

take wait_for_unattended_install answer_luks_prompt
ENCRYPT=true
INSTALL_TIMEOUT=600
ssh_guest() { false; }
ocr_screen() { echo "OMARCHY"; } # the logo and nothing else, for ever

echo 0 >"$work/slept"
: >"$work/pressed"
run wait_for_unattended_install install
slept=$(<"$work/slept")
grep -qx ret "$work/pressed" || fail "the passphrase was never typed at the logo"
((status == 1)) || fail "a boot stuck at the logo did not time out (status $status): $(tail -n3 "$work/out")"
grep -q "Timed out after ${INSTALL_TIMEOUT}s" "$work/out" || fail "no timeout message: $(tail -n3 "$work/out")"
((slept <= INSTALL_TIMEOUT + 10)) || fail "a ${INSTALL_TIMEOUT}s budget took ${slept}s"
echo "ok - typing the passphrase blind counts against the install timeout"

# The same for a passphrase prompt OCR can read, typed into again and again
# (a passphrase the guest keeps refusing).
ocr_screen() { echo "A password is required to access the root volume:"; }

echo 0 >"$work/slept"
: >"$work/pressed"
run wait_for_unattended_install install
slept=$(<"$work/slept")
grep -qx ret "$work/pressed" || fail "the passphrase was never typed at the prompt"
((status == 1)) || fail "a refused passphrase did not time out (status $status): $(tail -n3 "$work/out")"
((slept <= INSTALL_TIMEOUT + 10)) || fail "a ${INSTALL_TIMEOUT}s budget took ${slept}s at the passphrase prompt"
echo "ok - typing at the passphrase prompt counts against the install timeout"

# -------------------------------------------- typing under the guest's layout
#
# type_text sends key positions, which the guest reads through the layout
# being typed into: KB_LAYOUT on the installed system, us on the live ISO. A
# layout whose keys type_text does not know is refused before a VM starts,
# and on uk the two characters that move are typed on their uk keys.

take kb_layout_typeable
for layout in us uk; do
  run kb_layout_typeable "$layout"
  ((status == 0)) || fail "the $layout layout was refused: $(cat "$work/out")"
done
run kb_layout_typeable de
((status != 0)) || fail "the de layout was accepted, where the passphrase omarchy types as omarchz"
grep -q "OMARCHY_INTEGRATION_KB_LAYOUT=de" "$work/out" || fail "the refusal does not name the setting: $(cat "$work/out")"
echo "ok - a layout the harness cannot type is refused"

# What type_text pressed for each text, under each layout.
typed() {
  : >"$work/pressed"
  run type_text "$1"
  if ((status == 0)); then paste -sd' ' "$work/pressed"; else echo "a refusal: $(cat "$work/out")"; fi
}
take type_text
KB_LAYOUT=uk TYPE_LAYOUT=uk
[[ $(typed omarchy) == "o m a r c h y" ]] || fail "the passphrase was typed under uk as $(typed omarchy)"
[[ $(typed "test@omarchy.org") == "t e s t shift-apostrophe o m a r c h y dot o r g" ]] ||
  fail "the email was typed under uk as $(typed "test@omarchy.org")"
[[ $(typed "cd ~") == "c d spc shift-backslash" ]] || fail "~ was typed under uk as $(typed "cd ~")"
TYPE_LAYOUT=us
[[ $(typed "test@omarchy.org") == "t e s t shift-2 o m a r c h y dot o r g" ]] ||
  fail "the email was typed under us as $(typed "test@omarchy.org")"
[[ $(typed "cd ~") == "c d spc shift-grave_accent" ]] || fail "~ was typed under us as $(typed "cd ~")"
echo "ok - type_text types @ and ~ on the keys of the layout being typed into"

# The live ISO is us whatever the install was given.
take bootstrap_live_root_ssh grub_menus_waiting
FIRMWARE=uefi KB_LAYOUT=uk TYPE_LAYOUT=uk
ocr_screen() { echo "archiso login:"; }
ssh_live_root() { true; }
type_text() { echo "$TYPE_LAYOUT $1" >>"$work/typed"; }
: >"$work/typed"
run bootstrap_live_root_ssh
((status == 0)) || fail "the live root login failed: $(cat "$work/out")"
if [[ ! -s $work/typed ]] || grep -qv '^us ' "$work/typed"; then
  fail "the live ISO was typed into as: $(cat "$work/typed")"
fi
echo "ok - the live ISO is typed into as us under a uk install"

# The live boot can take the VT back for tty1's installer after the login
# prompt has shown: the bootstrap command is typed only at a root prompt, on
# the VT just selected again, and an attempt that loses its console moves to
# the next VT instead of typing into the wizard.
type_text() { echo "$(grep ctrl-alt-f "$work/pressed" | tail -n1) $1" >>"$work/typed"; }
# tty3's root prompt never shows; tty4's does.
wait_for_screen() { [[ $(grep ctrl-alt-f "$work/pressed" | tail -n1) != ctrl-alt-f3 ]]; }
ssh_live_root() { grep -q curl "$work/typed"; }
: >"$work/pressed"
: >"$work/typed"
run bootstrap_live_root_ssh
((status == 0)) || fail "a lost root prompt on tty3 ended the scenario: $(cat "$work/out")"
grep -q '^ctrl-alt-f3 curl' "$work/typed" && fail "the bootstrap command was typed where no root prompt showed"
grep -q '^ctrl-alt-f4 curl' "$work/typed" || fail "the second attempt did not type on tty4: $(cat "$work/typed")"
echo "ok - the live root bootstrap types only at a root prompt, retrying on the next VT"

# The root prompt is matched in what OCR makes of it: the red "root@" comes
# out as noise, so the pattern rests on the rest, and the login banner alone
# ("archiso login: root") must not pass for a shell.
take bootstrap_live_root_ssh grub_menus_waiting
ocr_screen() { echo "archiso login:"; }
wait_for_screen() { grep -qi "$1" <<<"$screen"; }
ssh_live_root() { grep -q curl "$work/typed"; }
type_text() { echo "$(grep ctrl-alt-f "$work/pressed" | tail -n1) $1" >>"$work/typed"; }
screen=$'Omarchy 7.2.8-9-omarchy (tty3)\narchiso login: root\n11 iGarchiso \u00a5 #'
: >"$work/pressed"; : >"$work/typed"
run bootstrap_live_root_ssh
((status == 0)) || fail "the root prompt as OCR reads it was not taken for a shell: $(cat "$work/out")"
grep -q '^ctrl-alt-f3 curl' "$work/typed" || fail "the bootstrap command was not typed at the root prompt: $(cat "$work/typed")"
screen=$'Omarchy 7.2.8-9-omarchy (tty3)\narchiso login: root'
: >"$work/pressed"; : >"$work/typed"
run bootstrap_live_root_ssh
grep -q curl "$work/typed" && fail "the bootstrap command was typed at a login banner: $(cat "$work/typed")"
echo "ok - the root prompt is recognised as OCR reads it, and a login banner is not"

# SSH that never comes up fails after tty3, tty4 and tty5, within a bounded wait.
wait_for_screen() { true; }
ssh_live_root() { false; }
echo 0 >"$work/slept"
: >"$work/pressed"
: >"$work/typed"
run bootstrap_live_root_ssh
slept=$(<"$work/slept")
((status == 1)) || fail "a live root SSH that never came up did not fail (status $status)"
[[ $(grep -c curl "$work/typed") == 3 ]] || fail "expected three bootstrap attempts: $(cat "$work/typed")"
grep -q '^ctrl-alt-f5 curl' "$work/typed" || fail "the last attempt did not use tty5: $(cat "$work/typed")"
((slept <= 300)) || fail "three failed live root logins took ${slept}s"
echo "ok - live root SSH that never comes up fails after three VTs"

# A press that lands while GRUB shows its menu stops the countdown: on a
# luks-calibration run the VM sat at the menu until the 300 s ran out. The
# menu stays until something boots its entry.
ocr_screen() {
  if grep -qx ret "$work/pressed"; then
    echo "archiso login:"
  else
    printf '%s\n' "GNU GRUB version 2:2. 18-1" "Try Qmarchy (xe 64, xf4 UEFTI"
  fi
}
wait_for_screen() { true; }
ssh_live_root() { true; }
echo 0 >"$work/slept"
: >"$work/pressed"
: >"$work/typed"
run bootstrap_live_root_ssh
((status == 0)) || fail "a stopped GRUB countdown ended the scenario: $(cat "$work/out")"
[[ $(sed -n 2p "$work/pressed") == ret ]] || fail "the menu was not booted at the first sight of it: $(paste -sd' ' "$work/pressed")"
echo "ok - the live root bootstrap boots GRUB's entry when its countdown stopped"

# OCR is no signal for that menu: on a live-misc run it read the header as
# "GHU GRUE", and the VM sat at the menu for the 300 s. GRUB draws the menu
# on the serial console too, and says there when it boots an entry.
SERIAL_LOG="$work/serial.log"
grub_serial() {
  printf '%s\r\n' 'BdsDxe: starting Boot0002 "UEFI QEMU DVD-ROM QM00011 " from PciRoot(0x0)/Pci(0x1F,0x2)/Sata(0x5,0xFFFF,0x0)' \
    'GNU GRUB  version 2:2.16-1' '*Install Omarchy (x86_64, x64 UEFI)' ' Try Omarchy (x86_64, x64 UEFI)' \
    '   The highlighted entry will be executed automatically in 3s.' '   The highlighted entry will be executed automatically in 2s.' \
    '   The highlighted entry will be executed automatically in 1s.' "$@" >"$SERIAL_LOG"
}
grub_serial
# The menu, as OCR misread it, until Return boots its entry; then the boot,
# which takes a while and leaves the serial console as it was, then the
# login prompt.
count="$work/ocr-count"
ocr_screen() {
  if ! grep -qx ret "$work/pressed"; then
    printf '%s\n' "GHU GRUE wersion 2:2016-1" "Try Omarchy (286 64, =64 UEFL"
    return
  fi
  local n=$(($(cat "$count" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$count"
  if ((n > 3)); then
    [[ -f $work/login-shown ]] || { touch "$work/login-shown"; echo "(login prompt)" >>"$work/pressed"; }
    echo "archiso login:"
  else
    echo "OMARCHY"
  fi
}
rm -f "$count" "$work/login-shown"
echo 0 >"$work/slept"
: >"$work/pressed"
: >"$work/typed"
run bootstrap_live_root_ssh
((status == 0)) || fail "a stopped GRUB countdown OCR misread ended the scenario: $(cat "$work/out")"
[[ $(sed -n 2p "$work/pressed") == ret ]] || fail "the menu on the serial console was not booted: $(paste -sd' ' "$work/pressed")"
[[ $(sed '/^(login prompt)$/q' "$work/pressed" | grep -cx ret) == 1 ]] ||
  fail "Return was pressed again while the entry booted: $(paste -sd' ' "$work/pressed")"
echo "ok - the live root bootstrap boots GRUB's entry by what the serial console shows, once"

# Once GRUB has booted its entry, or never drew a menu there (a hidden one),
# Return would go to the live system instead: none is pressed, whatever OCR
# makes of the boot.
ocr_screen() {
  local n=$(($(cat "$count" 2>/dev/null || echo 0) + 1))
  echo "$n" >"$count"
  if ((n > 3)); then
    [[ -f $work/login-shown ]] || { touch "$work/login-shown"; echo "(login prompt)" >>"$work/pressed"; }
    echo "archiso login:"
  else
    echo "OMARCHY"
  fi
}
for case in booted hidden; do
  if [[ $case == booted ]]; then
    grub_serial "Booting \`Install Omarchy (x86_64, x64 UEFI)'"
  else
    printf '%s\r\n' 'BdsDxe: starting Boot0002 "UEFI QEMU DVD-ROM QM00011 "' >"$SERIAL_LOG"
  fi
  rm -f "$count" "$work/login-shown"
  echo 0 >"$work/slept"
  : >"$work/pressed"
  : >"$work/typed"
  run bootstrap_live_root_ssh
  ((status == 0)) || fail "the live root login failed after a $case menu: $(cat "$work/out")"
  sed '/^(login prompt)$/q' "$work/pressed" | grep -qx ret &&
    fail "Return was pressed before the login prompt after a $case menu: $(paste -sd' ' "$work/pressed")"
done
echo "ok - no Return is pressed once GRUB has booted, or when its menu is hidden"
unset SERIAL_LOG

# pxe's NBD wait keeps to its 900 s when a load has failed and the return to
# the menu takes the menu wait's whole time. (The first wait for the menu,
# before the NBD wait starts, has its own 300 s.)
take_from "$ROOT/test/integration.d/pxe-test.sh" netboot_into_installer
SSH_KEY="$work/id_ed25519" RUN_DIR="$work/pxe-run" TFTP_ROOT="$work/tftp" CIDATA_IMG="$work/cidata.img"
mkdir -p "$RUN_DIR"
detect_packages() { :; }
build_cidata() { :; }
start_vm() { :; }
qemu-img() { :; }
nbd_dialed() { false; }
wait_for_live_root_ssh() { :; }
bootstrap_live_root_ssh() { :; }
LIVE_CIDATA_SMBIOS=()
# The wait at the menu takes all the time it is given, and the load fails
# 600 s into the NBD wait: a retry that started its own 900 s would take
# 300 + 600 + 900 s.
wait_for_screen() { sleep "$2"; }
: >"$RUN_DIR/serial.log"
nbd_dialed() {
  (($(<"$work/slept") >= 300 + 600)) && ! grep -q 'Boot failed' "$RUN_DIR/serial.log" &&
    echo "Boot failed: press a key to retry" >>"$RUN_DIR/serial.log"
  return 1
}
echo 0 >"$work/slept"
run netboot_into_installer
slept=$(<"$work/slept")
((status == 1)) || fail "a PXE boot that never dials NBD did not fail (status $status)"
grep -q "Timed out waiting for the guest to dial the NBD export" "$work/out" ||
  fail "the NBD wait was never reached: $(tail -n3 "$work/out")"
((slept <= 300 + 900 + 10)) || fail "pxe's 900 s NBD wait took ${slept}s after a failed load"
echo "ok - pxe's NBD wait keeps to 900 s after a failed load"

# The factory first boot's keyboard step takes English (US) and loads it,
# so what the form asks for next is typed as us: on uk keys, a password
# with an @ arrives with a " in its place.
take_from "$ROOT/test/integration.d/factory-reset-test.sh" drive_first_boot
take type_text
KB_LAYOUT=uk TYPE_LAYOUT=uk GUEST_HOSTNAME=omarchy-test
wait_for_screen() { true; }
printf '%s\n' "Select keyboard layout" "Username" "Password" "Confirm password" \
  "Hostname" "Timezone" "Does this look right?" >"$work/screens"
ocr_screen() { # each form screen once, in order
  head -n1 "$work/screens"
  sed -i 1d "$work/screens"
}
: >"$work/pressed"
GUEST_PASSWORD=pass@word run drive_first_boot
((status == 0)) || fail "the first-boot form stopped under uk: $(tail -n3 "$work/out")"
grep -qx shift-2 "$work/pressed" || fail "the password's @ was not typed as us after the keyboard step: $(paste -sd' ' "$work/pressed")"
! grep -qx shift-apostrophe "$work/pressed" || fail "the password's @ was typed on its uk key after the form loaded us"
echo "ok - the factory first boot is typed into as us after its keyboard step"

# ------------------------------------------- the boot wait unlocks the disk
#
# Every boot of an encrypted install stops at the LUKS prompt, scenario
# overlays included. An initramfs built on the machine (BIOS, or a layout
# the pre-built UKI lacks) asks with Plymouth's lock field, which OCR reads
# as the logo and nothing else; wait_for_ssh types into it as the install
# wait does, and not into a booted console.

take wait_for_ssh answer_luks_prompt type_text
ENCRYPT=true KB_LAYOUT=uk TYPE_LAYOUT=uk
ssh_guest() { [[ $(paste -sd' ' "$work/pressed") == *"o m a r c h y ret"* ]]; }
for screen in "OMARCHY" "A password is required to access the root volume:"; do
  ocr_screen() { echo "$screen"; }
  : >"$work/pressed"
  run wait_for_ssh 300
  ((status == 0)) || fail "a boot at the prompt reading \"$screen\" was not unlocked: $(tail -n3 "$work/out")"
done
echo "ok - wait_for_ssh types the passphrase at a logo-only prompt and a readable one"

ocr_screen() { echo "omarchy-test login:"; }
: >"$work/pressed"
run wait_for_ssh 60
((status == 1)) || fail "a booted console without SSH did not time out (status $status): $(tail -n3 "$work/out")"
[[ ! -s $work/pressed ]] || fail "wait_for_ssh typed into a booted console: $(paste -sd' ' "$work/pressed")"
echo "ok - wait_for_ssh types nothing into a booted console"

# ------------------------------------------ --reuse-base and the settings
#
# --reuse-base boots the base image a saved install left in BASE_DIR, so
# every setting that changes what was installed must give it its own folder:
# the firmware, the variant, the keyboard, encryption, the UKI and the disk
# size. The default settings keep the folder they always had, so the bases
# already saved are still found.

# The naming is the top-level block from BASE_DIR= to RUN_DIR=.
naming=$(sed -n '/^BASE_DIR="/,/^RUN_DIR=/p' "$harness")
[[ -n $naming ]] || fail "the harness no longer names its base folder with BASE_DIR"
base_dir() { # [VAR=value]...
  local ROOT=/r ISO=/i/omarchy-9.9.9.iso FIRMWARE=uefi VARIANT=default KB_LAYOUT=us \
    ENCRYPT=false UKI=false DISK_GB=40 SCENARIO=boot setting BASE_DIR RUN_DIR
  for setting; do eval "local $setting"; done
  eval "$naming"
  echo "$BASE_DIR"
}

[[ $(base_dir) == /r/test-runs/omarchy-9.9.9-integration ]] ||
  fail "the default install's base folder moved to $(base_dir), so the saved ones are not reused"
declare -A seen=([$(base_dir)]="the default settings")
for setting in FIRMWARE=bios VARIANT=small KB_LAYOUT=uk ENCRYPT=true UKI=true DISK_GB=24; do
  dir=$(base_dir "$setting")
  [[ ! -v seen[$dir] ]] || fail "$setting reuses the base of ${seen[$dir]} ($dir)"
  seen[$dir]=$setting
  [[ $(base_dir "$setting") == "$dir" ]] || fail "$setting does not find its own base again"
done
echo "ok - each install setting saves and reuses its own base"

# ------------------------------------------- live root SSH from the cidata drive
#
# The live ISO's cloud-init reads the cidata drive as NoCloud. Its user-data
# authorizes the harness key for root, which the image's cloud.cfg would wrap
# in a "log in as the default user" command (disable_root: true), and creates
# no default user.

take cidata_cloud_init
SSH_KEY="$work/id_ed25519"
mkdir -p "$work/cidata"
run cidata_cloud_init "$work/cidata"
((status == 0)) || fail "cidata_cloud_init failed: $(cat "$work/out")"
grep -qx 'instance-id: .*' "$work/cidata/meta-data" || fail "no NoCloud meta-data on the cidata drive"
user_data=$(cat "$work/cidata/user-data")
[[ $(head -n1 <<<"$user_data") == "#cloud-config" ]] || fail "user-data is not cloud-config: $user_data"
grep -qx 'disable_root: false' <<<"$user_data" || fail "root's key would be disabled: $user_data"
grep -qx 'users: \[\]' <<<"$user_data" || fail "cloud-init would create its default user: $user_data"
grep -qxF "  - $(cat "$SSH_KEY.pub")" <<<"$user_data" || fail "the harness key is not authorized: $user_data"
grep -q 'cidata_cloud_init "\$dir"' "$harness" || fail "build_cidata does not put the cloud-init files on the drive"
echo "ok - the cidata drive authorizes the harness key for the live ISO's root"

# Both live-SSH waits keep to their budget by the clock, when each refused
# attempt itself takes ConnectTimeout (5 s).
take wait_for_live_root_ssh
ssh_live_root() { sleep 5; false; }
echo 0 >"$work/slept"
run wait_for_live_root_ssh 120
slept=$(<"$work/slept")
((status == 1)) || fail "live root SSH that never came up did not time out (status $status)"
((slept <= 120 + 10)) || fail "a 120 s live-SSH wait took ${slept}s"
take bootstrap_live_root_ssh grub_menus_waiting
wait_for_screen() { true; }
echo 0 >"$work/slept"
: >"$work/typed"
run bootstrap_live_root_ssh
slept=$(<"$work/slept")
((status == 1)) || fail "the live root bootstrap did not fail (status $status)"
((slept <= 3 * (60 + 10) + 3 * 40)) || fail "three 60 s bootstrap attempts took ${slept}s"
echo "ok - the live-SSH waits keep to their budget when each attempt takes 5 s"

# ------------------------------------------ the first boot's update units
#
# The installer marks updates as applied after its last pacman transaction,
# so an install from this tree must skip the ConditionNeedsUpdate= units on
# its first boot. A released ISO from before that change runs them; it is
# installed only to start an upgrade from, so that is noted, not failed.

take check_first_boot_update_units
units="$work/first-boot-update-units.txt"
printf 'Id=ldconfig.service\nConditionResult=no\n\nId=systemd-sysusers.service\nConditionResult=no\n' >"$units"
RELEASE_ISO=false
run check_first_boot_update_units "$units"
((status == 0)) || fail "a first boot that skipped the update units failed: $(cat "$work/out")"

printf 'Id=ldconfig.service\nConditionResult=yes\n\nId=systemd-sysusers.service\nConditionResult=no\n' >"$units"
run check_first_boot_update_units "$units"
((status == 1)) || fail "an install from this tree that ran the update units passed (status $status)"
grep -q "First boot ran the ConditionNeedsUpdate= units" "$work/out" || fail "no message: $(cat "$work/out")"

RELEASE_ISO=true
run check_first_boot_update_units "$units"
((status == 0)) || fail "a release ISO that ran the update units failed the install: $(cat "$work/out")"
grep -q "First boot ran the ConditionNeedsUpdate= units" "$work/out" || fail "the release's first boot was not noted: $(cat "$work/out")"
echo "ok - only an install from this tree fails for running the first boot's update units"
