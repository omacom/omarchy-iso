# Raspberry Pi 4 bring-up

This draft extends the single aarch64 installer for the Pi 4 Model B. It needs the matching `aarch64-raspberrypi` runtime changes and `raspberrypi-4-support` package, plus `linux-omarchy` with the Pi 4 kernel configuration and device tree. Those changes must be built and published together before the normal channel can build this ISO. Pi 5 is not included.

## Simple setup: microSD boot, USB SSD installation

This is the proposed setup flow for the first Pi 4 beta, not an available download today. Before publishing it as an installation guide, the release must supply a tested Pi 4 firmware-card image, a matching aarch64 installer ISO, verification files and the required firmware settings. None of those Pi-qualified release artifacts is supplied by this source patch.

Use a Pi 4 Model B with 4GB or 8GB RAM, a microSD card for boot firmware, a USB installer stick, a wired keyboard and a suitable power supply. An external USB 3.0 SSD is recommended for the main installation; the microSD remains inserted for booting.

1. Download the matching firmware-card image and aarch64 installer ISO named in the Pi release notes. Verify the supplied checksums and signatures before writing either medium.
2. In Raspberry Pi Imager, select **Use custom**, choose the supplied firmware-card disk image and write it to the microSD. Check the selected device: writing an image erases it. The upstream PFTF firmware ZIP is an archive to extract, not a disk image to flash; a generic Omarchy ISO is not a replacement for the Pi firmware-card image.
3. Write the installer ISO to a separate USB stick using the normal [ISO instructions](README.md#get-omarchy).
4. Insert the microSD, connect the installer stick and SSD, and connect the SSD to a blue USB 3.0 port. Attach the display and keyboard, then power on. Use the release's firmware settings and select the USB installer in the UEFI boot menu if needed.
5. Follow the installer and select the external SSD as the target. A full-disk installation erases that SSD. After installation, remove the USB installer stick, leave the firmware microSD and SSD connected, and reboot. Unlock the encrypted installation with the password chosen during setup.

Keeping the UEFI files and installed system on one 128GB microSD is technically possible. The Pi's initial EEPROM bootloader remains on the board. This installer does not yet implement or qualify that single-card layout; it keeps firmware media separate from the target.

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
