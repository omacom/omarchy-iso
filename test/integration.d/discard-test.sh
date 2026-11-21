#!/bin/bash
#
# The installer tells the drive that the new root partition is free before it
# writes to it (omarchy-discard-partition). Nothing else would: mkfs.btrfs
# runs with -K, the root image fills only the start of the partition, and the
# installed btrfs only discards what it frees after mount.
#
# Boots the live ISO once to fill the last 8 GiB of the disk with random data,
# as a previous install would have left it, then installs unattended over it
# on a disk that passes discards through to its qcow2 file (discard=unmap). The
# root partition ends at the end of the disk and the root image never reaches
# that far, so once the install is done, the host's map of the disk image
# must show that region unallocated: only a discard can free it.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

DISCARD_DISK="$RUN_DIR/discard.qcow2"
qemu-img create -f qcow2 "$DISCARD_DISK" "${DISK_GB}G" >/dev/null
cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
fill_gib=8
fill_start_gib=$((DISK_GB - fill_gib - 1))

# Bytes of the disk image's own data clusters in [start, start + length).
allocated_in() { # disk start length
  qemu-img map -U --output=json "$1" | python3 -c '
import json, sys
start, end = int(sys.argv[1]), int(sys.argv[1]) + int(sys.argv[2])
print(sum(max(0, min(e["start"] + e["length"], end) - max(e["start"], start))
          for e in json.load(sys.stdin) if e["data"] and e["depth"] == 0))' "$2" "$3"
}
gib=$((1024 * 1024 * 1024))

log "Boot 1: leaving ${fill_gib} GiB of old data at the end of the disk"
start_vm "$DISCARD_DISK" "$RUN_DIR/fill-serial.log" \
  -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
  -device ide-cd,drive=cdrom0,bootindex=2
bootstrap_live_root_ssh
# 64 MiB blocks: seek and count are in blocks, 16 to the GiB. Detached, so the
# wait below bounds it (a host disk that fills pauses the guest, and an SSH
# session would wait on it forever); it powers the VM off when done.
printf '%s\n' "exec >/dev/ttyS0 2>&1" \
  "dd if=/dev/urandom of=/dev/vda bs=64M seek=$((fill_start_gib * 16)) count=$((fill_gib * 16)) status=none" \
  sync poweroff >"$RUN_DIR/fill"
ssh_live_root 'cat >/tmp/fill' <"$RUN_DIR/fill"
ssh_live_root 'setsid bash /tmp/fill </dev/null >/dev/null 2>&1 &'
waited=0
while vm_running; do
  if ((waited >= 300)); then
    capture_console "failure-fill-timeout"
    echo "Timed out filling the disk" >&2
    exit 1
  fi
  sleep 5
  ((waited += 5))
done
before=$(allocated_in "$DISCARD_DISK" $((fill_start_gib * gib)) $((fill_gib * gib)))
log "Before the install: $((before / 1024 / 1024)) MiB of the last ${fill_gib} GiB hold data"
if ((before < fill_gib * gib * 9 / 10)); then
  echo "The old data was not laid down; nothing here would test the installer" >&2
  exit 1
fi

log "Boot 2: installing unattended over it, with discards reaching the disk image"
cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
if ! OMARCHY_DISK_DRIVE_OPTS=discard=unmap install_unattended "$DISCARD_DISK" "$RUN_DIR/install-serial.log"; then
  echo "--- last lines of the serial console ---" >&2
  tail -n 40 "$RUN_DIR/install-serial.log" >&2 2>/dev/null || true
  exit 1
fi
ssh_sudo "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
capture_console "success-discard"
stop_vm

after=$(allocated_in "$DISCARD_DISK" $((fill_start_gib * gib)) $((fill_gib * gib)))
log "After the install: $((after / 1024 / 1024)) MiB of the last ${fill_gib} GiB hold data"
grep -a 'omarchy-discard-partition' "$RUN_DIR/omarchy-install.log" >"$RUN_DIR/discard.txt" || true
check "the installer discarded the new root partition ($(head -n 1 "$RUN_DIR/discard.txt"))" \
  grep -q 'omarchy-discard-partition: discarded ' "$RUN_DIR/discard.txt"
check "the old data at the end of the disk is gone from the disk image ($((before / 1024 / 1024)) MiB before, $((after / 1024 / 1024)) MiB after)" \
  test "$after" -lt $((64 * 1024 * 1024))

finish
