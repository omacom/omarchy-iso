# Omarchy ISO

[![Nightly ISO Build](https://github.com/omacom/omarchy-iso/actions/workflows/nightly-build.yml/badge.svg?branch=quattro&event=schedule)](https://github.com/omacom/omarchy-iso/actions/workflows/nightly-build.yml?query=branch%3Aquattro+event%3Aschedule)

The Omarchy ISO is the only supported way to install Omarchy. It ships the Omarchy Configurator, installs Arch Linux, installs the Omarchy packages from the bundled mirror, runs target system setup in the chroot, creates the user, and runs `omarchy-setup-user` for that user.

## What is published, and where

| What | Where | When |
| --- | --- | --- |
| Release ISO | `https://iso.omarchy.org/omarchy-<version>.iso`, linked from [omarchy.org](https://omarchy.org) | Each release |
| Edge ISO | `https://nightly.omarchy.org/edge/<version>/omarchy-edge-<version>.iso` | Every night |
| VM image of edge | `https://nightly.omarchy.org/edge/<version>/vm/` | Every night |
| VM image of the last release | `https://nightly.omarchy.org/stable/<version>/<run>/vm/` | Once per release |

Nobody has to build those paths: each channel has a `latest.json` that names the newest version and gives the full URLs.

```
https://nightly.omarchy.org/edge/latest.json
https://nightly.omarchy.org/stable/latest.json
```

A published file is never replaced. Only `latest.json` changes, and it is written last, after everything it points at has been fetched back and compared.

### Release ISO

Every release ISO has a `.sha256` and a `.sig` beside it at the same URL. Download the ISO and its `.sha256` into the same directory and check the ISO before writing it to a USB stick:

```bash
sha256sum -c omarchy-4.0.4.iso.sha256
```

Corruption anywhere in the ISO is worth catching before the write, and corruption in the bundled package mirror is worth catching most: the mirror lives inside the ISO and the installer reads it straight off the medium, so those bytes surface minutes into the install as a pacman "invalid or corrupted package" error rather than as anything that names the download. Corruption elsewhere is louder and earlier — it stops the medium booting or mounting. The `.sig` is for anyone who wants to verify the ISO against the Omarchy signing key.

### Nightly builds

The nightly (`.github/workflows/nightly-build.yml`) builds the edge ISO from `quattro` and the edge packages, installs it unattended, boots what it installed, and turns that installed disk into a VM image. It does the same once for each release, from the release ISO. Nothing is published unless the install and the image's checks passed.

### latest.json

| Field | What it is |
| --- | --- |
| `version` | Edge: the build's date and run number, `2026.10.09.431`. Stable: the release, `4.0.4`. |
| `channel` | `edge` or `stable`. |
| `built_at` | When the image was made, UTC, `2026-10-09T18:02:35Z`. |
| `url` | The ISO that was installed. Edge: on nightly.omarchy.org. Stable: the release ISO on iso.omarchy.org. |
| `sha256`, `size` | The ISO's SHA-256 and its size in bytes. |
| `iso_commit` | The omarchy-iso commit the nightly ran from. |
| `omarchy_version` | The version of the Omarchy package in the image. |
| `omarchy_commit` | Edge: the omarchy commit that package was built from. Stable: empty, the version names it. |
| `kernel` | The kernel release the image boots, as `uname -r` gives it. |
| `vm.url` | The folder the image's files are in, ending in `/`. |
| `vm.disk`, `vm.disk_sha256`, `vm.disk_size` | The disk image, `base.qcow2`: its URL, SHA-256 and size in bytes. |
| `vm.files` | Every file in `vm.url`. |
| `vm.user`, `vm.password` | The account for the desktop and `sudo`. |
| `vm.ssh` | How SSH gets in: keys only, never the password. |

The version is also in the edge ISO's file name, for a consumer that reads it from there.

### VM image

A VM image is Omarchy already installed: it boots to the desktop in a few seconds, with no installer to go through. `vm.url` holds:

| File | What it is |
| --- | --- |
| `base.qcow2` | The disk, a zstd-compressed qcow2. |
| `vmlinuz`, `initrd`, `cmdline` | The image's own kernel, initramfs and kernel arguments, for booting it directly without firmware or boot loader. |
| `OVMF_VARS.4m.fd` | The firmware variables with the installer's boot entry, for booting it through UEFI instead. |
| `vm-boot` | A script that boots the image with QEMU. |
| `SHA256SUMS` | Checksums of the files above. |

Every boot is its own machine: a new machine ID and new SSH host keys, and nothing of the build left in the image. To get one and run it, on a machine with QEMU and KVM:

```bash
latest=https://nightly.omarchy.org/edge/latest.json
vm=$(curl -fsSL "$latest" | jq -r .vm.url)
for file in $(curl -fsSL "$latest" | jq -r '.vm.files[]'); do curl -fsSLO "$vm$file"; done
sha256sum -c SHA256SUMS
chmod +x vm-boot

./vm-boot .             # boots, prints how to log in, runs until Ctrl-C
./vm-boot . uname -r    # boots, runs the command over SSH, powers off
```

`vm-boot` runs the machine on a throwaway overlay, so the downloaded image is never written to, and makes an SSH key for each boot. Its header lists what it needs and the settings it takes.

## Creating the ISO

Run `./bin/omarchy-iso-make`; output goes into `./release`. By default the ISO uses the Omarchy packages and tracks the `quattro` branch, from the stable mirror. Pass `--edge` to use `omarchy-dev` and `omarchy-settings-dev` from the edge mirror.

For local development, build the ISO from sibling checkouts:

```bash
./bin/omarchy-iso-make --local-source ../omarchy-installer ../omarchy-pkgs
```

Despite the local folder name, the first argument is the Omarchy source checkout (runtime commands, configs, setup scripts, themes, shell, migrations). The installer itself lives in this ISO repo.

Use `--dev` or `--rc` to build against those package channels. Both `--dev` and `--edge` select the dev packages from the edge mirror.

## Autoinstall

The shipped ISO installs itself with no keyboard when it finds its configuration on a second drive. Attach a drive labeled `cidata` alongside the ISO and the installer copies the config off it and skips the configurator; with no such drive, nothing changes and the wizard runs as usual. No rebuild, no extra boot entry.

`cidata` is the cloud-init `NoCloud` label, so Proxmox, libvirt, and Packer already know how to attach one.

### Configuration files

These are the configurator's own output files, so the way to get a starting set is to run one interactive install and copy what it wrote into `/root`.

| File | Required | Purpose |
|------|----------|---------|
| `user_configuration.json` | Yes | archinstall config: disk, hostname, timezone, keyboard |
| `user_credentials.json` | Yes | Username and password hash |
| `user_full_name.txt` | No | Git full name |
| `user_email_address.txt` | No | Git email |
| `user_encrypt_installation.txt` | No | `true` when `user_configuration.json` carries a `disk_encryption` block; defaults to false |
| `authorized_keys` | No | SSH public keys in sshd's own format, one per line |
| `tailscale_authkey` | No | Tailscale auth key; the machine joins your tailnet on first boot |

Both required files must be present or the installer falls back to the configurator. Generate the password hash for `user_credentials.json` with `openssl passwd -6 "yourpassword"`.

Encryption itself is configured by the `disk_encryption` block inside `user_configuration.json` — which carries the passphrase in plaintext, so treat a drive built from an encrypted install accordingly. The flag file must match it: it drives the encrypted install's SDDM autologin and the final boot validation, not the encryption.

`authorized_keys` is the same file sshd reads — copy your own or write one key per line:

```
ssh-ed25519 AAAA... you@host
```

When `authorized_keys` is present, autoinstall installs it as the user's `~/.ssh/authorized_keys`, enables `sshd`, and adds a `ufw allow ssh` rule — a stock Omarchy install ships openssh with the service disabled and its firewall opens neither port 22 nor anything else beyond LocalSend. Networking needs nothing extra; NetworkManager is already enabled with DHCP. Password SSH authentication is left at the distro default. An `authorized_keys` with no usable keys fails the install rather than producing a machine nobody can reach.

When `tailscale_authkey` is present (one key, blank lines and `#` comments ignored), the install adds the `tailscale` package from the ISO's bundled mirror — nothing is fetched from the network at install or boot — and stages the join for first boot: the key lands at `/etc/tailscale/authkey` (root-only), `tailscaled` is enabled, ufw allows traffic in on `tailscale0`, and a background unit runs `tailscale up` once the network is actually up, retrying until it succeeds without holding up the boot. After a successful join the key is deleted and the unit disables itself; until then both survive reboots, so a machine installed offline joins whenever it first gets connectivity. The node appears on the tailnet under the configured hostname. Use a reusable, pre-authorized (tagged) key so one drive image serves many machines — or an ephemeral key for disposable VMs.

### Building the drive

```bash
mkdir cidata
cp user_configuration.json user_credentials.json authorized_keys cidata/
genisoimage -output cidata.iso -volid cidata -joliet -rock cidata/
```

### Proxmox example

```bash
qm create 101 --name my-omarchy \
  --bios ovmf --machine q35 --cpu host --cores 4 --memory 8192 \
  --ostype l26 --scsihw virtio-scsi-single \
  --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=0 \
  --scsi0 local-lvm:40,discard=on,iothread=1 \
  --net0 virtio,bridge=vmbr0 --vga virtio --serial0 socket \
  --ide2 local:iso/omarchy.iso,media=cdrom \
  --ide3 local:iso/cidata.iso,media=cdrom \
  --boot order='scsi0;ide2'

qm start 101
```

Boot order is disk first: the empty disk falls through to the ISO on the first boot, and the installed system boots from disk afterwards. The machine reboots into Omarchy on its own when the install finishes.

Encrypted autoinstalls are not fully unattended — the LUKS passphrase prompt still needs someone at the first boot.

## Testing the ISO

Run `./bin/omarchy-iso-boot [release/omarchy.iso]`.

Run `./test/all` for the fast, VM-free tests under `test/unit/`, which cover cidata autoinstall loading and the orchestrator's phases without needing a built ISO.

To exercise installation alongside existing Windows-style partitions, run
`./bin/omarchy-iso-test-windows-disk [release/omarchy.iso]`. It creates a
synthetic disk in `/tmp` with an existing ESP and data partition plus ample
unallocated space, then offers to start an interactive installation on it. The
fixture exercises Windows partition preservation but does not contain Windows.

## Acceptance testing the ISO

Run `./bin/omarchy-iso-test [release/omarchy.iso]` to install the ISO into a headless VM by driving the real interactive install flow — the harness reads each screen via QMP screendumps + OCR and answers with virtual keystrokes, so the configurator wizard, install dashboard, reboot prompt, and SDDM login are all exercised exactly as a user would. It then boots the installed system, sends real VM keyboard shortcuts for the primary shell and window-management actions, and runs the in-guest acceptance suite (`test/acceptance` in the omarchy repo). The suite checks session and service health, the complete core-package manifest, user defaults, representative applications, menus, panels, live weather, launchers, visual selectors, notifications, clipboard, and other interactive shell behavior.

Visual checkpoints are saved as `success-<step>.png` or `failure-<step>.png` alongside the serial and install logs in `test-runs/<iso>/runs/<timestamp>/`. Independent test files and applications continue after a failure so one broken surface does not hide the rest of the report. The harness then stops the VM and opens the ordered screenshots in `imv` for quick visual review.

The harness syncs the acceptance suite from `$OMARCHY_PATH` when it is available. The install phase produces a reusable base image, so iterating against another checkout is fast:

```bash
./bin/omarchy-iso-test release/omarchy.iso --install-only        # once per ISO
./bin/omarchy-iso-test release/omarchy.iso --reuse-base \
  --sync-omarchy ../omarchy                                      # fast loop against local tests
```

Pass `--encrypt` to drive the encrypted install flow (including typing the LUKS passphrase at boot) instead of the unencrypted one. Pass `--no-preview` to collect the same visual artifacts without opening them in `imv` when the run finishes.

## Integration testing the ISO

Scenarios under `test/integration.d/` boot a real ISO install in QEMU and assert on what the running system actually does. The runner installs the ISO once — unattended, from a generated cidata drive — and saves the result as a reusable base image; every scenario then boots a throwaway overlay of that base with its own copy of the firmware vars, so neither disk nor NVRAM state leaks between runs. Shared machinery (VM lifecycle, QMP screendump + OCR console driving, virtual keystrokes, guest SSH, the cidata build) lives in `test/integration.d/base-test.sh`, so a new scenario is one file.

```bash
./test/integration release/omarchy.iso                   # install once, run all scenarios
./test/integration release/omarchy.iso --reuse-base      # fast loop against the saved base
./test/integration release/omarchy.iso factory-reset     # a single named scenario
```

The first scenario is `factory-reset`: it proves `omarchy-system-factory-reset` hands a machine on without destroying a shared ESP. The installed ESP gets a Windows entry with payload plus a second Linux cloned under a foreign machine-id with its own boot directory and UKIs; a real factory reset is then driven through a guest pty, and the harness asserts the foreign entries survive both the staged reset and first-boot provisioning, that the old Omarchy identity is fully retired, and that the machine reaches first-boot setup unattended.

Artifacts — screenshots, the fixtured/staged/final `limine.conf`, the reset typescript, and the factory-reset log — land under `test-runs/<iso>-integration/runs/<timestamp>-<scenario>/`, and `--no-preview` skips the `imv` review just like the acceptance harness.

## Signing the ISO

Run `./bin/omarchy-iso-sign [release/omarchy.iso]`. The signing key is retrieved from the shared Omarchy vault with the 1Password CLI.

## Uploading the ISO

Run `./bin/omarchy-iso-upload [release/omarchy.iso]`. This requires rclone configuration (`rclone config`). The `.sig` and `.sha256` sidecars go up with the ISO when they exist beside it.

## Full release of the ISO

Run `./bin/omarchy-iso-release VERSION` to create, test, sign, and upload the ISO in one flow. Add `--rc` to release an RC build instead.
