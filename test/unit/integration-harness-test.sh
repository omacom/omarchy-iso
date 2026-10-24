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
take bootstrap_live_root_ssh
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

# The factory first boot's keyboard step takes English (US) and loads it,
# so what the form asks for next is typed as us: on uk keys, the email
# arrives as test"omarchy.org.
take_from "$ROOT/test/integration.d/factory-reset-test.sh" drive_first_boot
take type_text
KB_LAYOUT=uk TYPE_LAYOUT=uk GUEST_HOSTNAME=omarchy-test
wait_for_screen() { true; }
printf '%s\n' "Select keyboard layout" "Username" "Password" "Confirm password" "Full name" \
  "Email address" "Hostname" "Timezone" "Does this look right?" >"$work/screens"
ocr_screen() { # each form screen once, in order
  head -n1 "$work/screens"
  sed -i 1d "$work/screens"
}
: >"$work/pressed"
run drive_first_boot
((status == 0)) || fail "the first-boot form stopped under uk: $(tail -n3 "$work/out")"
grep -qx shift-2 "$work/pressed" || fail "the email's @ was not typed as us after the keyboard step: $(paste -sd' ' "$work/pressed")"
! grep -qx shift-apostrophe "$work/pressed" || fail "the email's @ was typed on its uk key after the form loaded us"
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
