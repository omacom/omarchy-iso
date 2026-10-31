#!/usr/bin/env bash
# Every frame of the live boot renders as it should, from the boot loader to
# the greeter. test/boot-render boots the ISO as a USB stick through its
# firmware and boot loader and checks each frame against what the boot should
# show: the logo in the greeter's place drawn cell for cell, nothing else lit,
# no dark stretch between the first logo and the greeter, the greeter's text
# centred. Under BIOS on QEMU's standard VGA at 1280x800, whose driver (bochs)
# takes the console over from the VGA text console cleanly; under UEFI on
# ramfb, the firmware's framebuffer alone: a GPU driver taking a UEFI
# framebuffer over shows a few frames of the console's last layout in QEMU
# (test/boot-render's --device for those).
#
# Boots the ISO alone, no base image: `./test/integration <iso> boot-render`
# (UEFI) or `./test/integration <iso> boot-render --bios`.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

verify_boot_render() {
  local out="$RUN_DIR/boot-render" display=(--device ramfb)
  [[ $FIRMWARE == bios ]] && display=(--device VGA --resolution 1280x800)
  log "Checking every frame of the live boot to the greeter ($FIRMWARE, ${display[*]})"
  check "every frame from the boot loader to the greeter renders as it should" \
    "$ROOT/test/boot-render" "$ISO" --firmware "$FIRMWARE" "${display[@]}" --out "$out"
  sed -n '/^PROBLEMS/,$p' "$out/report.txt" 2>/dev/null || true
}

verify_boot_render
finish
