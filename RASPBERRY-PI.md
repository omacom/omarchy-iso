# Raspberry Pi 4 bring-up

This draft extends the single aarch64 installer for the Pi 4 Model B. It needs the matching `aarch64-raspberrypi` runtime changes and `raspberrypi-4-support` package, plus `linux-omarchy` with the Pi 4 kernel configuration and device tree. Those changes must be built and published together before the normal channel can build this ISO. Pi 5 is not included.

## Firmware boundary

A Pi does not boot this ISO through its native EEPROM firmware. Prepare separate Pi 4 UEFI firmware media and select Device Tree mode. ACPI-only mode does not expose the graphics devices needed here. The firmware must pass a suitable Pi 4 tree with VC4/V3D enabled; the proposed kernel package includes `/boot/dtbs/linux-omarchy/broadcom/bcm2711-rpi-4-b.dtb`. A working UEFI release, its settings and the handoff of that mainline tree still need board validation. The [firmware documentation](https://github.com/tianocore/edk2-platforms/blob/master/Platform/RaspberryPi/RPi4/Readme.md) warns about Device Tree boot and USB/DMA limitations and documents its default 3GB RAM cap; full 4GB/8GB memory availability must be checked as part of qualification. Do not assume the firmware's bundled downstream tree works with this kernel.

The USB installer keeps GRUB for live boot and Limine/UKIs on the installed target. It checks UEFI, the exact Pi 4 Device Tree compatible token and the V3D render device before releasing disk holders or preparing the target. Keep the UEFI media separate from the installation target. No script in this change updates it or flashes the EEPROM.

Maintainers need to decide whether requiring separate UEFI media is acceptable for initial Pi support, or whether a managed bootstrap should accompany the image. That bootstrap is outside this patch.

## Build and install

`builder/build-iso.sh` installs `raspberrypi-4-support` in the live aarch64 root and requires the runtime's Pi platform list. Its existing platform-list composition puts `raspberrypi-4-support` and its dependencies in the offline mirror and adds them to the target only on a Pi. `builder/archiso-aarch64-mkinitcpio.sh` includes the Pi firmware, PCIe and SD host modules so the USB or SD root can be reached. These modules are required: a kernel without Pi support must fail the image build.

Before the packages are published, use the existing local-source and package-bundle workflow with the Pi kernel and tooling built from the companion recipes:

```bash
./bin/omarchy-iso-make --arch aarch64 --local-source ../omarchy-upstream-pi ../omarchy-pkgs-pi --package-dir /absolute/path/to/pi-packages
```

The bundle contains the rebuilt `linux-omarchy` and `raspberrypi-4-support` archives. It does not alter the repository or signing rules on the installed system. Omarchy keeps its existing disk layout, owner setup, encryption choices and snapshot machinery. The Pi package supplies setup and update checks through the runtime's lifecycle dispatcher.

## Validation still needed

This is not yet a boot-qualified Pi installer. Kernel configuration and device-tree compilation, package tests and installer fixtures cannot replace a complete kernel/ISO build or board tests. Test live boot, installation, installed boot and update/reboot on both 4GB and 8GB Pi 4 Model B boards, followed by HDMI/audio, Wi-Fi/Bluetooth, USB, power, media decoding, encryption and snapshot restore. The community port's successful boot applies to its different firmware/U-Boot/ext4 image.
