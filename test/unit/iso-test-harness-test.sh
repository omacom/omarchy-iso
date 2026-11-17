#!/bin/bash
#
# bin/omarchy-iso-test without a VM: its functions are taken out of the
# script and run against stubs for QEMU, QMP and OCR, so what the harness
# decides from what it sees can be checked here.

# shellcheck disable=SC2034 # the variables are read by the functions taken out of the harness

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
harness="$ROOT/bin/omarchy-iso-test"
bash -n "$harness"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# The harness is a script that starts a VM when it is run; take only the
# functions under test.
take() {
  local name
  for name; do
    eval "$(sed -n "/^$name() {\$/,/^}\$/p" "$harness")"
    declare -F "$name" >/dev/null || fail "the harness no longer has $name"
  done
}

# ------------------------------------------------- --no-network first boot
#
# With no NIC there is no SSH to wait for, so an offline install passes on
# what the screen shows. It must not pass on the Reboot Now press alone: the
# installed system has to come up to its own console login.

take install_phase wait_for_first_boot_login
GUEST_HOSTNAME="omarchy-test"
SSH_KEY="$work/id_ed25519"
BASE_DISK="$work/base.qcow2"
BASE_OVMF="$work/OVMF_VARS.fd"
OVMF_VARS_TEMPLATE="$work/OVMF_VARS.template"
RUN_DIR="$work"
ISO="$work/omarchy.iso"
BOOT_TIMEOUT=60
FREE_SPACE=false PROVISION=false ENCRYPT=false NO_NETWORK=true
OEM=false
touch "$SSH_KEY" "$OVMF_VARS_TEMPLATE"

log() { :; }
qemu-img() { :; }
start_vm() { :; }
drive_configurator() { :; }
wait_for_install() { :; } # pressed Reboot Now and returned, as it does
bootstrap_ssh() { fail "bootstrap_ssh needs a network"; }
vm_running() { true; }
press() { :; }
sleep() { :; }
captured=()
capture_console() { captured+=("$1"); }
# The scripted screens in order, the last one forever. OCR runs in a
# pipeline's subshell, so where it is in the script is kept in a file.
screens() { printf '%s\n' "$@" >"$work/screens"; echo 1 >"$work/screen"; }
ocr_screen() {
  local n
  n=$(<"$work/screen")
  sed -n "${n}p" "$work/screens"
  (( n < $(wc -l <"$work/screens") )) && echo $((n + 1)) >"$work/screen"
  return 0
}

# The harness runs install_phase under set -e, outside any condition, so a
# failing step ends it there. Run it the same way: an `if` around it would
# switch set -e off inside and hide the failure.
offline_install() {
  set +e
  (set -e; install_phase; printf '%s\n' "${captured[@]}" >"$work/captured") 2>"$work/err"
  installed=$?
  set -e
}

screens "" "archiso login:"
offline_install
((installed != 0)) || fail "an offline install passed without the installed system reaching a login"

screens "Rebooting" "" "Arch Linux 6.17 (tty3)" "omarchy-test login:"
offline_install
((installed == 0)) || fail "an offline install that reached its login failed: $(cat "$work/err")"
grep -qx "success-first-boot-no-network" "$work/captured" ||
  fail "the offline install did not record its first boot"

echo "ok - an offline install passes only once the installed system reaches its login"

# ------------------------------------------------- --battery and --acpi-hid
#
# Both compile an SSDT with iasl, so the dependency setup has to bring it
# (Arch's acpica) when either is asked for, and a table that does not compile
# has to say why.

# The setup is the block of omarchy-pkg-add lines at the top level.
setup=$(sed -n '/^omarchy-pkg-add qemu-full/,/^$/p' "$harness")
[[ -n $setup ]] || fail "the harness no longer installs its dependencies with omarchy-pkg-add"
omarchy-pkg-add() { added+=("$@"); }
dependencies() { added=(); BATTERY=$1; shift; ACPI_HIDS=("$@"); eval "$setup"; }

