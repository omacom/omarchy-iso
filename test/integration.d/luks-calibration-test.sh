#!/bin/bash
# Exercise the shipped service, both format callers, missing/malformed-state
# fallbacks, actual keyslot costs and repeated unlocks in an 8 GiB live guest.
# Standalone: OMARCHY_INTEGRATION_ISO=/path/to.iso bash test/integration.d/luks-calibration-test.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

[[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
qemu-img create -f qcow2 "$RUN_DIR/scratch.qcow2" 1G >/dev/null
cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
MEMORY=8192 start_vm "$RUN_DIR/scratch.qcow2" "$RUN_DIR/serial.log" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2
bootstrap_live_root_ssh
# No cidata is attached: the wizard waits while the guest test waits for the
# service to exit successfully. A deliberate skip exercises normal formatting.
ssh_live_root 'cat >/tmp/luks-calibration-guest.py' <"$ROOT/test/luks-calibration-guest.py"
if ssh_live_root 'python /tmp/luks-calibration-guest.py' >"$RUN_DIR/calibration.json" 2>"$RUN_DIR/calibration.stderr"; then
  check "both callers format and unlock after completed or skipped calibration" true
else
  cat "$RUN_DIR/calibration.stderr" >&2
  check "both callers format and unlock after completed or skipped calibration" false
fi
ssh_live_root 'journalctl -b -u omarchy-luks-calibrate.service --no-pager' >"$RUN_DIR/calibration-unit.log"
stop_vm

# A nominal 4 GiB VM has <4 GiB usable RAM. cryptsetup's memory cap here
# depends on free RAM at the instant it starts. This must take the fallback.
cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
MEMORY=4096 start_vm "$RUN_DIR/scratch.qcow2" "$RUN_DIR/small-memory-serial.log" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2
bootstrap_live_root_ssh
ssh_live_root 'cat >/tmp/luks-calibration-guest.py' <"$ROOT/test/luks-calibration-guest.py"
if ssh_live_root 'python /tmp/luks-calibration-guest.py --expect-no-cache' >"$RUN_DIR/small-memory.json" 2>"$RUN_DIR/small-memory.stderr"; then
  check "4 GiB live guest formats and unlocks with normal calibration" true
else
  cat "$RUN_DIR/small-memory.stderr" >&2
  check "4 GiB live guest formats and unlocks with normal calibration" false
fi
ssh_live_root 'journalctl -b -u omarchy-luks-calibrate.service --no-pager' >"$RUN_DIR/small-memory-unit.log"
stop_vm
finish
