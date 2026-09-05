#!/bin/bash
#
# Factory reset on a shared ESP: proves omarchy-system-factory-reset hands a
# machine on without destroying a dual-boot setup (basecamp/omarchy#6847).
# Dresses the installed ESP up as a dual-boot machine (Windows + a foreign
# Linux, exactly what the reset must not destroy), runs a real factory reset,
# and walks the first-boot setup that follows.
#
# Staging asserts the Windows and foreign Linux entries and their ESP payload
# survive, the old Omarchy identity (entry + directory) is gone, and a fresh
# Omarchy entry exists. First boot asserts provisioning completes, the machine
# identity changed, and the foreign entries are still intact afterwards.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# This scenario is about a shared UEFI ESP (Windows + a foreign Linux under
# EFI/Linux, efibootmgr entries) — concepts that do not exist on a legacy BIOS
# install. Skip it there rather than fail its UEFI-specific assertions.
if [[ $FIRMWARE != uefi ]]; then
  log "factory-reset is UEFI-only (shared-ESP dual boot); skipping under $FIRMWARE"
  exit 0
fi

FOREIGN_ID="fedcfedcfedcfedcfedcfedcfedcfedc"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

# --------------------------------------------------------------- esp fixture

# Dress the ESP up as a shared dual-boot ESP: a Windows entry, and a second
# Linux installation cloned from the real Omarchy entry so its shape is
# exactly what limine-entry-tool writes, under a foreign machine-id with its
# own boot directory and byte-identical UKIs (so the cloned entry hashes
# stay valid).
fixture_shared_esp() {
  OLD_ID=$(ssh_guest "cat /etc/machine-id" | tr -d '\r\n')
  [[ $OLD_ID =~ ^[0-9a-f]{32}$ ]] || { echo "unexpected machine-id: $OLD_ID" >&2; return 1; }

  ssh_sudo "cp /boot/limine.conf /boot/limine.conf.pretest" >/dev/null
  ssh_sudo "
    set -euo pipefail
    awk '/^\//{block=1} block' /boot/limine.conf |
      sed -e 's/$OLD_ID/$FOREIGN_ID/g' \
          -e 's|/EFI/Linux/omarchy_|/EFI/Linux/foreign_|g' \
          -e 's|^/\(+\{0,1\}\)\([^/+]\)|/\1Foreign \2|' >/tmp/foreign-entries
    grep -q 'machine-id=$FOREIGN_ID' /tmp/foreign-entries
    for uki in /boot/EFI/Linux/omarchy_*.efi; do
      cp \"\$uki\" \"\${uki/omarchy_/foreign_}\"
    done
    cat >>/boot/limine.conf <<'CONF'

/Windows
    protocol: efi
    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
CONF
    cat /tmp/foreign-entries >>/boot/limine.conf
    mkdir -p /boot/$FOREIGN_ID /boot/EFI/Microsoft/Boot
    echo foreign-payload >/boot/$FOREIGN_ID/marker
    echo windows-payload >/boot/EFI/Microsoft/Boot/bootmgfw.efi
  " >/dev/null

  ssh_sudo "cat /boot/limine.conf" >"$RUN_DIR/limine.conf.fixtured"
  log "ESP fixtured as a shared dual-boot ESP (old machine-id $OLD_ID)"
}

# ------------------------------------------------------------- reset driver

# Drive the interactive reset through a pty on the guest: `script` supplies
# the terminal gum needs, a fifo feeds it answers on our schedule, and the
# typescript lands in /tmp/reset.out for the polling below.
start_reset() {
  # script hands the pty over at 0x0 when its own stdin is not a terminal,
  # which crashes gum's text input; give it a real size first. setsid keeps
  # both processes alive after this ssh session hangs up.
  ssh_guest "
    rm -f /tmp/reset.in /tmp/reset.out
    mkfifo /tmp/reset.in
    setsid bash -c 'exec 3<>/tmp/reset.in && sleep 3600' >/dev/null 2>&1 &
    setsid script -qefc 'stty rows 35 cols 130; sudo -S -p \"\" omarchy-system-factory-reset' /tmp/reset.out \
      </tmp/reset.in >/dev/null 2>&1 &
  "
  sleep 2
  ssh_guest "printf '%s\n' '$GUEST_PASSWORD' >/tmp/reset.in"
}

reset_output() {
  ssh_guest "sed 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\x1b\][^\x07]*\x07//g' /tmp/reset.out 2>/dev/null" || true
}

