#!/bin/bash
# The live ISO must boot from a Ventoy stick, in both of Ventoy's modes and
# on a Mac, without waiting in its initramfs.
#
# Ventoy keeps the ISO as a file on its exFAT partition. In normal mode it
# reads the ISO's grub.cfg as text, adds its hook to every initramfs named
# there by a literal path, and chainloads the ISO's own GRUB; the hook maps
# the ISO to /dev/mapper/ventoy. A path with a variable in it gets no hook,
# and the live system cannot find its medium: 4.5.0rc3 loaded
# initramfs-${live_kernel}.img and dropped to a shell behind the splash. In
# GRUB2 mode Ventoy's own GRUB runs the ISO's menu and adds the hook to
# whatever it loads. A Mac boots linux-t2, which grub.cfg picks from the
# firmware's maker, so its initramfs needs the hook too.
#
# The stick comes from bin/omarchy-iso-test-ventoy-disk, which needs root
# for its loop device and mount: CI makes it on the runner before the test
# container starts and passes it in as OMARCHY_INTEGRATION_VENTOY_DISK.
# Ventoy boots this way only under UEFI here. The cidata drive gives root
# SSH on the live system; the install it starts goes to /dev/vda, never the
# stick.

export OMARCHY_INTEGRATION_FIRMWARE=uefi

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

VENTOY_DISK="${OMARCHY_INTEGRATION_VENTOY_DISK:-$RUN_DIR/ventoy.img}"
# When the live root's PID 1 may start, in seconds after the kernel: the
# 30 s wait put it past 30.
MAX_INITRAMFS_SECONDS=15

# The kernel came from the ISO's own GRUB: its command line was read and lacks
# Ventoy's rdinit=, and Ventoy did not fail to chainload on the way.
chainloaded() {
  [[ -s $1 ]] && ! grep -qF "rdinit=/vtoy/vtoy" "$1" && ! grep -qaF "cannot load image" "$2"
}

boot_from_ventoy() {
  local mode="$1" disk="$RUN_DIR/scratch-$1.qcow2" started_us
  local smbios=("${LIVE_CIDATA_SMBIOS[@]}") cmdline="$RUN_DIR/cmdline-$1.txt"
  # grub.cfg boots linux-t2 where the firmware names Apple Inc. as the maker.
  [[ $mode == mac ]] && smbios=(-smbios "type=1,serial=ds=nocloud,manufacturer=Apple Inc.")

  qemu-img create -f qcow2 "$disk" "${DISK_GB}G" >/dev/null
  cp "$OVMF_VARS_TEMPLATE" "$RUN_DIR/OVMF_VARS-$mode.4m.fd"
  ACTIVE_OVMF="$RUN_DIR/OVMF_VARS-$mode.4m.fd"

  log "Booting the ISO from a Ventoy stick in $mode mode"
  # snapshot=on: Ventoy writes nothing the next boot should see.
  start_vm "$disk" "$RUN_DIR/serial-$mode.log" \
    -device qemu-xhci,id=xhci \
    -drive "file=$VENTOY_DISK,format=raw,if=none,id=ventoy,snapshot=on" \
    -device usb-storage,bus=xhci.0,drive=ventoy,removable=on,bootindex=0 \
    -drive "file=$CIDATA_IMG,format=raw,if=none,id=cidata" \
    -device usb-storage,bus=xhci.0,drive=cidata \
    "${smbios[@]}"

  # Ventoy's list holds the one ISO, selected. r switches to GRUB2 mode;
  # Enter boots, with no second menu (bin/omarchy-iso-test-ventoy-disk).
  check "Ventoy lists the ISO ($mode)" wait_for_screen "ventoy.net" 120
  if [[ $mode == grub2 ]]; then
    press r
    # Ventoy marks the mode on its menu in red, "GRUB2 Mode", which
    # tesseract can read as "GRUBZ".
    check "Ventoy switched to GRUB2 mode" wait_for_screen "grub. mode" 30
  fi
  capture_console "ventoy-menu-$mode"
  press ret

  if wait_for_live_root_ssh 300; then
    ssh_live_root "cat /proc/cmdline" >"$cmdline" 2>/dev/null || true
    started_us=$(ssh_live_root "systemctl show -p UserspaceTimestampMonotonic --value" 2>/dev/null | tr -d '\r')
    log "Live root's PID 1 started ${started_us:-?} µs after the kernel ($mode mode)"
    log "Live medium ($mode mode): $(ssh_live_root "findmnt -no SOURCE /run/archiso/bootmnt" 2>/dev/null)"
    check "the live system found the ISO at /dev/mapper/ventoy ($mode mode)" \
      ssh_live_root '[ "$(findmnt -no SOURCE /run/archiso/bootmnt)" = /dev/mapper/ventoy ]'
    # Ventoy's own GRUB adds rdinit=/vtoy/vtoy to the kernel's command line;
    # the ISO's GRUB, which normal mode chainloads, does not. A stick whose
    # ventoy_x64.efi cannot load falls back to Ventoy's GRUB with "cannot
    # load image" on the console, and boots ISOs a real machine does not.
    if [[ $mode == grub2 ]]; then
      check "Ventoy's own GRUB booted the ISO's menu in GRUB2 mode" grep -qF "rdinit=/vtoy/vtoy" "$cmdline"
    else
      check "Ventoy chainloaded the ISO's own GRUB ($mode mode)" chainloaded "$cmdline" "$RUN_DIR/serial-$mode.log"
    fi
    if [[ $mode == mac ]]; then
      check "a Mac boots the live ISO on linux-t2" ssh_live_root '[[ $(uname -r) == *-t2 ]]'
    fi
    check "the live initramfs found the Ventoy medium within ${MAX_INITRAMFS_SECONDS} s in $mode mode (PID 1 at ${started_us:-?} µs)" \
      test "${started_us:-999999999}" -lt $((MAX_INITRAMFS_SECONDS * 1000000))
  else
    check "the live ISO boots from Ventoy in $mode mode" false
  fi
  capture_console "ventoy-$mode"
  stop_vm
}

[[ -f $SSH_KEY ]] || ssh-keygen -t ed25519 -N "" -q -C "omarchy-integration" -f "$SSH_KEY"
detect_packages
build_cidata

if [[ ! -f $VENTOY_DISK ]]; then
  log "Making a Ventoy stick with ${ISO##*/}"
  "$ROOT/bin/omarchy-iso-test-ventoy-disk" "$ISO" "$VENTOY_DISK"
fi

boot_from_ventoy normal
boot_from_ventoy grub2
boot_from_ventoy mac
# A stick made here holds a copy of the ISO; one passed in is the caller's.
[[ -n ${OMARCHY_INTEGRATION_VENTOY_DISK:-} ]] || rm -f "$VENTOY_DISK"
finish
