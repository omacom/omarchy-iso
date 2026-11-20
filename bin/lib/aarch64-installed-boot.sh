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

# Follow the install run only when the installer rebooted (QEMU's SHUTDOWN
# reason is guest-reset) and the disk holds data. Closing the window is
# host-ui, and a guest poweroff is guest-shutdown: both stop, even if the
# installer had already written the disk. An empty reason (QMP never
# answered) stops too; running the launcher again sees the disk and boots
# the plain device directly.
aarch64_should_relaunch() {
  local reason=$1
  [[ $reason == guest-reset ]] && disk_written
}

# QEMU has returned. A reader that was connected exits when QEMU closes the
# socket, which has already happened. A reader that never got a socket is
# still in its connect loop (30s). Reap the finished one immediately and stop
# the one that is still waiting, so a QEMU that fails to start does not sit
# there for the connect timeout.
aarch64_reap_qmp_reader() {
  local pid=$1 i state
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      return 0
    fi
    state=$(ps -o state= -p "$pid" 2>/dev/null || true)
    state=${state//[[:space:]]/}
    if [[ -z $state || $state == Z* ]]; then
      wait "$pid" || true
      return 0
    fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" || true
}
