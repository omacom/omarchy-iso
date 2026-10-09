# Omarchy ISO

[![Nightly ISO Build](https://github.com/omacom/omarchy-iso/actions/workflows/nightly-build.yml/badge.svg?branch=quattro&event=schedule)](https://github.com/omacom/omarchy-iso/actions/workflows/nightly-build.yml?query=branch%3Aquattro+event%3Aschedule)

The Omarchy ISO is the only supported way to install Omarchy. It ships the Omarchy Configurator, installs Arch Linux, installs the Omarchy packages from the bundled mirror, runs target system setup in the chroot, creates the user, and runs `omarchy-provision-user` for that user.

## Get Omarchy

[Download the ISO](https://omarchy.org) and put it on a USB stick, with [balenaEtcher](https://etcher.balena.io/) on Mac or Windows or [caligula](https://github.com/ifd3f/caligula) on Linux. Turn off Secure Boot and/or TPM in the BIOS, boot off the stick, answer the configuration questions and select a drive. The install can be done in under a minute on the fastest modern machines and shouldn't take more than 5 minutes even on an older computer.

Check the download before writing it to the stick. Every release ISO has a `.sha256` beside it at the same URL, linked next to the download. From a terminal, this fetches the latest release and checks it; the version is the latest release of [omacom/omarchy](https://github.com/omacom/omarchy/releases):

```bash
version=$(curl -fsSL https://api.github.com/repos/omacom/omarchy/releases/latest | jq -r .tag_name)
version=${version#v}
curl -fLO "https://iso.omarchy.org/omarchy-$version.iso"
curl -fsSLO "https://iso.omarchy.org/omarchy-$version.iso.sha256"
sha256sum -c "omarchy-$version.iso.sha256"
```

A damaged download otherwise shows up minutes into the install, as a pacman "invalid or corrupted package" error. There is a `.sig` beside the ISO too, for verifying it against the Omarchy signing key.

The manual has the rest:

- [Getting started](https://omarchy.org/manual/getting-started/): the install step by step, installing for another owner, installing without encryption.
- [Dual-boot install](https://omarchy.org/manual/dual-boot-install/): Omarchy in the free space of a drive, beside Windows or another OS.
- [Unattended installs](https://omarchy.org/manual/unattended-installs/): the ISO installs itself, with no keyboard and no wizard, from a configuration on a second drive.

## For maintainers

Everything from here on is about building, testing and publishing the ISO.

### What is published, and where

| What | Where | When |
| --- | --- | --- |
| Release ISO, with `.sha256` and `.sig` | `https://iso.omarchy.org/omarchy-<version>.iso` | Each release |
| Edge ISO, with `.sha256` | `https://nightly.omarchy.org/edge/<version>/omarchy-edge-<version>.iso` | Every night |
| VM image of edge | `https://nightly.omarchy.org/edge/<version>/vm/` | Every night |
| VM image of the last release | `https://nightly.omarchy.org/stable/<version>/<run>/vm/` | Once per release |
| `latest.json` | `https://nightly.omarchy.org/edge/latest.json` and `.../stable/latest.json` | With each of the three above |

On nightly.omarchy.org a published file is never replaced. Only `latest.json` changes, and it is written last, after every file of the version has been fetched back through the CDN and compared.

### The nightly

`.github/workflows/nightly-build.yml` runs every night and for two channels:

- `edge`: builds the ISO from the edge channel: the edge packages and mirrors, and the edge builds of Omarchy (`omarchy-dev`).
- `stable`: takes the last release. The latest release of omacom/omarchy names the version, iso.omarchy.org has the ISO, and it is used only if its signature is the release key's. A release already published is skipped on the nightly run; a run started by hand makes it again.

Each ISO is installed unattended and the installed system booted, by the same install test a pull request gets. `test/vm-image/vm-seal` then turns the installed disk into a VM image and `test/vm-image/vm-verify` boots that image and checks it. Nothing is published unless all of it passed.

Publishing is a job of its own, the only one with the bucket's key, and it runs on `quattro` only. To try a change, run the workflow by hand on a branch: that builds and checks everything and publishes nothing.

Which channels a run makes and where they go is decided by `test/vm-image/nightly-plan`; what is laid out and what `latest.json` says by `test/vm-image/nightly-layout`. Both are covered by `test/unit/nightly-test.sh`.

### latest.json

| Field | What it is |
| --- | --- |
| `version` | Edge: the build's date and run number, `2026.10.09.431`. Stable: the release, `4.0.4`. |
| `channel` | `edge` or `stable`. |
| `built_at` | When this file was written, once the image had passed its checks. UTC, `2026-10-09T18:02:35Z`. |
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

The version is also in the edge ISO's file name.

### A VM image's files

| File | What it is |
| --- | --- |
| `base.qcow2` | The disk, a zstd-compressed qcow2. |
| `vmlinuz`, `initrd`, `cmdline` | The image's own kernel, initramfs and kernel arguments, for booting it directly without firmware or boot loader. |
| `OVMF_VARS.4m.fd` | The firmware variables with the installer's boot entry, for booting it through UEFI instead. |
| `vm-boot` | A script that boots the image with QEMU. |
| `SHA256SUMS` | Checksums of the files above. |


### Using a VM image

For testing, not for users: users get the release ISO from iso.omarchy.org. A VM image is Omarchy already installed, with no installer to go through, and it boots in seconds. There is one of edge, rebuilt every night, and one of the last release.

On a Linux machine with QEMU (`qemu-system-x86_64` and `qemu-img`), a `/dev/kvm` you can read and write, `ssh`, `curl` and `jq`:

```bash
latest=https://nightly.omarchy.org/edge/latest.json    # or .../stable/latest.json
vm=$(curl -fsSL "$latest" | jq -r .vm.url)
for file in $(curl -fsSL "$latest" | jq -r '.vm.files[]'); do curl -fsSLO "$vm$file"; done
sha256sum -c SHA256SUMS
chmod +x vm-boot

./vm-boot .             # boots, prints how to log in, runs until Ctrl-C
./vm-boot . uname -r    # boots, runs the command over SSH, powers off
```

The user is `omarchy` with password `omarchy`. SSH takes keys only, and `vm-boot` makes one for each boot. Every boot is a new machine, and the downloaded image is never written to: the machine runs on an overlay under `/var/tmp` (`VM_STATE_DIR` moves it) that is deleted on exit. The disk is a download of 4 to 5 GB.

The nightly's edge ISO is `jq -r .url` of the same `latest.json`.

### Autoinstall

The [manual's page](https://omarchy.org/manual/unattended-installs/) is the one for users; this is the same feature in full.

The shipped ISO installs itself with no keyboard when it finds its configuration on a second drive. Attach a drive labeled `cidata` alongside the ISO and the installer copies the config off it and skips the configurator; with no such drive, nothing changes and the wizard runs as usual. No rebuild, no extra boot entry.

`cidata` is the cloud-init `NoCloud` label, so Proxmox, libvirt, and Packer already know how to attach one.

#### Configuration files

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

Both required files must be present or the installer falls back to the configurator. (A `defer-provisioning` marker file can stand in for `user_credentials.json`: user creation is then deferred to first boot.) Generate the password hash for `user_credentials.json` with `openssl passwd -6 "yourpassword"`.

Encryption itself is configured by the `disk_encryption` block inside `user_configuration.json` — which carries the passphrase in plaintext, so treat a drive built from an encrypted install accordingly. The flag file must match it: it drives the encrypted install's SDDM autologin and the final boot validation, not the encryption.

`authorized_keys` is the same file sshd reads — copy your own or write one key per line:

```
ssh-ed25519 AAAA... you@host
```

When `authorized_keys` is present, autoinstall installs it as the user's `~/.ssh/authorized_keys`, enables `sshd`, and adds a `ufw allow ssh` rule — a stock Omarchy install ships openssh with the service disabled and its firewall opens neither port 22 nor anything else beyond LocalSend and Docker's DNS. Networking needs nothing extra; NetworkManager is already enabled with DHCP. Password SSH authentication is left at the distro default. An `authorized_keys` with no keys in it fails the install rather than producing a machine nobody can reach.

When `tailscale_authkey` is present (one key, blank lines and `#` comments ignored), the install adds the `tailscale` package from the ISO's bundled mirror — nothing is fetched from the network at install or boot — and stages the join for first boot: the key lands at `/etc/tailscale/authkey` (root-only), `tailscaled` is enabled, ufw allows traffic in on `tailscale0`, and a background unit runs `tailscale up` once the network is actually up, retrying until it succeeds without holding up the boot. After a successful join the key is deleted and the unit disables itself; until then both survive reboots, so a machine installed offline joins whenever it first gets connectivity. The node appears on the tailnet under the configured hostname. Use a reusable, pre-authorized (tagged) key so one drive image serves many machines — or an ephemeral key for disposable VMs.

#### Building the drive

```bash
mkdir cidata
cp user_configuration.json user_credentials.json authorized_keys cidata/
genisoimage -output cidata.iso -volid cidata -joliet -rock cidata/
```

#### Proxmox example

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

### Creating the ISO

Run `./bin/omarchy-iso-make`; output goes into `./release`. By default the ISO uses the Omarchy packages and tracks the `quattro` branch, from the stable mirror. Pass `--edge` to use `omarchy-dev` and `omarchy-settings-dev` from the edge mirror.

For local development, build the ISO from sibling checkouts:

```bash
./bin/omarchy-iso-make --local-source ../omarchy-installer ../omarchy-pkgs
```

Despite the local folder name, the first argument is the Omarchy source checkout (runtime commands, configs, setup scripts, themes, shell, migrations). The installer itself lives in this ISO repo.

Use `--dev` or `--rc` to build against those package channels. Both `--dev` and `--edge` select the dev packages from the edge mirror.

### Testing the ISO

Run `./bin/omarchy-iso-boot [release/omarchy.iso]`.

Run `./test/all` for the fast, VM-free tests under `test/unit/`, which cover cidata autoinstall loading and the orchestrator's phases without needing a built ISO.

To exercise installation alongside existing Windows-style partitions, run
`./bin/omarchy-iso-test-windows-disk [release/omarchy.iso]`. It creates a
synthetic disk in `/tmp` with an existing ESP and data partition plus ample
unallocated space, then offers to start an interactive installation on it. The
fixture exercises Windows partition preservation but does not contain Windows.

### Acceptance testing the ISO

Run `./bin/omarchy-iso-test [release/omarchy.iso]` to install the ISO into a headless VM by driving the real interactive install flow — the harness reads each screen via QMP screendumps + OCR and answers with virtual keystrokes, so the configurator wizard, install dashboard, reboot prompt, and SDDM login are all exercised exactly as a user would. It then boots the installed system, sends real VM keyboard shortcuts for the primary shell and window-management actions, and runs the in-guest acceptance suite (`test/acceptance` in the omarchy repo). The suite checks session and service health, the complete core-package manifest, user defaults, representative applications, menus, panels, live weather, launchers, visual selectors, notifications, clipboard, and other interactive shell behavior.

Visual checkpoints are saved as `success-<step>.png` or `failure-<step>.png` alongside the serial and install logs in `test-runs/<iso>/runs/<timestamp>/`. Independent test files and applications continue after a failure so one broken surface does not hide the rest of the report. The harness then stops the VM and opens the ordered screenshots in `imv` for quick visual review.

The harness syncs the acceptance suite from `$OMARCHY_PATH` when it is available. The install phase produces a reusable base image, so iterating against another checkout is fast:

```bash
./bin/omarchy-iso-test release/omarchy.iso --install-only        # once per ISO
./bin/omarchy-iso-test release/omarchy.iso --reuse-base \
  --sync-omarchy ../omarchy                                      # fast loop against local tests
```

Pass `--encrypt` to drive the encrypted install flow (including typing the LUKS passphrase at boot) instead of the unencrypted one. Pass `--no-preview` to collect the same visual artifacts without opening them in `imv` when the run finishes.

### Integration testing the ISO

Scenarios under `test/integration.d/` boot a real ISO install in QEMU and assert on what the running system actually does. The runner installs the ISO once — unattended, from a generated cidata drive — and saves the result as a reusable base image; every scenario then boots a throwaway overlay of that base with its own copy of the firmware vars, so neither disk nor NVRAM state leaks between runs. Shared machinery (VM lifecycle, QMP screendump + OCR console driving, virtual keystrokes, guest SSH, the cidata build) lives in `test/integration.d/base-test.sh`, so a new scenario is one file.

```bash
./test/integration release/omarchy.iso                   # install once, run all scenarios
./test/integration release/omarchy.iso --reuse-base      # fast loop against the saved base
./test/integration release/omarchy.iso factory-reset     # a single named scenario
```

The first scenario is `factory-reset`: it proves `omarchy-system-factory-reset` hands a machine on without destroying a shared ESP. The installed ESP gets a Windows entry with payload plus a second Linux cloned under a foreign machine-id with its own boot directory and UKIs; a real factory reset is then driven through a guest pty, and the harness asserts the foreign entries survive both the staged reset and first-boot provisioning, that the old Omarchy identity is fully retired, and that the machine reaches first-boot setup unattended.

Artifacts — screenshots, the fixtured/staged/final `limine.conf`, the reset typescript, and the factory-reset log — land under `test-runs/<iso>-integration/runs/<timestamp>-<scenario>/`, and `--no-preview` skips the `imv` review just like the acceptance harness.

### Signing the ISO

Run `./bin/omarchy-iso-sign [release/omarchy.iso]`. The signing key is retrieved from the shared Omarchy vault with the 1Password CLI.

### Uploading the ISO

Run `./bin/omarchy-iso-upload [release/omarchy.iso]`. This requires rclone configuration (`rclone config`). The `.sig` and `.sha256` sidecars go up with the ISO when they exist beside it.

### Full release of the ISO

Run `./bin/omarchy-iso-release VERSION` to create, test, sign, and upload the ISO in one flow. Add `--rc` to release an RC build instead.
