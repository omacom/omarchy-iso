#!/bin/bash
#
# A medium too slow to read is named as such, with the disk untouched. The
# boot-time verify unit carries a size-based TimeoutStartSec so a stalling
# stick fails the pre-flight gate instead of hanging the install forever;
# this scenario forces that timeout and asserts the user reads "install
# medium is too slow" — not a generic failure. The regression it guards: a
# start timeout makes systemd STOP the unit, and on a dying medium the stop
# itself drags (SIGTERM cannot land on a read stuck in the driver), so the
# unit reports 'deactivating' long before 'failed'; the wait helper used to
# classify that window as "did not run".
#
# Mechanics: the ISO is booted unmodified. A systemd credential injected via
# SMBIOS type 11 adds a drop-in shrinking TimeoutStartSec — named 99-* so it
# sorts after the build-time 50-size-timeout.conf and wins the merge. The
# medium is throttled at boot so the hash cannot finish early, then choked
# over QMP once the installer is waiting at the gate: the hash is mid-read
# when the timeout's stop arrives, exactly like a dying stick.
#
# Boots the ISO itself, not the installed base image, so it needs no base.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

VERIFY_UNIT=omarchy-root-image-verify.service
GATE_UNIT=omarchy-install-prepare-target.service
# The failing phase's own words live in the journal under the handover
# identifier, each line prefixed with the failing unit's name (cgroup
# attribution loses the teardown race) -- there is no handover file.
PHASE_ERROR_QUERY='journalctl -b -t omarchy-phase-error -o cat --no-pager | grep ^omarchy-install-prepare-target.service:'

# Slow enough that hashing the multi-GB image cannot beat the timeout, fast
# enough that the live system boots promptly: the image needs 90+ s at this
# rate while the unit times out at 180 s only because the choke below stops
# the hash long before either.
BOOT_THROTTLE_BPS=$((40 * 1024 * 1024))

# From unit start (early boot): long enough that SSH is up and the choke has
# landed first, short enough to keep the scenario brisk.
TIMEOUT_DROPIN=$'[Service]\nTimeoutStartSec=180\n'

# ------------------------------------------------------------------ fixture

# QMP is line-delimited JSON: the whole command must be a single line, and
# qmp() swallows errors, so read the response — a failed choke would let the
# hash win the race against the timeout and pass the gate legitimately.
throttle_medium() {
  local bps="$1" resp
  resp=$(qmp "\"block_set_io_throttle\", \"arguments\": {\"device\": \"cdrom0\", \"bps\": $bps, \"bps_rd\": 0, \"bps_wr\": 0, \"iops\": 0, \"iops_rd\": 0, \"iops_wr\": 0}")
  if [[ $resp == *'"error"'* || $resp != *'"return"'* ]]; then
    echo "block_set_io_throttle failed: $resp" >&2
    return 1
  fi
}

# -------------------------------------------------------------------- phases

