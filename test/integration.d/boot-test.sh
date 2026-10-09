#!/bin/bash
#
# Everyday boot: boots the installed system a second time and records how
# long it takes to answer SSH and what systemd-analyze reports, then asserts
# that systemd finished starting with no failed units. CI reports these next
# to the install time, so a change that slows booting shows up in its PR.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

log "Booting the installed system"
boot_started=$(date +%s%N)
start_vm_from_base
if ! wait_for_ssh 300 failure-boot-ssh-timeout; then
  # The console screenshot is saved; the serial log shows what the firmware,
  # loader and kernel printed, which a screenshot of a hung boot often lacks.
  echo "--- last lines of the serial console ---" >&2
  tail -n 40 "$RUN_DIR/serial.log" >&2 2>/dev/null || true
  exit 1
fi
boot_ms=$((($(date +%s%N) - boot_started) / 1000000))
# Coarse: wait_for_ssh polls every 2 s. systemd-analyze below has the exact
# firmware, loader, kernel and userspace split.
log "SSH answered within ${boot_ms} ms of power-on"

# --wait returns once startup has finished, so systemd-analyze has final
# numbers and a unit that fails late in boot is still counted. It exits
# non-zero for "degraded"; keep the answer so the diagnostics below are still
# collected and the assertion reports it.
state=$(ssh_guest "timeout 120 systemctl is-system-running --wait" 2>/dev/null | tr -d '\r' || true)
ssh_guest "systemd-analyze" >"$RUN_DIR/systemd-analyze.txt" 2>/dev/null || true
ssh_guest "systemd-analyze blame --no-pager | head -n 20" >"$RUN_DIR/systemd-analyze-blame.txt" 2>/dev/null || true
# A query that fails must not read as "no failed units".
ssh_guest "systemctl --failed --no-legend --plain" >"$RUN_DIR/failed-units.txt" 2>/dev/null ||
  echo "could not query failed units over SSH" >"$RUN_DIR/failed-units.txt"
printf '{"boot_to_ssh_ms": %d, "system_state": "%s"}\n' "$boot_ms" "$state" >"$RUN_DIR/boot-timing.json"

check "systemd reports the system running (got: ${state:-nothing})" test "$state" = running
check "no failed units" test ! -s "$RUN_DIR/failed-units.txt"
capture_console "success-boot"

stop_vm
finish
