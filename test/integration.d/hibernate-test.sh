#!/bin/bash
#
# Suspend-to-disk and resume on the installed system. `systemctl hibernate`
# makes the guest kernel write its memory image into the swapfile (on the
# encrypted btrfs for the encrypted variant) and power the machine off
# through ACPI S4; the next boot has to unlock the root, find the image
# through the resume offset and restore it. The proof of a real resume is a
# marker in tmpfs: it cannot survive anything but a restored memory image.
#
# A fresh install does not set hibernation up, so the test does what an owner
# would: `omarchy-hibernation-setup`, then a boot of the rebuilt UKI so the
# resume parameters are on the cmdline. Every boot after the first reuses the
# run's own disk instead of a fresh overlay of the base image.
#
# Runs against the base image: `./test/integration <iso> hibernate`.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

vm_powered_off() { ! vm_running; }

wait_for_power_off() {
  local waited=0
  while vm_running && ((waited < 180)); do
    sleep 1
    ((waited += 1))
  done
  WAITED=$waited
}

set_up_hibernation() {
  log "Booting the installed base image to set hibernation up"
  start_vm_from_base
  wait_for_ssh "$BOOT_TIMEOUT"

  check "installed system is reachable" ssh_guest "test ! -e /run/archiso"
  # A released ISO from before this change still sets hibernation up.
  if [[ $RELEASE_ISO != true ]]; then
    check "a fresh install has no hibernation swapfile" \
      ssh_sudo "! grep -q /swap/swapfile /etc/fstab"
  fi
  local setup_status=0
  ssh_sudo "OMARCHY_PATH=/usr/share/omarchy omarchy-hibernation-setup --force" \
    >"$RUN_DIR/hibernation-setup.log" 2>&1 || setup_status=$?
  check "omarchy-hibernation-setup sets hibernation up (see hibernation-setup.log)" test "$setup_status" -eq 0
  if ((setup_status != 0)); then
    stop_vm
    return 1
  fi

  ssh_sudo "systemctl poweroff" >/dev/null 2>&1 || true
  wait_for_power_off
  check "machine powered off after hibernation setup (${WAITED}s)" vm_powered_off
  if vm_running; then
    capture_console "failure-setup-poweroff-still-running"
    stop_vm
    return 1
  fi
}

verify_hibernate_resume() {
  log "Booting with the resume parameters to hibernate it"
  start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/setup-serial.log"
  wait_for_ssh "$BOOT_TIMEOUT"

  check "the swapfile is active (somewhere for the hibernation image)" \
    ssh_sudo "swapon --show=NAME --noheadings | grep -qx /swap/swapfile"
  check "the cmdline names the resume device" ssh_guest "grep -qE '(^| )resume=' /proc/cmdline"
  check "the kernel offers suspend-to-disk" ssh_guest "grep -qw disk /sys/power/state"

  ssh_guest 'echo alive >/dev/shm/hib-marker; cut -d. -f1 /proc/uptime >/dev/shm/uptime-before'
  capture_console "success-before-hibernate"

  log "systemctl hibernate; waiting for the machine to power off"
  ssh_sudo "systemctl hibernate" >/dev/null 2>&1 || true
  wait_for_power_off
  check "machine powered off after systemctl hibernate (${WAITED}s)" vm_powered_off
  if vm_running; then
    capture_console "failure-hibernate-still-running"
    stop_vm
    return 0
  fi

  log "Booting the same disk again to resume"
  start_vm "$RUN_DIR/run.qcow2" "$RUN_DIR/resume-serial.log"
  wait_for_ssh "$BOOT_TIMEOUT"

  check "resumed from hibernation (tmpfs marker survived the power cycle)" \
    ssh_guest 'test "$(cat /dev/shm/hib-marker 2>/dev/null)" = alive'
  check "uptime continued from before the hibernation (not a cold boot)" \
    ssh_guest 'test "$(cut -d. -f1 /proc/uptime)" -ge "$(cat /dev/shm/uptime-before 2>/dev/null || echo 999999)"'
  check "the kernel logged the hibernation exit" \
    ssh_sudo "dmesg | grep -qi 'hibernation exit'"
  check "the swap device is active again after the resume" \
    ssh_sudo "swapon --show --noheadings | grep -q ."

  capture_console "success-resumed"
  stop_vm
}

# ---------------------------------------------------------------------- main

set_up_hibernation && verify_hibernate_resume
finish
