# Try Omarchy — Live Desktop Preview ISO

> [!TIP]
> **Testing Status: Fully Verified on Bare-Metal Hardware (Desktop & WiFi Working)**  
> This bootable ISO builds upon John Sideserf's [`try-omarchy` branch](https://github.com/johnsideserf/omarchy-iso/tree/try-omarchy) with a critical upstream fix: enabling **NetworkManager natively at build time** to eliminate wireless driver conflicts with `systemd-networkd`.  
> **Hardware Status:** Tested and verified on physical laptop hardware — both the live Hyprland desktop session and out-of-the-box WiFi networking work cleanly!

---

## Download the ISO

Hosted with high-speed direct downloads on Hugging Face:

📦 **[Download try-omarchy.iso (5.89 GiB / 6.32 GB)](https://huggingface.co/datasets/flamingvariable/tryomarchy/resolve/main/try-omarchy.iso)**  
*(Dataset repo: [huggingface.co/datasets/flamingvariable/tryomarchy](https://huggingface.co/datasets/flamingvariable/tryomarchy))*

---

## Credits & Attribution

- **Original Architecture, Feature Design & Codebase:**  
  Designed, architected, and implemented by **John Sideserf** ([@johnsideserf](https://github.com/johnsideserf)) on the [`try-omarchy`](https://github.com/johnsideserf/omarchy-iso/tree/try-omarchy) branch of `omarchy-iso`. All core logic, including just-in-time offline mirror resolution, `omarchy-try-setup`, NVIDIA card fallback detection, and the unit test suite, are the work of John Sideserf and the Omarchy project contributors.
- **ISO Compilation, Hardware Verification & NetworkManager Fix:**  
  Tested on bare metal, fixed build-time networking, and maintained by **Aarav Tank** ([@aaravtank](https://github.com/aaravtank)).

---

## What is "Try Omarchy"?

"Try Omarchy" lets you boot the Omarchy ISO on the machine you are about to wipe and experience the real Hyprland desktop on your actual hardware before committing — the x86 counterpart of the `try-omarchy` Mac app.

- **Ephemeral live session** running entirely in RAM (overlayfs).
- Installed **just-in-time** directly from the ISO's offline bundled mirror (`/var/cache/omarchy/mirror/offline`).
- Does not modify your existing drives until you explicitly choose to install.
- Exiting or rebooting leaves no persistent changes behind.

---

## System Requirements

- **Processor:** Standard 64-bit x86 processor (`x86_64`) or Intel-based MacBook (including T2 security chip models).
- **RAM:** Minimum **4 GiB** of RAM (required for the in-memory live overlay).
- **USB Drive:** At least **8 GB** USB flash drive.

---

## Flashing the ISO to USB

### On Windows (using Rufus)
1. Download and open [Rufus](https://rufus.ie/).
2. Select your USB drive under **Device**.
3. Under **Boot selection**, select `try-omarchy.iso`.
4. Click **START**.
5. **IMPORTANT:** When prompted with the dialog asking for *ISO Image mode* vs. *DD Image mode*, select:
   👉 **Write in DD Image mode**.  
   *(Archiso requires a raw 1:1 bit copy to find the offline package mirror during boot).*

### On Linux / macOS (using `dd`)
```bash
# Identify your USB drive (e.g. /dev/sdX on Linux or /dev/rdiskN on macOS)
sudo dd if=try-omarchy.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

### Using Ventoy
Simply copy `try-omarchy.iso` directly onto your Ventoy USB drive.

---

## How to Boot & Try Omarchy

1. Plug the USB into your PC / laptop.
2. Power on and open your BIOS/UEFI boot menu (typically `F12`, `F11`, `F8`, `F2`, or `Option/Alt` on Intel Macs).
3. Select your USB drive in UEFI mode.
4. From the boot menu, launch Omarchy.
5. In the installer dashboard / welcome screen, select **"Try Omarchy"**.
6. The system will unpack the desktop into memory and launch the live Hyprland session!

---

## Image Specifications & Integrity Verification

- **ISO Filename:** `try-omarchy.iso`
- **File Size:** `6,328,778,752 bytes` (5.89 GiB / 6.32 GB)
- **Kernel:** `linux-t2` (universal x86_64 support + Intel T2 Mac support)
- **Squashfs Superblock:** SquashFS 4.0, zstd-19 (`airootfs.sfs`)
- **SHA-256 Checksum:**
  ```text
  23B7613A7F56A6AA0AC666144F482AA182690C4E018D6F7B11596CD61420A4D0
  ```

### Verify Integrity Before Booting

#### Windows (PowerShell):
```powershell
Get-FileHash .\try-omarchy.iso -Algorithm SHA256
```

#### Linux / macOS:
```bash
sha256sum try-omarchy.iso
```

---

## License

This project is distributed under the [MIT License](LICENSE).

```text
Copyright (c) 2026 John Sideserf, Aarav Tank, and Omarchy Project Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```
