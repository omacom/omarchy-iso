#!/bin/bash
#
# A corrupt install medium is refused before the disk is touched. The root
# image ships on the ISO with its sha256 beside it; omarchy-root-image-verify
# checks it at boot and the installer's pre-flight phase takes that verdict.
# Flip one byte inside the image stream on a copy of the ISO (a badly
# flashed stick's damage, for real), autoinstall from it, and assert: the
# unit fails, the install halts in "Preparing install target" telling the
# user to re-flash, nothing after that phase ran, and the target disk still
# has no partition table. Damaging the artifact rather than the recorded
# digest proves the digest is sensitive to the shipped bytes at that
# offset; the fixture separately proves the pristine stream matches its
# recorded digest host-side, so a build hashing the wrong or a stale file
# fails even in --reuse-base and standalone runs, where no install ever
# boots the untouched ISO. (That the verify truly reads the whole multi-GB
# image is the slow-medium scenario's business, where the read is what is
# being timed.)
#
# Boots the ISO itself, not the installed base image, so it needs no base.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

CORRUPT_ISO="$BASE_DIR/corrupt.iso"
STREAM=arch/x86_64/omarchy-root.btrfs.zst
VERIFY_UNIT=omarchy-root-image-verify.service
GATE_UNIT=omarchy-install-prepare-target.service
# The failing phase's own words live in the journal under the handover
# identifier, each line prefixed with the failing unit's name (cgroup
# attribution loses the teardown race) -- there is no handover file.
PHASE_ERROR_QUERY='journalctl -b -t omarchy-phase-error -o cat --no-pager | grep ^omarchy-install-prepare-target.service:'

# ------------------------------------------------------------------ fixture

# A copy of the ISO with one byte flipped inside the root image stream
# itself. ISO9660 files are contiguous extents with no per-file integrity
# data, so patching in place leaves everything else on the medium intact
# (cp --reflink makes the copy free on btrfs).
#
# The stream's extent comes from the ISO9660 directory records themselves:
# xorriso reports the file's start LBA and byte size, so the flip is placed
# by filesystem metadata, not by searching for content (the zstd frame
# magic opens every mirror package and countless squashfs blocks on this
# ISO, so a content search would need fingerprinting games). ISO9660 files
# are single contiguous extents, which is what makes lba*2048 + offset a
# byte address inside this file and no other.
corrupt_iso() {
  local lba size start off orig flipped

  log "Copying the ISO and corrupting one byte inside the root image stream"
  rm -f "$CORRUPT_ISO"
  cp --reflink=auto "$ISO" "$CORRUPT_ISO"

  # "File data lba:  xt , startlba , blocks , filesize , path"
  # || true: under set -e a read off an empty pipe would kill the scenario
  # before the guard below could say what went wrong.
  read -r lba size < <(xorriso -indev "$ISO" -find "/$STREAM" -exec report_lba 2>/dev/null |
    awk -F, '/File data lba/ { gsub(/ /, ""); print $2, $4 }') || true
  [[ ${lba:-} =~ ^[0-9]+$ && ${size:-} =~ ^[0-9]+$ ]] ||
    { echo "xorriso could not report the extent of $STREAM" >&2; return 1; }
  start=$((lba * 2048))

  # Before damaging anything, prove the pristine artifact verifies: the
  # digest recorded at build time must match the bytes that ship, computed
  # here over the extent just located. Every booted install checks this
  # implicitly, but --reuse-base skips the install and this scenario runs
  # standalone, and in those modes nothing else would catch a build that
  # hashed the wrong or a stale file.
  local recorded computed
  recorded=$(xorriso -osirrox on -indev "$ISO" -extract "/$STREAM.sha256" "$BASE_DIR/stream.sha256" 2>/dev/null &&
    awk '{print $1; exit}' "$BASE_DIR/stream.sha256") || true
  [[ ${recorded:-} =~ ^[0-9a-f]{64}$ ]] ||
    { echo "could not read the recorded digest for $STREAM" >&2; return 1; }
  computed=$(dd if="$ISO" bs=1M iflag=skip_bytes,count_bytes skip="$start" count="$size" status=none | sha256sum | cut -d' ' -f1)
  [[ $computed == "$recorded" ]] ||
    { echo "pristine image does not match its recorded digest (recorded ${recorded:0:8}..., shipped ${computed:0:8}...)" >&2; return 1; }
  log "Pristine stream matches its recorded digest (${recorded:0:8}...)"

  # Deep enough to model bit-rot in the payload, and provably inside the
  # file's extent; +1 mod 256 so the byte always changes.
  off=$((start + 1048576))
  ((1048576 < size)) || { echo "stream unexpectedly small: $size bytes" >&2; return 1; }
  orig=$(dd if="$CORRUPT_ISO" bs=1 skip="$off" count=1 status=none | od -An -tu1 | tr -d ' ')
  flipped=$(( (orig + 1) % 256 ))
  printf "\\$(printf '%03o' "$flipped")" |
    dd of="$CORRUPT_ISO" bs=1 seek="$off" conv=notrunc status=none
  log "Stream extent at LBA $lba ($size bytes); byte at ISO offset $off flipped ($orig -> $flipped)"
}

