#!/bin/bash
#
# The installed system booted, and it booted the way the firmware demands:
# under UEFI it comes up with an EFI runtime and a Limine EFI binary on the
# ESP; under legacy BIOS (--bios) it comes up with no EFI runtime and Limine's
# BIOS stage on the target disk's MBR path. The BIOS case is the one only real
# hardware covered before — the base install already proved the MBR boots (the
# install phase waits for SSH after the auto-reboot), and this pins down that
# the right bootloader was installed and the machine really is in BIOS mode.
#
# Runs against the base image, so it inherits whatever firmware that base was
# installed under: `./test/integration <iso> firmware-boot` (UEFI) or
# `./test/integration <iso> firmware-boot --bios`.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

verify_firmware_boot() {
  log "Booting the installed base image ($FIRMWARE) to check its bootloader"
  start_vm_from_base
  wait_for_ssh "$BOOT_TIMEOUT"

  check "installed system is reachable (it booted, not the install medium)" \
    ssh_guest "test ! -e /run/archiso"

  ssh_sudo "find /boot -maxdepth 3 -print" >"$RUN_DIR/boot-tree.txt" 2>/dev/null || true

  # /boot is a root-only FAT mount, so its contents are checked with sudo.
  if [[ $FIRMWARE == bios ]]; then
    check "booted in legacy BIOS mode (no EFI runtime)" \
      ssh_guest "test ! -d /sys/firmware/efi"
    check "Limine BIOS stage is installed under /boot" \
      ssh_sudo "test -f /boot/limine/limine-bios.sys"
    check "Limine's boot code is in the disk's MBR" \
      ssh_sudo "dd if=/dev/vda bs=512 count=2048 2>/dev/null | grep -qa -i limine"
    # Note: the install also drops EFI artifacts under /boot/EFI (a UEFI-machine
    # fallback); they are inert under BIOS, so their presence is not asserted
    # either way. What matters is that the machine booted via the BIOS/MBR path,
    # which the checks above establish.
  else
    check "booted in UEFI mode (EFI runtime present)" \
      ssh_guest "test -d /sys/firmware/efi"
    # UEFI installs boot through systemd-boot, the loader Secure Boot needs,
    # unless the ISO had no omarchy-boot-systemd or was told to keep Limine
    # (OMARCHY_ISO_BOOT_LOADER=limine), as a shipped release ISO may be.
    local loader
    loader=$(installed_boot_loader)
    if [[ $loader == "limine" ]]; then
      check "a Limine EFI binary is on the ESP" \
        ssh_sudo "test -e /boot/EFI/limine/limine_x64.efi -o -e /boot/EFI/BOOT/BOOTX64.EFI"
      check "efibootmgr has a Limine entry" \
        ssh_sudo "efibootmgr | grep -qi limine"
      capture_console "success-firmware-$FIRMWARE"
      return
    fi
    check "systemd-boot is on the ESP" \
      ssh_sudo "test -s /boot/EFI/systemd/systemd-bootx64.efi -a -s /boot/EFI/BOOT/BOOTX64.EFI"
    check "efibootmgr has an Omarchy Boot entry, first in the boot order" \
      ssh_sudo "efibootmgr | awk '/^BootOrder:/ { split(\$2, order, \",\") } /Omarchy Boot/ { sub(/^Boot/, \"\", \$1); sub(/\\*\$/, \"\", \$1); entry = \$1 } END { exit !(entry != \"\" && order[1] == entry) }'"
    check "systemd-boot started this boot" \
      ssh_sudo "bootctl status 2>/dev/null | grep -q 'Product: systemd-boot'"
    check "the boot store is mounted and the switch state is active" \
      ssh_sudo "findmnt -n /var/lib/omarchy/boot >/dev/null && grep -qx phase=active /var/lib/omarchy/boot/state"
  fi

  capture_console "success-firmware-$FIRMWARE"
}

# ---------------------------------------------------------------------- main

verify_firmware_boot
finish