dependencies true
[[ " ${added[*]} " == *" acpica "* ]] || fail "--battery does not install acpica: ${added[*]}"
dependencies false OVTI08F4
[[ " ${added[*]} " == *" acpica "* ]] || fail "--acpi-hid does not install acpica: ${added[*]}"
dependencies false
[[ " ${added[*]} " != *" acpica "* ]] || fail "acpica is installed with no fake ACPI device"

take start_vm
FAKE_PCI=() FAKE_PCI_PIDS=() SMBIOS=() CPU_ID="" ACPI_HIDS=() BATTERY=true
QMP_SOCK="$work/qmp.sock"
iasl() { echo "fake-acpi.dsl     3: Device (BAT0) { Name (_HID, EisaId (\"PNP0C0A\"))"; echo "Error    6126 -   syntax error ^" >&2; return 255; }
qemu-system-x86_64() { fail "QEMU started with an SSDT that did not compile"; }
set +e
(set -e; start_vm "$work/disk.qcow2" "$work/serial.log") 2>"$work/err"
started=$?
set -e
((started != 0)) || fail "start_vm went on after iasl failed"
grep -q "syntax error" "$work/err" || fail "the iasl error is hidden: $(cat "$work/err")"

echo "ok - fake ACPI devices bring iasl with them and show its errors"

# ------------------------------------------- --reuse-base and fake hardware
#
# The fake hardware changes what the install does (packages, kernel, boot
# configuration), so --reuse-base must not boot an image installed with other
# hardware, or none: each hardware setting gets its own base image, and the
# same setting finds its own again.

# The naming is the top-level block from BASE_NAME= to BASE_DIR=.
naming=$(sed -n '/^BASE_NAME="/,/^BASE_DIR=/p' "$harness")
[[ -n $naming ]] || fail "the harness no longer names its base image with BASE_NAME"
base_name() { # [VAR=value | VAR+=(value)]...
  ISO="$work/omarchy.iso" KEYBOARD_LABEL="English (US)" REPO_DIR="$work"
  ENCRYPT=false PROVISION=false FREE_SPACE=false
  FAKE_PCI=() SMBIOS=() CPU_ID="" BATTERY=false ACPI_HIDS=() NO_NETWORK=false
  local setting
  for setting; do eval "$setting"; done
  eval "$naming"
  echo "$BASE_NAME"
}

[[ $(base_name) == omarchy ]] || fail "the plain install's base image moved to $(base_name), so existing ones are not reused"
declare -A seen=([$(base_name)]="no fake hardware")
for setting in "FAKE_PCI+=(106b:1802:088000)" "FAKE_PCI+=(10de:2684:030000)" \
  "SMBIOS+=('manufacturer=Framework,,product=Laptop 16')" "CPU_ID=vendor=GenuineIntel,model=170" \
  "BATTERY=true" "ACPI_HIDS+=(OVTI08F4)" "NO_NETWORK=true"; do
  name=$(base_name "$setting")
  [[ ! -v seen[$name] ]] || fail "$setting reuses the base image of ${seen[$name]} ($name)"
  seen[$name]=$setting
  [[ $(base_name "$setting") == "$name" ]] || fail "$setting does not find its own base image again"
done

echo "ok - each fake hardware setting installs and reuses its own base image"

# ------------------------------------------- --keep-running and --fake-pci
#
# A fake PCI device lives in its own vfio-user server process, which the VM
# reads the device from. --keep-running leaves the VM up after the suite, so
# its devices must stay up with it; without it, the VM stops first and its
# servers after it.