install_from_slow_medium() {
  local cred
  cred=$(base64 -w0 <<<"$TIMEOUT_DROPIN")

  [[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
  detect_packages
  build_cidata

  qemu-img create -f qcow2 "$RUN_DIR/disk.qcow2" 40G >/dev/null
  if [[ $FIRMWARE == uefi ]]; then
    cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
    ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
  fi

  log "Autoinstalling from a throttled medium (headless)"
  start_vm "$RUN_DIR/disk.qcow2" "$RUN_DIR/serial.log" \
    -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0,throttling.bps-total=$BOOT_THROTTLE_BPS" \
    -device ide-cd,drive=cdrom0,bootindex=2 \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,drive=cidata \
    -smbios "type=11,value=io.systemd.credential.binary:systemd.unit-dropin.${VERIFY_UNIT}~99-test-timeout=$cred"

  bootstrap_live_root_ssh

  check "shrunk timeout is in effect" \
    ssh_live_root "systemctl show -p TimeoutStartUSec --value $VERIFY_UNIT | grep -qx 3min"

  # The choke must land while the installer is already waiting at the gate:
  # the field failure is a user parked on the pre-flight phase when the
  # timeout hits, with the helper actively polling the unit through systemd's
  # slow stop of it. Choking earlier stalls the installer's own climb to the
  # gate, and it then only samples the unit after the stop has settled —
  # which hides exactly the window this scenario exists to pin down.
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

  # The image hash is the LAST of the boot readers: at gate time it can
  # still sit queued behind the mirror verify, where ActiveState reads
  # "inactive", not "activating". The gate waits mirror-first, so the unit
  # starts as soon as the mirror verify is done -- wait out that handover
  # before asserting, because the choke below must land mid-hash of the
  # stream, which is the read the field failure stalls.
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

  # If the hash already finished, the gate passes legitimately and nothing
  # below tests the timeout; the throttle above is sized to prevent this.
  check "verify unit is still hashing when the medium dies" \
    ssh_live_root "systemctl show -p ActiveState --value $VERIFY_UNIT | grep -qx activating"

  log "Choking the medium to 64 KB/s"
  # Slow enough that the hash cannot finish and the stop of a mid-read
  # process takes visible seconds, fast enough that no single request
  # outlives the guest kernel's 30 s command timeout — 1 KB/s turns reads
  # into I/O errors and the unit fails as corrupt instead of slow.
  throttle_medium 65536

  log "Waiting for the installer to stop"
  local waited=0
  until ssh_live_root 'grep -q "installer child exited" /var/log/omarchy-install.log' 2>/dev/null; do
    if ! vm_running; then
      echo "VM exited while waiting for the installer" >&2
      return 1
    fi
    if ((waited >= 600)); then
      capture_console "failure-installer-timeout"
      echo "Timed out waiting for the installer to stop" >&2
      return 1
    fi
    sleep 5
    ((waited += 5))
  done

  # Lift the choke so the stuck read drains and the unit can settle into its
  # terminal state, and so the assertions below are not themselves throttled.
  throttle_medium 0
  local settled=0
  until ssh_live_root "systemctl show -p ActiveState --value $VERIFY_UNIT | grep -qx failed" 2>/dev/null; do
    if ((settled >= 120)); then
      break
    fi
    sleep 2
    ((settled += 2))
  done

  sleep 2
  capture_console "success-installer-stopped"
  ssh_live_root "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
  ssh_live_root "systemctl list-units --all --no-legend 'omarchy-install-*'; echo; journalctl -b -t omarchy-phase-error -o cat --no-pager 2>/dev/null" >"$RUN_DIR/phase-state" 2>/dev/null || true
  ssh_live_root "journalctl -b -u $VERIFY_UNIT -o short-precise --no-pager" >"$RUN_DIR/verify-unit.journal" 2>/dev/null || true
}

screen_shows() {
  ocr_screen | grep -qi "$1"
}

assert_named_slow() {
  check "verify unit ended in a start timeout" \
    ssh_live_root "systemctl show -p Result --value $VERIFY_UNIT | grep -qx timeout"
  check "install halted in the pre-flight phase" \
    ssh_live_root "[ \"\$(systemctl list-units --failed --plain --no-legend 'omarchy-install-*' | awk '{print \$1}')\" = $GATE_UNIT ]"
  check "the error names the slow medium" \
    ssh_live_root "$PHASE_ERROR_QUERY | grep -q 'install medium is too slow: try another USB stick or port'"
  check "nothing ran after the pre-flight phase" \
    ssh_live_root "journalctl -b -u omarchy-install-prepare-live.service --no-pager | grep -q Finished && [ \"\$(systemctl show -p ExecMainStartTimestampMonotonic --value omarchy-install-disk.service)\" = 0 ]"
  check "target disk has no partition table" \
    ssh_live_root "! lsblk -rno TYPE /dev/vda | grep -qx part && ! blkid /dev/vda"
  # The stopped-banner renders red on dark, which OCR misreads; the log
  # carries the dashboard's own record of the stop.
  check "dashboard reported the installer stopped" \
    grep -q "installer child exited with status 1" "$RUN_DIR/omarchy-install.log"
  check "dashboard shows the slow-medium advice" \
    screen_shows "too slow"
}

# ---------------------------------------------------------------------- main

install_from_slow_medium
assert_named_slow
finish
