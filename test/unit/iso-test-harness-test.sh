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
FREE_SPACE=false PROVISION=false ENCRYPT=false NO_NETWORK=true CHILD=false
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
  ENCRYPT=false PROVISION=false FREE_SPACE=false CHILD=false
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

# The free-space fixture has existing partitions. Drive the real wizard
# function against the product's actual ordering, refusing an erase choice.
(
  take drive_configurator
  source "$ROOT/configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"
  mapfile -t modes < <(install_mode_choices true 2)
  FREE_SPACE=true PROVISION=false ENCRYPT=true CHILD=false
  KEYBOARD_LABEL="English (US)" GUEST_USER=omarchy GUEST_PASSWORD=omarchy
  picking=false selected=0 choice=""
  type_text() { :; }
  capture_console() { :; }
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
