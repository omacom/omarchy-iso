# Omarchy on the NVIDIA N1x laptop

The NVIDIA N1x laptop (first seen as the Dell XPS 16 DX16263) is an aarch64
machine with an on-package Blackwell GPU. Omarchy runs on it with its own
kernel and a few platform settings. There are two images:

| Image | File name | Use it for |
| --- | --- | --- |
| Normal | `omarchy-<date>-aarch64-n1x-<version>.iso` | Everyday installs. No remote access, like any Omarchy ISO; the installed system leaves sshd off. |
| Dev | `omarchy-<date>-aarch64-n1x-<version>-dev.iso` | Bring-up and debugging. Adds key-only SSH for the development key to the live USB and the installed system, and verbose installer output. |

Both install the same Omarchy. Only the dev image opens remote access, so do
not hand a dev image, or a machine installed from one, to anyone else.

Each image has a `.sha256` file next to it. Check it before writing the USB:

```bash
sha256sum -c omarchy-<date>-aarch64-n1x-<version>.iso.sha256
```

## What is different from stock Omarchy

- **Kernel:** `linux-n1x`, NVIDIA's signed Ubuntu 7.0 kernel with two NVIDIA
  patches that make the internal keyboard and touchpad work (MediaTek I2C over
  ACPI, and a GPIO debounce fix).
