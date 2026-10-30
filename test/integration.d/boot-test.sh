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
# The installer encrypts in 4096-byte sectors, btrfs's own block size
# (orchestrator/luks_calibration.py); a volume formatted with 512 keeps them.
if [[ $ENCRYPT == true ]]; then
  ssh_sudo 'cryptsetup luksDump "$(blkid -t TYPE=crypto_LUKS -o device | head -n 1)"' \
    >"$RUN_DIR/luks-dump.txt" 2>/dev/null || true
  sector=$(awk '$1 == "sector:" { print $2; exit }' "$RUN_DIR/luks-dump.txt")
  check "the root's LUKS sectors are 4096 bytes (got: ${sector:-nothing})" test "$sector" = 4096

  # TRIM has to reach the drive through dm-crypt, which drops every discard
  # unless the mapping allows them (omacom/omarchy#5332). The installer stores
  # allow-discards in the LUKS2 header, so every activation applies it; the
  # live table shows it took effect, the root then advertises a discard
  # granularity, and btrfs turns on discard=async by itself only for a device
  # that does. The VM's virtio disk accepts discards, so each of these fails
  # only when the encryption layer blocks them.
  ssh_sudo 'root=$(findmnt -no SOURCE / | sed "s/\[.*//"); echo "source $root"
    echo "table $(dmsetup table "${root#/dev/mapper/}")"
    echo "granularity $(lsblk -dno DISC-GRAN "$root" | tr -d " ")"
    echo "options $(findmnt -no OPTIONS /)"' >"$RUN_DIR/trim.txt" 2>/dev/null || true
  flags=$(awk '$1 == "Flags:" { $1 = ""; print; exit }' "$RUN_DIR/luks-dump.txt" | xargs)
  granularity=$(awk '$1 == "granularity" { print $2 }' "$RUN_DIR/trim.txt")
  check "the root's LUKS2 header allows discards (flags: ${flags:-none})" grep -qw allow-discards <<<"$flags"
  check "the open root mapping passes discards (dm-crypt allow_discards)" grep -q '^table .* allow_discards' "$RUN_DIR/trim.txt"
  check "the root advertises a discard granularity (got: ${granularity:-nothing})" test -n "$granularity" -a "$granularity" != 0B
  check "btrfs discards freed space on the root (discard=async)" grep -q '^options .*discard=async' "$RUN_DIR/trim.txt"
fi
capture_console "success-boot"

stop_vm
finish
