#!/usr/bin/env bash
# Every frame of the live boot renders as it should, from the boot loader to
# the greeter. test/boot-render boots the ISO as a USB stick through its
# firmware and boot loader and checks each frame against what the boot should
# show: the logo in the greeter's place drawn cell for cell, nothing else lit,
# no dark stretch between the first logo and the greeter, the greeter's text
# centred. Under BIOS on QEMU's standard VGA at 1280x800, whose driver (bochs)
# takes the console over from the VGA text console cleanly; under UEFI on
# ramfb, the firmware's framebuffer alone.
#
# Under UEFI a second boot is on the standard VGA, whose driver takes the
# firmware's framebuffer over under the logo, as a laptop's GPU driver does:
# the console is frozen for it (omarchy-console-logo-redraw). Under BIOS a
# second boot holds the GPU driver back until after the login.
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
  if [[ $FIRMWARE != bios ]]; then
    log "Checking it again with a GPU driver taking the firmware's framebuffer over"
    check "every frame renders as it should as a GPU driver takes the firmware's framebuffer over" \
      "$ROOT/test/boot-render" "$ISO" --firmware "$FIRMWARE" --device VGA --resolution 1280x800 --out "$out-takeover"
    sed -n '/^PROBLEMS/,$p' "$out-takeover/report.txt" 2>/dev/null || true
    return 0
  fi

  # A GPU driver that loads after the login, as one may on a slow machine: a
  # udev rule passed in as a systemd credential holds it back four seconds.
  # The VGA logo stays up until the driver's framebuffer comes and the logo
  # is laid out again there, and the login's wait for udev keeps the
  # configurator back until then.
  local rule='ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x03*", RUN+="/usr/bin/sleep 4"'
  log "Checking it again with the GPU driver loading after the login"
  check "every frame renders as it should with a GPU driver that loads after the login" \
    "$ROOT/test/boot-render" "$ISO" --firmware bios "${display[@]}" --out "$out-late-driver" --qemu-arg=-smbios \
    --qemu-arg="type=11,value=io.systemd.credential.binary:udev.rules.71-omarchy-late-gpu=$(printf '%s\n' "$rule" | base64 -w0)"
  sed -n '/^PROBLEMS/,$p' "$out-late-driver/report.txt" 2>/dev/null || true
}

verify_boot_render
finish
