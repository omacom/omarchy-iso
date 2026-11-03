#!/usr/bin/env bash
# The live ISO must reach its greeter with 512 MB of RAM.
#
# omarchy-iso#128: the 4.0.0 live initramfs was 241 MiB (the kms hook pulled
# every DRM driver's firmware in), and GRUB failed to allocate it on a Lenovo
# Yoga's fragmented EFI memory map, then booted the kernel without it: a VFS
# panic that looked like a bad USB stick. Under OVMF the same initramfs fails at
# 512 MB (GRUB cannot start the kernel image) and at 768 MB (the kernel cannot
# unpack it); the 91 MiB one boots at 512. That makes 512 MB a deterministic
# regression gate for the size of the live initramfs, independent of firmware.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

verify_live_lowmem() {
  local disk="$RUN_DIR/scratch.qcow2"
  qemu-img create -f qcow2 "$disk" 1G >/dev/null
  log "Booting the live ISO alone with 512 MB to its greeter"
  MEMORY=512 start_vm "$disk" "$RUN_DIR/serial.log" \
    -drive "file=$ISO,media=cdrom,if=none,format=raw,id=cdrom0" \
    -device ide-cd,drive=cdrom0,bootindex=2
  check "the live ISO reaches the installer greeter with 512 MB of RAM" \
    wait_for_screen "Linux by DHH" 300
  capture_console "success-live-512mb"
  stop_vm
}

verify_live_lowmem
finish
