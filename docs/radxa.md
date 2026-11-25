# Omarchy on Radxa Orion O6 and Orion O6N

Radxa Orion O6 and Orion O6N are aarch64 desktop boards built on the CIX CD8180 (Sky1) SoC with an Arm Immortalis-G720 GPU. Omarchy runs on both from the standard `aarch64` image with `linux-omarchy` and a board-scoped hardware drop-in (`install/hardware/radxa/orion.sh` in `omarchy`).

## Firmware prerequisites

Update the board to Radxa EDK2 BIOS `1.3.3` or newer on Orion O6 (`1.3.1` or newer on Orion O6N) before booting the installer:

- **Boot mode:** ACPI with SCMI enabled, SPCR serial console redirect disabled.
- **CPU and memory clocks:** keep the firmware's **Vendor** defaults (`2.6 GHz` CPU, `5500 MT/s` LPDDR5). Raising the UEFI frequencies (for example `3.2 GHz` CPU or `6400 MT/s` DRAM) causes deterministic userspace segfaults under load.

## What is different from stock Omarchy

- **Kernel:** `linux-omarchy` (`pkgbuilds/linux-omarchy-aarch64` in `omarchy-pkgs`), carrying CIX Sky1 SoC, SCMI, Linlon display, Trilin DisplayPort, built-in Cadence GPIO/fixed regulator/USB-C/DP combo PHY (`phy_cix_usbdp`) and RTS5453 PD mux, PCIe, I2C, HDA/I2S audio and thermal drivers alongside upstream Panthor Mali-G720 support.
- **Early live display:** because built-in `phy_cix_usbdp` and `rts5453` reconfigure the Type-C combo PHY during early kernel init (dropping UEFI GOP's link), the live initramfs bundles `pwm_bl`, `linlon_dp` and `trilin_dpsub` via `omarchy-radxa-orion-live`. Only exact SMBIOS matches (`Radxa Orion O6` and `Radxa Orion O6N`) load them early via `earlymodules=pwm_bl,linlon_dp,trilin_dpsub` in GRUB; other ARM machines boot unchanged.
- **GPU firmware and Vulkan:** `arm/mali/arch12.8/mali_csffw.bin` stays in the live root so `panthor` initializes cleanly once `linlon_dp` claims the display, and `install/hardware/vulkan.sh` installs `vulkan-panfrost` (`panvk`) from the offline repository when it sees a Mali DRM device or enabled ACPI `CIXH5000` GPU.
- **Audio routing:** `omarchy-settings` ships ALSA UCM2 profiles for `cix_sky1` (5x DisplayPort/HDMI audio outputs with `HDMI/DP,pcm=0..4 Jack` hotplug detection) and `cix-ipbloq-hda` (ALC269/ALC256 3.5mm headset, front mic, line-out and speaker header), paired with `/etc/wireplumber/wireplumber.conf.d/50-cix-sky1-audio.conf` for clean node labels and default-sink priority.
- **Kernel parameters:** `clk_ignore_unused cma=512M` on both live boot (via SMBIOS-gated GRUB options, alongside `fbcon=nodefer` so `fbcon` modesets `linlon_dp` immediately after the combo PHY switches to DP mode) and the installed system (via `omarchy-boot-cmdline set radxa-orion`, where Plymouth modesets in the UKI).
- **Installed boot:** `install/hardware/radxa/orion.sh` writes `/etc/mkinitcpio.conf.d/radxa-orion.conf` (`pwm_bl? linlon_dp? trilin_dpsub?`) and registers the kernel parameters with `omarchy-boot-cmdline`, so the installer and subsequent kernel updates build an Orion UKI under `systemd-boot` or Limine with Plymouth and LUKS2 disk unlock on the display.

## Installing

1. Write the standard `aarch64` image to a USB stick of 8 GB or more, replacing `/dev/sdX` with the stick (check with `lsblk`; everything on it is erased):

   ```bash
   sudo dd if=omarchy-<date>-aarch64-local.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. Plug the stick into the board, power it on, open the EDK2 boot manager and pick the USB stick. It boots straight into the installer on DisplayPort/HDMI.
3. Complete the installer as usual, including full-disk encryption, remove the stick when prompted and reboot into the Omarchy desktop.

## Boot menus

The **USB stick** boots the installer directly without waiting at a menu. Press Esc while GRUB starts for:

- **N1x recovery shell (hardware probe, no installer)**.
- **Radxa Orion O6 / O6N serial debug (ttyAMA0, no splash)** — shown on `Radxa Orion O6` and `Radxa Orion O6N`, enabling PL011 UART2 (`ttyAMA0,115200n8`, `earlycon=pl011,0x040d0000`) with Plymouth disabled for serial diagnostics.

## Building the image

Builds run natively on an aarch64 host with Docker, using the plain `aarch64` image command:

```bash
# From published edge packages and local checkouts
bin/omarchy-iso-make --arch aarch64 --edge --local-source ../omarchy ../omarchy-pkgs

# With a local checksummed linux-omarchy package bundle ahead of the channel repo
bin/omarchy-iso-make --arch aarch64 --edge \
  --package-dir /path/to/checksummed-kernel-bundle \
  --local-source ../omarchy ../omarchy-pkgs
```