wait_for_reset_output() {
  local text="$1" timeout="$2" waited=0

  until reset_output | grep -qi "$text"; do
    if reset_output | grep -qE "^Error:|COMMAND_EXIT_CODE"; then
      reset_output >"$RUN_DIR/reset.out"
      echo "The factory reset failed before reaching: $text" >&2
      reset_output | grep -E "^Error:" >&2 || true
      return 1
    fi
    if ((waited >= timeout)); then
      reset_output >"$RUN_DIR/reset.out"
      echo "Timed out after ${timeout}s waiting for reset output: $text" >&2
      return 1
    fi
    sleep 3
    ((waited += 3))
  done
}

reset_phase() {
  log "Booting reset VM from base image overlay"

  start_vm_from_base
  wait_for_ssh "$BOOT_TIMEOUT"

  fixture_shared_esp

  log "Running omarchy-system-factory-reset"
  start_reset
  wait_for_reset_output "Type 'reset' to continue" 60
  capture_console "success-reset-confirm"
  ssh_guest "printf 'reset\r' >/tmp/reset.in"

  # Staging clones @factory, rebuilds the UKI in a chroot, and reworks the
  # ESP; only then does the reboot prompt appear.
  wait_for_reset_output "Reboot to complete the reset" 900
  reset_output >"$RUN_DIR/reset.out"
  log "Reset staged. Asserting on the shared ESP before rebooting."

  check "windows entry survives staging" \
    ssh_sudo "grep -q '^/Windows' /boot/limine.conf"
  check "windows boot payload survives staging" \
    ssh_sudo "grep -q windows-payload /boot/EFI/Microsoft/Boot/bootmgfw.efi"
  check "foreign linux entry survives staging" \
    ssh_sudo "grep -q 'machine-id=$FOREIGN_ID' /boot/limine.conf"
  check "foreign boot directory survives staging" \
    ssh_sudo "grep -q foreign-payload /boot/$FOREIGN_ID/marker"
  check "foreign UKI survives staging" \
    ssh_sudo "test -f /boot/EFI/Linux/foreign_linux.efi"
  check "old omarchy entry is removed by staging" \
    ssh_sudo "! grep -q 'machine-id=$OLD_ID' /boot/limine.conf"
  check "old omarchy boot directory is removed by staging" \
    ssh_sudo "! test -e /boot/$OLD_ID"
  check "a fresh omarchy entry exists after staging" \
    ssh_sudo "grep -o 'machine-id=[0-9a-f]\{32\}' /boot/limine.conf | grep -qv 'machine-id=$FOREIGN_ID'"

  ssh_sudo "cat /boot/limine.conf" >"$RUN_DIR/limine.conf.staged" || true
  ssh_sudo "cat /var/log/omarchy-system-factory-reset.log" >"$RUN_DIR/factory-reset.log" || true
  capture_console "success-reset-staged"

  if ((FAILURES > 0)); then
    log "Staging assertions failed; keeping the VM off the reboot path."
    return 1
  fi

  # Decline the prompt's reboot; reboot deliberately so the ssh session
  # closing cannot race the answer.
  ssh_guest "printf 'n' >/tmp/reset.in"
  sleep 2
  log "Rebooting into the factory first boot"
  ssh_sudo "systemctl reboot" || true
}

# --------------------------------------------------------------- first boot

