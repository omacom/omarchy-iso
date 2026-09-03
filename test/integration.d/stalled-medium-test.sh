#!/bin/bash
#
# A medium that stops answering outright is named "too slow" in seconds, not
# after the size-based timeout's minutes. The verify units run under
# omarchy-stall-watchdog: when the hasher's reads stop advancing for 30 s the
# wrapper kills it and exits 75, and the gate translates that into the same
# slow-medium advice the size timeout produces — reached while the user is
# still looking at the screen instead of twenty minutes later.
#
# Mechanics: the ISO boots unmodified with a lightly throttled medium (so the
# hash is still running when the installer reaches the gate — the same
# staging as the slow-medium scenario). Then the hasher is frozen with
# SIGSTOP: reads stop without device errors, which to the watchdog is
# exactly a stick that went silent — a QMP throttle cannot fake that,
# because a near-zero cap turns reads into guest I/O errors and the unit
# fails as corrupt instead (see slow-medium's choke comment).
#
# Boots the ISO itself, not the installed base image, so it needs no base.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

VERIFY_UNIT=omarchy-root-image-verify.service
GATE_UNIT=omarchy-install-prepare-target.service
# The failing phase's own words live in the journal under the handover
# identifier, each line prefixed with the failing unit's name (cgroup
# attribution loses the teardown race) -- there is no handover file.
PHASE_ERROR_QUERY='journalctl -b -t omarchy-phase-error -o cat --no-pager | grep ^omarchy-install-prepare-target.service:'

# Slow enough that hashing the multi-GB image is still going when SSH is up
# and the installer sits at the gate; fast enough that the live system boots
# promptly.
BOOT_THROTTLE_BPS=$((40 * 1024 * 1024))

# Watchdog threshold (30 s) + its sampling jitter + wait-verify's poll +
# the dashboard's teardown. Generous headroom on a loaded host — the point
# is the order of magnitude: seconds, not the size timeout's minutes.
STALL_VERDICT_BUDGET=180

# -------------------------------------------------------------------- phases

install_from_stalled_medium() {
  [[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
  detect_packages
  build_cidata

  qemu-img create -f qcow2 "$RUN_DIR/disk.qcow2" 40G >/dev/null
  if [[ $FIRMWARE == uefi ]]; then
    cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
    ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
  fi

  log "Autoinstalling from a medium about to go silent (headless)"
  start_vm "$RUN_DIR/disk.qcow2" "$RUN_DIR/serial.log" \
    -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0,throttling.bps-total=$BOOT_THROTTLE_BPS" \
    -device ide-cd,drive=cdrom0,bootindex=2 \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,drive=cidata

  bootstrap_live_root_ssh

  log "Waiting for the installer to reach the verify gate"
  local gated=0
  until ssh_live_root "systemctl show -p ActiveState --value $GATE_UNIT | grep -qx activating" >/dev/null 2>&1; do
    if ! vm_running; then
      echo "VM exited before the installer reached the verify gate" >&2
      return 1
    fi
    if ((gated >= 300)); then
      capture_console "failure-gate-timeout"
      echo "Timed out waiting for the installer to reach the verify gate" >&2
      return 1
    fi
    sleep 2
    ((gated += 2))
  done

  # The image hash is the LAST of the boot readers: wait out the handover
  # from the mirror verify (where the image unit still reads "inactive"),
  # because the freeze below must land mid-hash of the stream.
  local handover=0
  until ssh_live_root "systemctl show -p ActiveState --value $VERIFY_UNIT | grep -qx activating" 2>/dev/null; do
    if ! vm_running; then
      echo "VM exited before the image hash started" >&2
      return 1
    fi
    if ((handover >= 180)); then
      capture_console "failure-hash-start-timeout"
      echo "Timed out waiting for the image hash to start" >&2
      return 1
    fi
    sleep 2
    ((handover += 2))
  done

  check "verify unit is still hashing when the medium goes silent" \
    ssh_live_root "systemctl show -p ActiveState --value $VERIFY_UNIT | grep -qx activating"

  log "Freezing the hasher (SIGSTOP): the medium goes silent"
  ssh_live_root "pkill -STOP -x sha256sum" ||
    { echo "No sha256sum to freeze" >&2; return 1; }
  local frozen_at=$SECONDS

  log "Waiting for the stall verdict (budget ${STALL_VERDICT_BUDGET}s)"
  local waited=0
  until ssh_live_root 'grep -q "installer child exited" /var/log/omarchy-install.log' 2>/dev/null; do
    if ! vm_running; then
      echo "VM exited while waiting for the installer" >&2
      return 1
    fi
    if ((waited >= STALL_VERDICT_BUDGET)); then
      capture_console "failure-verdict-timeout"
      echo "No stall verdict within ${STALL_VERDICT_BUDGET}s — is the watchdog wired in?" >&2
      return 1
    fi
    sleep 5
    ((waited += 5))
  done
  VERDICT_SECS=$((SECONDS - frozen_at))
  log "Installer stopped ${VERDICT_SECS}s after the freeze"

  sleep 2
  capture_console "success-installer-stopped"
  ssh_live_root "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
  ssh_live_root "systemctl list-units --all --no-legend 'omarchy-install-*'; echo; journalctl -b -t omarchy-phase-error -o cat --no-pager 2>/dev/null" >"$RUN_DIR/phase-state" 2>/dev/null || true
  ssh_live_root "journalctl -b -u $VERIFY_UNIT -o short-precise --no-pager" >"$RUN_DIR/verify-unit.journal" 2>/dev/null || true
}

screen_shows() {
  ocr_screen | grep -qi "$1"
}

assert_named_stalled() {
  check "the watchdog killed the hash (exit 75)" \
    ssh_live_root "systemctl show -p ExecMainStatus --value $VERIFY_UNIT | grep -qx 75"
  check "the verdict landed in seconds, not the size timeout's minutes" \
    test "$VERDICT_SECS" -le "$STALL_VERDICT_BUDGET"
  check "install halted in the pre-flight phase" \
    ssh_live_root "[ \"\$(systemctl list-units --failed --plain --no-legend 'omarchy-install-*' | awk '{print \$1}')\" = $GATE_UNIT ]"
  check "the error names the slow medium" \
    ssh_live_root "$PHASE_ERROR_QUERY | grep -q 'install medium is too slow: try another USB stick or port'"
  check "the error names the stall, not a size timeout" \
    ssh_live_root "$PHASE_ERROR_QUERY | grep -q 'stalled: the medium stopped returning data'"
  check "nothing ran after the pre-flight phase" \
    ssh_live_root "journalctl -b -u omarchy-install-prepare-live.service --no-pager | grep -q Finished && [ \"\$(systemctl show -p ExecMainStartTimestampMonotonic --value omarchy-install-disk.service)\" = 0 ]"
  check "target disk has no partition table" \
    ssh_live_root "! lsblk -rno TYPE /dev/vda | grep -qx part && ! blkid /dev/vda"
  check "dashboard reported the installer stopped" \
    grep -q "installer child exited with status 1" "$RUN_DIR/omarchy-install.log"
  check "dashboard shows the slow-medium advice" \
    screen_shows "too slow"
}

# ---------------------------------------------------------------------- main

install_from_stalled_medium
assert_named_stalled
finish