take cleanup
HTTP_PID="" RUN_DIR="$work"
open_screenshots() { :; }
stop_vm() {
  local pid
  for pid in "${FAKE_PCI_PIDS[@]}"; do
    kill -0 "$pid" 2>/dev/null || echo "a fake device server stopped before its VM" >>"$work/order"
  done
  rm -f "$work/vm"
}
exit_with() { # KEEP_RUNNING: start two fake device servers and a VM, then exit as the harness does
  KEEP_RUNNING=$1 FAKE_PCI_PIDS=()
  command sleep 60 & FAKE_PCI_PIDS+=($!)
  command sleep 60 & FAKE_PCI_PIDS+=($!)
  touch "$work/vm"
  : >"$work/order"
  cleanup || true
}
alive() { local pid n=0; for pid in "${FAKE_PCI_PIDS[@]}"; do ! kill -0 "$pid" 2>/dev/null || n=$((n + 1)); done; echo "$n"; }

exit_with true
kept=$(alive)
kill "${FAKE_PCI_PIDS[@]}" 2>/dev/null || true
[[ -f $work/vm ]] || fail "--keep-running stopped the VM"
((kept == 2)) || fail "--keep-running left the VM up but stopped $((2 - kept)) of its 2 fake device servers"

exit_with false
for pid in "${FAKE_PCI_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
[[ ! -f $work/vm ]] || fail "the VM was left running without --keep-running"
[[ ! -s $work/order ]] || fail "$(head -1 "$work/order")"
(($(alive) == 0)) || fail "the fake device servers were left running after the VM stopped"

echo "ok - fake PCI devices stay up as long as their VM, and stop after it"

# ------------------------------------------------------------------- --oem
#
# An OEM ISO installs without a question, so the harness must not answer one:
# a key sent here could land in the first-boot setup that follows.

(
  take drive_configurator
  OEM=true
  press() { fail "the harness pressed $1 during an OEM install"; }
  type_text() { fail "the harness typed during an OEM install"; }
  wait_for_screen() { fail "the harness waited for an installer screen during an OEM install"; }
  drive_configurator
)

# An OEM install is always full-disk, so asking for the free-space fixture
# with it is refused before a disk is made or a package installed.
touch "$work/omarchy-oem.iso"
mkdir -p "$work/refuse"
printf '#!/bin/bash\necho reached >"%s/refuse/setup"\nexit 1\n' "$work" >"$work/refuse/omarchy-pkg-add"
chmod +x "$work/refuse/omarchy-pkg-add"
! PATH="$work/refuse:$PATH" bash "$harness" "$work/omarchy-oem.iso" --oem --free-space 2>"$work/err" ||
  fail "--oem --free-space was accepted"
grep -q -- "--oem installs over the whole disk" "$work/err" || fail "--oem --free-space was refused without saying why: $(cat "$work/err")"
[[ ! -e $work/refuse/setup ]] || fail "--oem --free-space got as far as installing dependencies"

echo "ok - an OEM install is sent no keys, and is not asked for a free-space install"

# ------------------------------------------------------- first-boot setup
#
# First-boot setup asks the account questions in the installer's order on a
# runtime that has the language step and in its older order on one that does
# not. The driver answers whichever prompt is on screen, each once.

