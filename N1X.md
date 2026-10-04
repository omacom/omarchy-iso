# Omarchy on the NVIDIA N1x laptop

The NVIDIA N1x is an aarch64 laptop platform with an on-package Blackwell GPU. Omarchy runs on it with its own kernel and a few platform settings. It is validated on the ASUS ProArt P14 (H7407BA); the Dell XPS 16 (DX16263), the first N1x laptop, uses the same image.

There are two images:

| Image | File name | Use it for |
| --- | --- | --- |
| Normal | `omarchy-<date>-aarch64-n1x-local.iso` | Everyday installs. No remote access, like any Omarchy ISO; the installed system leaves sshd off. |
| Dev | `omarchy-<date>-aarch64-n1x-devssh-local.iso` | Debugging. Adds key-only SSH for the public key it was built with, on the live USB and the installed system, and verbose installer output. |

Both install the same Omarchy. Only the dev image opens remote access, so do not hand a dev image, or a machine installed from one, to anyone else.

## What is different from stock Omarchy

- **Kernel:** `linux-omarchy-n1x`, the `linux-omarchy` kernel with NVIDIA's N1x platform support and Omarchy's N1x patches (see `pkgbuilds/linux-omarchy-n1x` in omarchy-pkgs).
- **GPU:** the NVIDIA open driver from Omarchy's aarch64 repository, loaded early so the disk passphrase prompt and the desktop are drawn by the GPU. On the Dell's pre-release firmware (0.x) the driver stays unloaded and the desktop renders in software.
- **Console:** every boot entry carries `console=tty0 acpi=nospcr`. Without it the firmware's serial console takes over and the screen stays black, the disk passphrase prompt included.
- **Boot splash:** Plymouth, as on every Omarchy machine, with the panel lit for the passphrase prompt.
- **Sleep:** suspend to idle. The firmware's deep sleep returns at once.
- **USB4 (ProArt P14):** docks, displays and PCIe devices such as 10 GbE adapters work through the USB4 ports. A dock or adapter plugged in while you are logged in and unlocked is approved once, with a notification, and connects on every plug after that. One plugged in at the lock screen, or already connected at boot the first time, stays without its PCIe devices (a dock's Ethernet, for one) until it is plugged in again after unlocking. The three USB4 PCIe ports are kept out of runtime suspend, because a dock that comes up behind a suspended port never shows its PCIe devices; a kernel fix that wakes the port instead would give back their idle power.
- **ProArt P14:** the RAM the firmware reserves for Windows' GPU is given to Linux (about 122 GiB of 128), and the speakers get ASUS's amplifier tuning.
- **Wired and Wi-Fi together:** each interface answers ARP only for its own address (`/etc/sysctl.d/90-omarchy-arp.conf`), so a dock's Ethernet on the same network as the Wi-Fi keeps its routes and becomes the default route.
- **Packages:** everything else comes from Omarchy's aarch64 repository (`pkgs.omarchy.org/edge/aarch64`) and Arch Linux ARM. OBS Studio is not installed; it has no aarch64 build.

## Installing

1. Write the image to a USB stick of 8 GB or more, replacing `/dev/sdX` with the stick (check with `lsblk`; everything on it is erased):

   ```bash
   sudo dd if=omarchy-<date>-aarch64-n1x-local.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. Plug the stick into the laptop, power it on, open the firmware's boot menu and pick the stick. It boots straight into the installer; the internal keyboard works there.
3. Install as usual. Disk encryption is supported; you then type the passphrase at every boot.
4. Remove the stick when asked and reboot.

The first boot lands on the Omarchy login screen, drawn by the NVIDIA GPU.

## Boot menus

The **USB stick** boots the installer without showing a menu. Press Esc while it starts for:

- **Omarchy with speakup screen reader**.
- **N1x recovery shell (hardware probe, no installer)**. Records the GPU, display, input and network state to `/var/log/omarchy-n1x-live-probe.log` and leaves you at a root prompt, without touching the disk.

The **installed system** (Limine) offers:

- **linux-omarchy-n1x**, the normal desktop. It boots by default.
- **linux-omarchy-n1x-fallback**, the rescue entry. It boots the same system to a text login with the NVIDIA driver blocked and Plymouth off; use it if the desktop comes up black. It is rebuilt with every kernel update.
- **Snapshots**, once Omarchy has taken some.

`sudo omarchy-n1x-probe` records hardware and boot details to `/var/log/omarchy-n1x-probe.log` on demand.

## Dev image: remote access

The dev image carries the public key passed to `--dev-ssh` when it was built. Password and keyboard-interactive logins are refused everywhere; only that key works.

**On the live USB**, sshd starts on boot and root accepts the key. Find the address on the laptop with `ip -4 -brief address` or from your router's DHCP leases. The live system is called `omarchy-n1x-rescue`, so this also works where mDNS reaches:

```bash
ssh root@<address>
ssh root@omarchy-n1x-rescue.local
```

**On a system installed from the dev image**, sshd is enabled, port 22 is open in the firewall, and both root and the user you created accept the key.

### Removing dev access from an installed machine

```bash
sudo rm /etc/ssh/sshd_config.d/05-omarchy-n1x-dev-ssh.conf
sudo nvim /root/.ssh/authorized_keys ~/.ssh/authorized_keys   # delete the dev key
sudo systemctl disable --now sshd
sudo ufw delete allow ssh
```

## Known limitations

- **USB4 devices across suspend** are not validated yet.
- **Battery, lid and thermal readings are missing on the Dell XPS 16.** Its embedded controller uses a newer interface than NVIDIA's driver implements.
- **USB4 is only set up on the ProArt P14** until it is tested on the Dell.

## Building the images

Builds run natively on an aarch64 host with Docker, from sibling checkouts of omarchy, omarchy-pkgs and this repository. They need a platform package directory with the packages no repository publishes yet, built from omarchy-pkgs, and a `SHA256SUMS` covering them:

- `linux-omarchy-n1x` and `linux-omarchy-n1x-headers`
- `asus-proart-p14-speaker-firmware`

```bash
# Normal image
bin/omarchy-iso-make --arch aarch64 --platform n1x \
  --package-dir <platform-packages> --local-source ../omarchy-installer ../omarchy-pkgs

# Dev image: adds key-only SSH for your public key and verbose installer output
bin/omarchy-iso-make --arch aarch64 --platform n1x --dev-ssh ~/.ssh/id_ed25519.pub --debug \
  --package-dir <platform-packages> --local-source ../omarchy-installer ../omarchy-pkgs
```

The images land in `release/`. On an aarch64 host, `bin/omarchy-iso-boot` boots them in a KVM virtual machine. The VM installs Omarchy like any aarch64 machine; the N1x-specific setup only runs on N1x hardware.
