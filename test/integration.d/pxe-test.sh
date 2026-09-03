#!/bin/bash
#
# The ISO's PXE path really boots and really installs: PXELINUX routed into
# the PXE menu (whichsys.c32) brings up a live environment whose medium is an
# NBD export, the pre-flight gate hashes the multi-GB root image across the
# network, and the unattended cidata install streams it to disk — the LAN
# install the pinned copytoram=n on the PXE entries exists to keep working.
#
# Mechanics: no boot medium is attached to the VM. QEMU's user-mode network
# stack plays the LAN — its built-in TFTP server hands iPXE lpxelinux.0 and
# the boot files straight out of the ISO's own /boot/syslinux and /arch/boot
# trees, and qemu-nbd serves the ISO itself as the export the initramfs dials
# back to (the guest reaches the host at 10.0.2.2, which is also what the
# archiso_pxe_common hook resolves ${pxeserver} to from the DHCP handshake).
# The one file the ISO does not carry is pxelinux.cfg/default — PXELINUX's
# config entry point, which every real deployment writes too; ours is a
# one-line INCLUDE of the ISO's own syslinux.cfg.
#
# Two fixed conditions, both inherent to the boot path under test:
#   - BIOS only: the PXE config is syslinux and the ISO has no UEFI netboot
#     path, so the scenario forces SeaBIOS regardless of the runner's flag.
#   - Port 10809: archiso_nbd_srv carries an address only (${pxeserver}), so
#     nbd-client always dials the well-known NBD port; qemu-nbd must own it
#     on the host loopback for the duration of the run.
#
# Boots the ISO itself (over the wire), so it needs no base image.

export OMARCHY_INTEGRATION_FIRMWARE=bios

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
# The TFTP root and NBD export come from the same rig bin/omarchy-iso-boot-pxe
# uses, so what this scenario proves is exactly what the hands-on tool boots.
source "$ROOT/bin/lib/netboot.sh"

TFTP_ROOT="$RUN_DIR/tftp"

pxe_cleanup() {
  local status=$?
  [[ -n $NBD_PID ]] && kill "$NBD_PID" 2>/dev/null || true
  cleanup
  return $status
}
trap pxe_cleanup EXIT

nbd_dialed() {
  [[ -n $(ss -Htn "sport = :$NBD_PORT") ]]
}

# -------------------------------------------------------------------- phases

netboot_into_installer() {
  [[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
  detect_packages
  build_cidata

  qemu-img create -f qcow2 "$RUN_DIR/disk.qcow2" 40G >/dev/null

  log "Netbooting with no attached install medium (headless)"
  NETDEV_EXTRA=",tftp=$TFTP_ROOT,bootfile=/boot/syslinux/lpxelinux.0"
  NIC_EXTRA=",bootindex=2"
  start_vm "$RUN_DIR/disk.qcow2" "$RUN_DIR/serial.log" \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,drive=cidata

  # Unlike the ISO's boot menu, the PXE menu has no auto-boot timeout, so
  # commit the highlighted default — the NBD entry leads the list.
  wait_for_screen "NBD" 300
  capture_console "success-pxe-01-menu"
  press ret

  # The kernel and initramfs now cross the TFTP link, which is slow, and the
  # boot shows no OCR-able text until much later. The first hard evidence the
  # initramfs is up is it dialing the NBD export — gate on that from the host
  # side before driving the console.
  log "Waiting for the initramfs to dial the NBD export"
  local waited=0
  until nbd_dialed; do
    if ! vm_running; then
      echo "VM exited before connecting to the NBD export" >&2
      return 1
    fi
    if ((waited >= 900)); then
      capture_console "failure-nbd-connect-timeout"
      echo "Timed out waiting for the guest to dial the NBD export" >&2
      return 1
    fi
    sleep 5
    ((waited += 5))
  done
  log "NBD connection established"

  bootstrap_live_root_ssh
}

assert_nbd_medium() {
  # The NBD hook hands /dev/nbd0 to the mount handler, but the entry's
  # archisosearchuuid makes the archiso hook re-resolve by UUID — and on an
  # isohybrid image that lands on the partition (nbd0p1), the same way a USB
  # stick boots from sdX1. Either is the NBD transport.
  check "live medium is NBD-backed" \
    ssh_live_root "findmnt -no SOURCE /run/archiso/bootmnt | grep -qxE '/dev/nbd0(p[0-9]+)?'"
  check "kernel cmdline pinned copytoram=n" \
    ssh_live_root "grep -q 'copytoram=n' /proc/cmdline"
  check "root image stream is reachable on the netboot medium" \
    ssh_live_root "test -f /run/archiso/bootmnt/arch/x86_64/omarchy-root.btrfs.zst"
  # The mirror is a directory on the same medium, bind-mounted over the path
  # pacman's [offline] repo points at. Over the wire that is an ISO9660 read over
  # NBD, which nothing else here exercises -- and an install that cannot
  # read a package is exactly as dead as one that cannot read the root image.
  check "offline mirror is reachable on the netboot medium" \
    ssh_live_root "test -f /run/archiso/bootmnt/arch/x86_64/mirror/offline.db.tar.gz"
  check "the offline mirror is mounted from it" \
    ssh_live_root "mountpoint -q /var/cache/omarchy/mirror/offline"
  check "packages are readable through the mounted mirror" \
    ssh_live_root "test -s /var/cache/omarchy/mirror/offline/offline.db && ls /var/cache/omarchy/mirror/offline/*.pkg.tar.zst >/dev/null"
}

assert_installed_system() {
  check "installed system is reachable (not the live medium)" \
    ssh_guest "test ! -e /run/archiso"
  check "booted in legacy BIOS mode" \
    ssh_guest "test ! -d /sys/firmware/efi"

  ssh_sudo "cat /var/log/omarchy-install.log" >"$RUN_DIR/omarchy-install.log" 2>/dev/null || true
}

# ---------------------------------------------------------------------- main

log "Assembling the TFTP root from the ISO's own netboot files"
assemble_tftp_root "$ISO" "$TFTP_ROOT"
log "Serving the ISO as NBD export 'archiso' on 127.0.0.1:$NBD_PORT"
serve_nbd "$ISO"
netboot_into_installer
assert_nbd_medium
wait_for_unattended_install pxe
assert_installed_system
finish
