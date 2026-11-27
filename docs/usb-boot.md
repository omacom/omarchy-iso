# Booting the ISO from a USB stick

The x86_64 ISO has a valid GPT since #543 (4.6.0). It boots in UEFI mode from
any stick we have tried. In legacy (BIOS or CSM) mode, some older firmware
refuses it. Boot those machines in UEFI mode.

## The layout

A hybrid ISO is a CD image (ISO 9660 with an El Torito boot catalog) and a
disk image at once. The first sectors of the file decide how firmware sees it
when it is written to a stick:

| Layout | MBR | GPT | Used by |
|---|---|---|---|
| Protective MBR | one `0xEE` entry | valid | Fedora, openSUSE Tumbleweed |
| Protective MBR plus a bootable dummy | `0xEE` entry and an active `0x00` entry | valid | Ubuntu since 20.10, Omarchy since 4.6.0 |
| MBR first, GPT behind it | real MBR entries, no `0xEE` | not valid to firmware | Arch, Debian, CachyOS, Pop!_OS, Omarchy before 4.6.0 |

The third layout comes from mkarchiso's `-isohybrid-gpt-basdat`. `blkid`
reads it as `dos`. The first two read as `gpt`. The build refuses an x86_64 ISO
that `blkid` doesn't read as `gpt` (`builder/iso-partition-table.sh`).

## Why the layout matters

A USB device reports itself as removable or fixed (the RMB bit of its SCSI
INQUIRY reply, `RM` in `lsblk`). Ordinary flash drives report removable. Fast
sticks with SSD controllers and portable SSDs report fixed, for example the
SanDisk Extreme PRO USB-C (SDCZ890), the Kingston DataTraveler Max and the
Samsung T7.

Firmware looks for a GPT first, then El Torito, then the MBR. Without a valid
GPT it finds only the CD image. Some firmware offers no CD image on a device
that reports a fixed disk, so the stick is missing from its boot menu
(omarchy#10734).

## What we measured

An MSI MAG Z690 Tomahawk (AMI UEFI) with a SanDisk Extreme PRO USB-C, which
reports fixed. Each ISO was written to the stick, read back, and picked from
the firmware's boot menu:

| ISO | Layout | In the boot menu | Boots |
|---|---|---|---|
| Omarchy 4.6.0-rc1 | protective + dummy | yes | yes |
| Fedora Workstation 45 | protective | yes | yes |
| openSUSE Tumbleweed (20261125) | protective | yes | yes |
| Ubuntu 26.04.1 | protective + dummy | yes | yes |
| Ubuntu 26.10 | protective + dummy | yes | yes |
| Omarchy 4.5.0 | MBR first | no | — |
| Arch 2026.11.01 | MBR first | no | — |
| Debian live 13.8.0 | MBR first | no | — |
| CachyOS 261123 | MBR first | no | — |
| Pop!_OS 24.04 | MBR first | no | — |

A Dell XPS 13 9343 (2015) in legacy mode refuses both Omarchy 4.6.0-rc1 and
Ubuntu 26.04.1 ("Selected boot device failed"). It boots both in UEFI mode. A
build without #543 boots there in legacy mode too. Ubuntu has the same table
with GRUB's MBR boot code, so the table is what this firmware rejects, not
the boot code. Reports of the same refusal exist for a ThinkPad T420 set to
legacy only, an Acer XC-603, and HP dc7700 and dc7900.

## If the stick doesn't boot

- Boot it in UEFI mode. Turn off legacy or CSM boot in the firmware setup, or
  pick the stick's "UEFI:" entry in the boot menu.
- A machine with legacy-only firmware that refuses a GPT disk can't boot the
  stick. Such firmware predates UEFI, about 2011.
- If the stick isn't in the boot menu at all on an Omarchy ISO before 4.6.0,
  and the stick is a fast one or an SSD, update to 4.6.0 or use an ordinary
  flash drive.