(
  take drive_provision_owner drive_oem_agreement wait_for_screen wait_for_screen_any
  KEYBOARD_LABEL="English (US)" GUEST_USER=owner GUEST_PASSWORD=secret GUEST_HOSTNAME=box
  GREETER_TEXT="Linux by DHH" GREETER_OCR_THRESHOLD=50 OEM_EULA=false
  press() {
    [[ $(sed -n "$(($(<"$work/screen") - 1))p" "$work/screens") != "Let's set your timezone..." ]] ||
      fail "the harness answered the timezone heading, before the picker was up"
    echo "press $1" >>"$work/actions"
  }
  type_text() { echo "type $1" >>"$work/actions"; }
  capture_console() { [[ $1 != *finalizing-* ]] || echo "$1" >>"$work/captured-progress"; }
  # As offline_install above: an `||` around the driver would switch set -e
  # off inside it and hide a step that failed.
  drive() {
    : >"$work/actions" >"$work/captured-progress"
    screens "$@"
    set +e
    (set -e; drive_provision_owner) 2>"$work/err"
    driven=$?
    set -e
  }
  driven_ok() { ((driven == 0)) || fail "first-boot setup was not driven: $(cat "$work/err")"; }

  zones="Timezone > Filter... America/Chicago Africa/Abidjan" # one line: a scripted screen is a line
  drive "Linux by DHH" "Language" "Select keyboard layout" "$zones" "Username>" "Username>" "Password>" \
    "Confirm>" "Hostname>" "Does this look right?" "477" "" "" "48>" "desktop" "" "login:" "never read"
  driven_ok
  # OCR reads the percent sign as anything, and from a screen caught mid-redraw
  # nothing at all: the progress screen lasts until two readable screens in a
  # row are not it.
  [[ -s $work/captured-progress && $(<"$work/screen") == 18 ]] || fail "the setup progress screen was not followed to its end"
  expected="press ret,press ret,press down,press ret,press ret,type owner,press ret,type secret,press ret,type secret,press ret,type box,press ret,press ret,"
  [[ $(tr '\n' ',' <"$work/actions") == "$expected" ]] ||
    fail "the installer's order was answered as: $(tr '\n' ' ' <"$work/actions")"

  # The older runtime names the step in a heading while it fetches its guess;
  # a Return then is lost, so only the picker itself is answered.
  drive "Linux by DHH" "Select keyboard layout" "Username>" "Password>" "Confirm>" "Hostname>" \
    "Let's set your timezone..." "$zones" "Does this look right?" "desktop" "desktop"
  driven_ok
  expected="press ret,press down,press ret,type owner,press ret,type secret,press ret,type secret,press ret,type box,press ret,press ret,press ret,"
  [[ $(tr '\n' ',' <"$work/actions") == "$expected" ]] ||
    fail "the older order was answered as: $(tr '\n' ' ' <"$work/actions")"

  # An OEM's greeter carries its own tagline, so it is known by its hint, and
  # its agreement is the form's last question: the driver reads on, comes back
  # from Ctrl+C's reboot offer and from declining, and only then accepts.
  GREETER_TEXT="Start Setup" OEM_EULA=true
  agreement="Do you accept this agreement?"
  drive "Acme Book 14, pouwered by Omarchy Press Return to Start Setup" "Language" "Select keyboard layout" "$zones" "Username>" "Password>" \
    "Confirm>" "Hostname>" "Does this look right?" "$agreement" "Reboot this machine?" "$agreement" \
    "Shut doun this machine? Yes, shut doun No, back to the agreement" "$agreement" "50%" "desktop" "desktop"
  driven_ok
  expected="press ret,press ret,press down,press ret,press ret,type owner,press ret,type secret,press ret,type secret,press ret,type box,press ret,press ret,"
  expected+="press pgdn,press ctrl-c,press right,press ret,press tab,press ret,press ret,press end,press ret,"
  [[ $(tr '\n' ',' <"$work/actions") == "$expected" ]] ||
    fail "the OEM's agreement was answered as: $(tr '\n' ' ' <"$work/actions")"

  # An ISO whose agreement never comes up was not built with the config named.
  drive "Press Return to Start Setup" "Select keyboard layout" "Does this look right?" "50%"
  ((driven != 0)) && grep -q "waiting for screen: accept this agreement" "$work/err" ||
    fail "a first boot without the expected agreement passed: $(cat "$work/err")"
  GREETER_TEXT="Linux by DHH" OEM_EULA=false

  # A form that stops on a screen the driver cannot answer fails the run.
  drive "Linux by DHH" "Select keyboard layout" "Passwords didn't match!"
  ((driven != 0)) || fail "a first-boot form that stalled passed"

  # Setup that never leaves its progress screen, or leaves the screen black,
  # fails the run instead of waiting forever or passing unseen.
  for stuck in "50%" ""; do
    drive "Linux by DHH" "Select keyboard layout" "Does this look right?" "$stuck"
    ((driven != 0)) && grep -q "Timed out waiting for first-boot setup to finish" "$work/err" ||
      fail "first-boot setup stuck on '${stuck:-a blank screen}' did not time out: $(cat "$work/err")"
  done
)