- **GPU:** the NVIDIA open driver 610.57.04, loaded early. It drives the panel
  on firmware 1.0.4 and later. Updates are held at this version (see
  [Updates](#updates)). On older firmware the NVIDIA driver stays unloaded and
  the desktop renders in software.
- **Console:** every boot entry carries `console=tty0 acpi=nospcr`. Without it
  the firmware's serial console takes over and the screen stays black, the disk
  passphrase prompt included.
- **Boot splash:** off. Plymouth crashes on this machine.
- **Packages:** everything else comes from Omarchy's aarch64 repository
  (`pkgs.omarchy.org/edge/aarch64`) and Arch Linux ARM. OBS Studio is not
  installed yet; it has no aarch64 build.

## Installing

1. Write the image to a USB stick of 8 GB or more, replacing `/dev/sdX` with
   the stick (check with `lsblk`; everything on it is erased):

   ```bash
   sudo dd if=omarchy-<date>-aarch64-n1x-<version>.iso of=/dev/sdX bs=4M status=progress oflag=sync
   ```

2. Plug the stick and a USB Ethernet adapter into the laptop, power it on and
   press **F12** for the boot menu. Pick the USB stick.
3. At the USB's menu choose the first entry, **Omarchy (aarch64, arm64 UEFI)**.
   The internal keyboard works in the installer.
4. Install as usual. Disk encryption is supported; you then type the
   passphrase at every boot.
5. Remove the stick when asked and reboot.

The first boot lands on the Omarchy login screen, drawn by the NVIDIA GPU.

## Boot menus

The **USB stick** offers:

- **Omarchy (aarch64, arm64 UEFI)**, the installer.
- **Omarchy with speakup screen reader**.
- **N1x recovery shell (hardware probe, no installer)**. Records the GPU,
  display, input and network state to `/var/log/omarchy-n1x-live-probe.log`
  and leaves you at a root prompt, without touching the disk. Useful for
  checking a disk or capturing hardware details.

The **installed system** (Limine) offers:

- **linux-n1x**, the normal desktop. It boots by default.
- **N1x rescue (text console, graphics off)**. Boots the same system to a
  text login with the NVIDIA driver blocked. Use it if the desktop comes up
  black; you can log in and inspect it from there.
- **Snapshots**, once Omarchy has taken some.

Every boot of the installed system also records hardware details to
`/var/log/omarchy-n1x-probe.log`.

## Dev image: remote access

The dev image carries one development public key
(`builder/n1x-dev-ssh/authorized_keys` in this repository). Password and
keyboard-interactive logins are refused everywhere; only that key works.

**On the live USB**, sshd starts on boot and root accepts the key. Find the
address on the laptop with `ip -4 -brief address`, from the recovery entry's
probe output, or from your router's DHCP leases. The live system is called
`omarchy-n1x-rescue`, so this also works where mDNS reaches:

```bash
ssh root@<address>
ssh root@omarchy-n1x-rescue.local
```

**On a system installed from the dev image**, sshd is enabled, port 22 is open
in the firewall, and both root and the user you created accept the key:

```bash
ssh root@<address>
ssh <user>@<address>
```

The installed system uses the laptop's own hostname and DHCP. It has no wired
network port, so remote access needs a USB Ethernet adapter or Wi-Fi.

### Removing dev access from an installed machine

```bash
sudo rm /etc/ssh/sshd_config.d/05-omarchy-n1x-dev-ssh.conf
sudo sed -i '/n1x-recovery/d' /root/.ssh/authorized_keys ~/.ssh/authorized_keys
sudo systemctl disable --now sshd
sudo ufw delete allow ssh
```

The machine is then the same as one installed from the normal image.
Reinstalling from the normal image does the same thing.

## Updates

Omarchy Update works as on any Omarchy machine, with one hold: the NVIDIA
driver stays at 610.57.04, the version proven on this GPU.
`/etc/pacman.conf` carries

```
IgnorePkg = nvidia-open-dkms nvidia-utils
```

so updates skip newer drivers (pacman lists them as `[ignored]`). To try a
newer driver, remove that line and update, and keep the rescue entry in mind:
if the desktop comes up black afterwards, boot **N1x rescue** and downgrade
from the package cache (`sudo pacman -U /var/cache/pacman/pkg/nvidia-*610.57.04*`).

## Known limitations

- **Battery, lid, and thermal readings are missing.** The firmware's embedded
  controller uses a newer interface than NVIDIA's driver implements.
- **The rescue entry does not follow kernel updates.** It is built once, at
  install time. After a `linux-n1x` update the normal entry is rebuilt; the
  rescue entry keeps the old kernel until it is rebuilt by hand.
- **systemd reports failed TPM units** (`systemd-pcrlogin@*`,
  `systemd-pcrproduct`, `systemd-tpm2-setup-early`). The pre-release firmware
  does not offer what they measure into. They do not affect booting.
- **Omarchy's own packages are local builds.** `omarchy` and
  `omarchy-settings` carry the N1x support and install at the same version as
  upstream's aarch64 packages. A newer upstream release would replace them
  without the N1x support, although settings already applied stay in place.

## Building the images

Builds run natively on an aarch64 host with Docker. They need:

- **Omarchy source:** a checkout of the N1x runtime branch (Omarchy 4.0.4 plus
  the N1x commits).
- **omarchy-pkgs:** a checkout with the N1x recipe switch.
- **A platform package directory:** the `linux-n1x` and `linux-n1x-headers`
  packages plus the NVIDIA 610.57.04 packages, with a `SHA256SUMS` file
  covering them.

```bash
export OMARCHY_RUNTIME_PACKAGE=omarchy OMARCHY_SETTINGS_PACKAGE=omarchy-settings

# Normal image
bin/omarchy-iso-make --arch aarch64 --platform n1x \
  --package-dir <platform-packages> --local-source <omarchy> <omarchy-pkgs> --no-boot-offer

# Dev image: adds the development key and verbose installer output
bin/omarchy-iso-make --arch aarch64 --platform n1x --dev-ssh --debug \
  --package-dir <platform-packages> --local-source <omarchy> <omarchy-pkgs> --no-boot-offer
```

The images land in `release/`, named `…-aarch64-n1x-local.iso` and
`…-aarch64-n1x-devssh-local.iso`. The build fails if the Omarchy packages come
out as the Apple Silicon variant, which lacks the boot setup the N1x needs.