# Answer whichever setup screens the factory first boot presents. The form's
# exact steps depend on what the reset deferred, so dispatch on the screen
# actually showing instead of scripting a fixed sequence.
drive_first_boot() {
  log "Driving the factory first-boot setup"

  # The reset must leave a bootable default: the machine has to reach the
  # first-boot greeter on its own. A numeric default_entry pointing at a
  # moved entry parks Limine at the menu instead — catch that explicitly,
  # then boot the Omarchy entry by hand so the rest of the flow still runs.
  if wait_for_screen "Opinionated" 120 2>/dev/null; then
    printf 'ok - %s\n' "the machine boots into first-boot setup unattended"
  else
    if ocr_screen | grep -qi "Omarchy Bootloader"; then
      printf 'not ok - %s\n' "the machine boots into first-boot setup unattended (parked at the Limine menu)"
      ((FAILURES += 1))
      capture_console "failure-firstboot-parked-at-menu"
      log "Selecting the Omarchy entry manually to continue the run"
      press down; sleep 1; press down; sleep 1; press down; sleep 1
      press ret
      wait_for_screen "Opinionated" 600
    else
      echo "Neither the greeter nor the Limine menu appeared" >&2
      return 1
    fi
  fi
  capture_console "success-firstboot-00-greeter"
  press ret

  local waited=0 text step
  local -A answered=()
  while true; do
    text=$(ocr_screen)
    step=""

    if grep -qi "look right" <<<"$text"; then
      capture_console "success-firstboot-03-review"
      press ret
      break
    elif grep -qi "keyboard layout" <<<"$text"; then
      step="keyboard"; [[ -v answered[$step] ]] || { capture_console "success-firstboot-01-keyboard"; press ret; }
    elif grep -qi "Username" <<<"$text"; then
      step="username"; [[ -v answered[$step] ]] || { type_text "$GUEST_USER"; press ret; }
    elif grep -qi "Conf *irm" <<<"$text"; then
      step="confirm"; [[ -v answered[$step] ]] || { type_text "$GUEST_PASSWORD"; press ret; }
    elif grep -qi "Password" <<<"$text"; then
      step="password"; [[ -v answered[$step] ]] || { type_text "$GUEST_PASSWORD"; press ret; }
    elif grep -qi "Full name" <<<"$text"; then
      step="fullname"; [[ -v answered[$step] ]] || { type_text "Omarchy Test"; press ret; }
    elif grep -qi "Email address" <<<"$text"; then
      step="email"; [[ -v answered[$step] ]] || { type_text "test@omarchy.org"; capture_console "success-firstboot-02-form"; press ret; }
    elif grep -qi "Hostname" <<<"$text"; then
      step="hostname"; [[ -v answered[$step] ]] || { type_text "$GUEST_HOSTNAME"; press ret; }
    elif grep -qi "Timezone" <<<"$text"; then
      step="timezone"; [[ -v answered[$step] ]] || press ret
    fi
    [[ -n $step ]] && answered[$step]=1

    if ! vm_running; then
      echo "VM exited during first-boot setup" >&2
      return 1
    fi
    if ((waited >= 600)); then
      capture_console "failure-firstboot-form-timeout"
      echo "Timed out driving the first-boot form" >&2
      return 1
    fi
    sleep 3
    ((waited += 3))
  done

  capture_console "success-firstboot-04-finalizing"
}

first_boot_phase() {
  drive_first_boot

  # Finalization can still be running when the console appears; the pending
  # flag clearing is the definitive end of provisioning. The reset scrubbed
  # users, host keys, and sshd state, so SSH has to be re-authorized first.
  bootstrap_ssh

  log "Waiting for provisioning to finish"
  local waited=0 rc
  while true; do
    rc=0
    ssh_guest "test -f /var/lib/omarchy/provisioning/pending" 2>/dev/null || rc=$?
    (( rc == 0 || rc == 255 )) || break
    if ((waited >= 900)); then
      capture_console "failure-provisioning-timeout"
      echo "Timed out waiting for first-boot provisioning to complete" >&2
      return 1
    fi
    sleep 10
    ((waited += 10))
  done

  local new_id
  new_id=$(ssh_guest "cat /etc/machine-id" | tr -d '\r\n')

  check "provisioning completed on first boot" \
    ssh_guest "! test -f /var/lib/omarchy/provisioning/pending"
  # A well-formed identity, and not one we already know: an empty or echoed
  # ID would make the boot-entry grep below match the wrong entry.
  check "the reset minted a fresh machine identity" \
    bash -c "[[ '$new_id' =~ ^[0-9a-f]{32}\$ && '$new_id' != '$OLD_ID' && '$new_id' != '$FOREIGN_ID' ]]"
  check "windows entry survives the first boot" \
    ssh_sudo "grep -q '^/Windows' /boot/limine.conf"
  check "windows boot payload survives the first boot" \
    ssh_sudo "grep -q windows-payload /boot/EFI/Microsoft/Boot/bootmgfw.efi"
  check "foreign linux entry survives the first boot" \
    ssh_sudo "grep -q 'machine-id=$FOREIGN_ID' /boot/limine.conf"
  check "foreign boot directory survives the first boot" \
    ssh_sudo "grep -q foreign-payload /boot/$FOREIGN_ID/marker"
  check "foreign UKI survives the first boot" \
    ssh_sudo "test -f /boot/EFI/Linux/foreign_linux.efi"
  check "old omarchy identity never returns" \
    ssh_sudo "! grep -q 'machine-id=$OLD_ID' /boot/limine.conf"
  check "the new identity owns a boot entry" \
    ssh_sudo "grep -q 'machine-id=$new_id' /boot/limine.conf"

  ssh_sudo "cat /boot/limine.conf" >"$RUN_DIR/limine.conf.final" || true
  capture_console "success-final"
}

# ---------------------------------------------------------------------- main

reset_phase
first_boot_phase
finish