# -------------------------------------------------------------------- phases

install_from_corrupt_medium() {
  [[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
  detect_packages
  build_cidata

  qemu-img create -f qcow2 "$RUN_DIR/disk.qcow2" 40G >/dev/null
  if [[ $FIRMWARE == uefi ]]; then
    cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS.4m.fd"
    ACTIVE_OVMF="$RUN_DIR/OVMF_VARS.4m.fd"
  fi

  log "Autoinstalling from the corrupt medium (headless)"
  start_vm "$RUN_DIR/disk.qcow2" "$RUN_DIR/serial.log" \
    -drive "file=$CORRUPT_ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
    -device ide-cd,drive=cdrom0,bootindex=2 \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,drive=cidata

  bootstrap_live_root_ssh

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
  sleep 2
  capture_console "success-installer-stopped"
  ssh_live_root "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
  ssh_live_root "systemctl list-units --all --no-legend 'omarchy-install-*'; echo; journalctl -b -t omarchy-phase-error -o cat --no-pager 2>/dev/null" >"$RUN_DIR/phase-state" 2>/dev/null || true
  ssh_live_root "journalctl -b -u $VERIFY_UNIT -o short-precise --no-pager" >"$RUN_DIR/verify-unit.journal" 2>/dev/null || true
}

screen_shows() {
  ocr_screen | grep -qi "$1"
}

assert_refused() {
  check "verify unit failed on the corrupt image" \
    ssh_live_root "systemctl show -p Result --value $VERIFY_UNIT | grep -qx exit-code"
  check "install halted in the pre-flight phase" \
    ssh_live_root "[ \"\$(systemctl list-units --failed --plain --no-legend 'omarchy-install-*' | awk '{print \$1}')\" = $GATE_UNIT ]"
  check "the error tells the user to re-flash the medium" \
    ssh_live_root "$PHASE_ERROR_QUERY | grep -q 'install medium is corrupt: re-flash it'"
  check "the error carries sha256sum's verdict" \
    ssh_live_root "$PHASE_ERROR_QUERY | grep -q 'did NOT match'"
  check "nothing ran after the pre-flight phase" \
    ssh_live_root "journalctl -b -u omarchy-install-prepare-live.service --no-pager | grep -q Finished && [ \"\$(systemctl show -p ExecMainStartTimestampMonotonic --value omarchy-install-disk.service)\" = 0 ]"
  check "target disk has no partition table" \
    ssh_live_root "! lsblk -rno TYPE /dev/vda | grep -qx part && ! blkid /dev/vda"
  check "dashboard shows the installation stopped" \
    screen_shows "installation stopped"
  # The advice renders in the summary block's pink-on-dark, which OCR misses
  # (the same reason slow-medium asserts its advice from the log); the
  # dashboard's own log carries the identical line untruncated.
  check "dashboard shows the re-flash advice" \
    grep -q "failed phase: .*re-flash it" "$RUN_DIR/omarchy-install.log"
}

# ---------------------------------------------------------------------- main

corrupt_iso
install_from_corrupt_medium
assert_refused
rm -f "$CORRUPT_ISO"
finish
