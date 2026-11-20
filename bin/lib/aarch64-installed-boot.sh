#!/bin/bash
#
# How bin/omarchy-iso-boot chooses the aarch64 display, and when the install
# run should be followed by a boot of the installed system.
#
# virtio-gpu-gl draws the live ISO. An installed system stays dark on it
# ("Display output is not active"); plain virtio-gpu shows it. One QEMU keeps
# its devices across a guest reboot, so the install run exits at that reboot
# and a second QEMU starts with the plain device.

# A fresh qcow2 has no data extents. qemu-img writes "data": true once the
# installer has put something on the disk.
disk_written() {
  qemu-img map -U --output=json "$DISK" 2>/dev/null | grep -q '"data": true'
}

# gl while the disk is still empty, plain once it holds an install (or when
# OMARCHY_VM_GL=0 asked for the plain device the whole way).
aarch64_boot_mode() {
  if [[ ${OMARCHY_VM_GL:-1} == "0" ]] || disk_written; then
    printf '%s\n' plain
  else
    printf '%s\n' gl
  fi
}

# Follow the install run with a boot of the installed system only once the
# disk holds data. A window closed before the installer writes anything has
# nothing to boot.
aarch64_should_relaunch() {
  disk_written
}