echo "ok - first-boot setup is answered in whichever order it asks"

# ------------------------------------------------------------ --oem-config
#
# The installed machine is held to the bundle the config lays out, and the
# record of acceptance to this OEM, this agreement's text and this owner: a
# machine that asked for other terms, or recorded them, does not pass.

(
  take verify_oem_setup
  GUEST_USER=owner OEM_EULA=true RUN_DIR="$work/oem-run" OEM_BUNDLE="$work/oem-run/oem-bundle"
  guest="$work/oem-guest"
  mkdir -p "$RUN_DIR" "$guest/etc/omarchy" "$guest/var/lib/omarchy/oem"
  python3 "$ROOT/builder/oem-bundle.py" "$OEM_BUNDLE" "--config=$ROOT/test/unit/fixtures/oem/oem.json"
  log() { :; }
  # The guest's files are the ones under $guest.
  ssh_guest() {
    local command=${1//\/etc\/omarchy/$guest/etc/omarchy}
    bash -c "${command//\/var\/lib\/omarchy/$guest/var/lib/omarchy}"
  }
  accepted() {
    printf '{"oem": "%s", "sha256": "%s", "accepted_by": "%s"}\n' "$@" >"$guest/var/lib/omarchy/oem/eula-accepted.json"
  }
  verified() { (set -e; verify_oem_setup) 2>"$work/err"; }
  terms=$(sha256sum <"$OEM_BUNDLE/eula.txt" | cut -d' ' -f1)

  cp -r "$OEM_BUNDLE" "$guest/etc/omarchy/oem"
  accepted "Acme Computers" "$terms" owner
  verified || fail "a machine carrying the bundle and its accepted agreement was refused: $(cat "$work/err")"

  accepted "Acme Computers" "$(printf other | sha256sum | cut -d' ' -f1)" owner
  ! verified || fail "a record of other terms passed"
  accepted "Another OEM" "$terms" owner
  ! verified || fail "a record naming another OEM passed"
  accepted "Acme Computers" "$terms" someone-else
  ! verified || fail "a record of another account passed"
  rm "$guest/var/lib/omarchy/oem/eula-accepted.json"
  ! verified || fail "a machine with no record of acceptance passed"

  accepted "Acme Computers" "$terms" owner
  echo "older terms" >"$guest/etc/omarchy/oem/eula.txt"
  ! verified || fail "a machine carrying another agreement passed"
)

echo "ok - an OEM install is held to its config's bundle and to a record of its own agreement"

# The free-space fixture has existing partitions. Drive the real wizard
# function against the product's actual ordering, refusing an erase choice.
(
  take drive_configurator
  source "$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"
  mapfile -t modes < <(install_mode_choices true 2)
  FREE_SPACE=true PROVISION=false ENCRYPT=true
  KEYBOARD_LABEL="English (US)" GUEST_USER=omarchy GUEST_PASSWORD=omarchy
  picking=false selected=0 choice=""
  type_text() { :; }
  capture_console() { :; }
  wait_for_screen_any() { SCREEN_MATCHED="Language"; }
  wait_for_screen() {
    case $1 in
      "installation mode") picking=true ;;
      "of free space")
        [[ $choice == free_space ]] || fail "free-space harness selected $choice"
        ;;
    esac
  }
  press() {
    $picking || return 0
    case $1 in
      home) selected=0 ;;
      down) selected=$((selected+1)) ;;
      ret) choice=${modes[$selected]}; picking=false ;;
    esac
  }
  drive_configurator
)
echo "ok - the free-space wizard harness preserves the fixture's existing partitions"
