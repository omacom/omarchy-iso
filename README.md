# Omarchy ISO

[![Nightly ISO Build](https://github.com/omacom/omarchy-iso/actions/workflows/nightly-build.yml/badge.svg?branch=quattro&event=schedule)](https://github.com/omacom/omarchy-iso/actions/workflows/nightly-build.yml?query=branch%3Aquattro+event%3Aschedule)

The Omarchy ISO is the only supported way to install Omarchy. It includes the Omarchy Configurator and installs Arch Linux and the Omarchy packages from the bundled mirror. It then runs target system setup in the chroot, creates the user, and runs `omarchy-provision-user` for that user.

## Get Omarchy

1. [Download the ISO](https://omarchy.org).
2. Write it to a USB stick. Use [balenaEtcher](https://etcher.balena.io/) on Mac or Windows, or [caligula](https://github.com/ifd3f/caligula) on Linux.
3. Turn off Secure Boot and/or TPM in the BIOS.
4. Boot from the stick.
5. Answer the configuration questions and select a drive.

The install takes under a minute on the fastest machines and up to 5 minutes on an older computer.

### Verify the download

Verify the ISO before you write it to the stick. Otherwise, a corrupted download causes a pacman "invalid or corrupted package" error several minutes into the install.

Every release ISO has a `.sha256` file and a `.sig` file next to it. Run these commands to download and verify the ISO of the latest release of [omacom/omarchy](https://github.com/omacom/omarchy/releases):

```bash
version=$(curl -fsSL https://api.github.com/repos/omacom/omarchy/releases/latest | jq -r .tag_name)
version=${version#v}
curl -fLO "https://iso.omarchy.org/omarchy-$version.iso"
curl -fsSLO "https://iso.omarchy.org/omarchy-$version.iso.sha256"
sha256sum -c "omarchy-$version.iso.sha256"
```

Use the `.sig` file to verify the ISO against the Omarchy signing key.

### More in the manual

- [Getting started](https://omarchy.org/manual/getting-started/): the install step by step, installing for another owner, and installing without encryption.
- [Dual-boot install](https://omarchy.org/manual/dual-boot-install/): install Omarchy in the free space of a drive, beside Windows or another OS.
- [Unattended installs](https://omarchy.org/manual/unattended-installs/): let the ISO install itself from a configuration on a second drive, with no keyboard and no wizard.

# For maintainers

The rest of this file covers building, testing and publishing the ISO.

## What is published, and where

| What | Where | When |
| --- | --- | --- |
| Release ISO | `https://iso.omarchy.org/omarchy-<version>.iso` | Each release |
| Edge ISO | `https://nightly.omarchy.org/edge/<version>/omarchy-edge-<version>.iso` | Every night |
| VM image of edge | `https://nightly.omarchy.org/edge/<version>/omarchy-edge-<version>.qcow2` | Every night |
| VM image of the latest release | `https://nightly.omarchy.org/stable/<version>/<run>/omarchy-<version>.qcow2` | Once per release |
| `latest.json` | `https://nightly.omarchy.org/edge/latest.json` and `.../stable/latest.json` | With each nightly build |

Every ISO and every VM image has a `.sha256` file next to it. The release ISO also has a `.sig` file. Each VM image has an `unpacked/` folder next to it.

On nightly.omarchy.org, a published file is never replaced. Only `latest.json` changes. It is written last, after every file of the version has been fetched back through the CDN and compared.

## The nightly build

`.github/workflows/nightly-build.yml` runs every night for two channels:

- `edge`: builds the ISO from the edge channel: the edge packages and mirrors, and the edge builds of Omarchy (`omarchy-dev`).
- `stable`: uses the latest release. The latest release of omacom/omarchy determines the version. The ISO comes from iso.omarchy.org and is used only if its signature matches the release key. A scheduled run skips a release that is already published. A manual run builds it again.

Each ISO goes through the same install test that runs for pull requests: an unattended install, then a boot of the installed system. `test/vm-image/vm-seal` then turns the installed disk into a VM image, and `test/vm-image/vm-verify` boots that image and checks it. Nothing is published unless every check passes.

A separate job publishes. It is the only job with the bucket's key, and it runs only on `quattro`. To try a change, run the workflow manually on a branch. That run builds and checks everything and publishes nothing.

`test/vm-image/nightly-plan` decides which channels a run builds and where they are published. `test/vm-image/nightly-layout` lays out the files and writes `latest.json`. `test/unit/nightly-test.sh` tests both.

## latest.json

| Field | What it is |
| --- | --- |
| `version` | Edge: the build's date and run number, `2026.10.09.431`. Stable: the release, `4.0.4`. |
| `channel` | `edge` or `stable`. |
| `built_at` | When this file was written, after the image passed its checks. UTC, `2026-10-09T18:02:35Z`. |
| `url` | The ISO that was installed. Edge: on nightly.omarchy.org. Stable: the release ISO on iso.omarchy.org. |
| `sha256`, `size` | The ISO's SHA-256 and its size in bytes. |
| `iso_commit` | The omarchy-iso commit the nightly build ran from. |
| `omarchy_version` | The version of the Omarchy package in the image. |
| `omarchy_commit` | Edge: the omarchy commit that package was built from. Stable: empty. |
| `kernel` | The image's kernel release, as reported by `uname -r`. |
| `vm.url`, `vm.sha256`, `vm.size` | The VM image: its URL, SHA-256 and size in bytes. |
| `vm.unpacked` | The URL of the image's `unpacked/` folder, ending in `/`. |
| `vm.unpacked_files` | Every file in that folder. |
| `vm.user`, `vm.password` | The account for the desktop and `sudo`. |
| `vm.ssh` | SSH authentication: keys only. Password authentication is off. |

The version is also in the edge ISO's file name.

## VM images

VM images are for testing. Users download the release ISO from iso.omarchy.org.

A VM image is Omarchy already installed, as one `.qcow2` file. There is an image of the edge channel, rebuilt every night, and an image of the latest release. Every boot is a new machine, with a new machine ID and new SSH host keys.

The user is `omarchy` and the password is `omarchy`. SSH takes keys only.

### Boot the image by itself

The image boots through UEFI with no other file. Run these commands on a Linux machine with QEMU, read and write access to `/dev/kvm`, `curl` and `jq`:

```bash
latest=https://nightly.omarchy.org/edge/latest.json    # or .../stable/latest.json
image=$(curl -fsSL "$latest" | jq -r .vm.url)
curl -fLO "$image"
curl -fsSLO "$image.sha256"
sha256sum -c "${image##*/}.sha256"

cp /usr/share/edk2/x64/OVMF_VARS.4m.fd vars.fd
qemu-system-x86_64 -enable-kvm -cpu host -smp 4 -m 4G \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/x64/OVMF_CODE.4m.fd \
  -drive if=pflash,format=raw,file=vars.fd \
  -drive file="${image##*/}",if=virtio,snapshot=on \
  -device virtio-vga
```

The firmware paths are Arch's. `snapshot=on` keeps the downloaded image unchanged. The image is a 4 to 5 GB download.

### Boot it faster, with SSH

The `unpacked/` folder next to each image holds what a direct boot needs:

| File | What it is |
| --- | --- |
| `vmlinuz`, `initrd`, `cmdline` | The image's own kernel, initramfs and kernel arguments. |
| `vm-boot` | A script that boots the image directly into its kernel and gives it an SSH key. |
| `SHA256SUMS` | Checksums of the files above. |

A direct boot skips the firmware and the boot loader: SSH answers after about 6 seconds instead of about 20. Download the folder next to the image, then run `vm-boot`. It also needs `qemu-img` and `ssh`:

```bash
unpacked=$(curl -fsSL "$latest" | jq -r .vm.unpacked)
for file in $(curl -fsSL "$latest" | jq -r '.vm.unpacked_files[]'); do curl -fsSLO "$unpacked$file"; done
sha256sum -c SHA256SUMS
chmod +x vm-boot

./vm-boot "${image##*/}"             # boots, prints how to log in, runs until Ctrl-C
./vm-boot "${image##*/}" uname -r    # boots, runs the command over SSH, powers off
```

`vm-boot` makes a new SSH key for each boot. It runs the machine on an overlay under `/var/tmp`, so the downloaded image is never changed, and deletes the overlay on exit. Set `VM_STATE_DIR` to put the overlay somewhere else.

To get the URL of the edge ISO, run `jq -r .url` on the same `latest.json`.

## Autoinstall

The [manual's page](https://omarchy.org/manual/unattended-installs/) is the one for users; this is the same feature in full.

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

Both required files must be present or the installer falls back to the configurator. (A `defer-provisioning` marker file can stand in for `user_credentials.json`: user creation is then deferred to first boot.) Generate the password hash for `user_credentials.json` with `openssl passwd -6 "yourpassword"`.

Encryption itself is configured by the `disk_encryption` block inside `user_configuration.json` — which carries the passphrase in plaintext, so treat a drive built from an encrypted install accordingly. The flag file must match it: it drives the encrypted install's SDDM autologin and the final boot validation, not the encryption.

`authorized_keys` is the same file sshd reads — copy your own or write one key per line:

```
ssh-ed25519 AAAA... you@host
```

When `authorized_keys` is present, autoinstall installs it as the user's `~/.ssh/authorized_keys`, enables `sshd`, and adds a `ufw allow ssh` rule — a stock Omarchy install ships openssh with the service disabled and its firewall opens neither port 22 nor anything else beyond LocalSend and Docker's DNS. Networking needs nothing extra; NetworkManager is already enabled with DHCP. Password SSH authentication is left at the distro default. An `authorized_keys` with no keys in it fails the install rather than producing a machine nobody can reach.

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

## Creating the ISO

Run `./bin/omarchy-iso-make`; output goes into `./release`. By default the ISO uses the Omarchy packages and tracks the `quattro` branch, from the stable mirror. Pass `--edge` to use `omarchy-dev` and `omarchy-settings-dev` from the edge mirror.

For local development, build the ISO from sibling checkouts:

```bash
./bin/omarchy-iso-make --local-source ../omarchy-installer ../omarchy-pkgs
```

Despite the local folder name, the first argument is the Omarchy source checkout (runtime commands, configs, setup scripts, themes, shell, migrations). The installer itself lives in this ISO repo.

Use `--dev` or `--rc` to build against those package channels. Both `--dev` and `--edge` select the dev packages from the edge mirror.

### ARM media

The build defaults to the host architecture, with Snapdragon media selected on ARM hosts. Use `--arch` and `--media-target` to select explicitly. Docker must support the selected architecture; cross-architecture builds require container emulation.

```bash
./bin/omarchy-iso-make --arch aarch64 --media-target aarch64/snapdragon --edge --keep-pkg-cache --no-boot-offer
./bin/omarchy-iso-make --arch aarch64 --media-target aarch64/generic --edge --keep-pkg-cache --no-boot-offer
```

Snapdragon media uses a UKI with hardware-matched Qualcomm device trees. Generic ARM media uses GRUB and firmware-provided hardware tables, and must be selected explicitly. Neither target supports every ARM board; Apple Silicon and Raspberry Pi boot support are not included. The existing `omarchy-iso-boot` helper is x86-only.

Both targets use published ARM packages by default. The manual `aarch64 ISO Build` workflow selects `edge`, `rc` or `stable` and builds only the ISO. Package building, signing and publication stay with the existing `omarchy-pkgs` pipeline.

The ISO branch and package channel are independent. Selecting the `dragon` ISO branch does not select Dragon runtime sources. The chosen channel must publish a compatible runtime and settings package, `linux-aarch64-pkgbase-shim`, and, for Snapdragon, `qcom-firmware-extract`. The build rejects packages missing the required ARM boot configuration or Snapdragon setup scripts. It does not publish missing packages or change repository trust settings.

For unpublished changes, use `--local-repo <repo-dir>` for a prebuilt repository or `--local-source` as above to build runtime, settings and Neovim packages from local checkouts. Other missing packages still need to be supplied by the selected repository; the two options can be combined. Offline caches are separated by channel, architecture and media target. Generic image filenames start with `omarchy-generic-`.

[configs/aarch64/platforms.json](configs/aarch64/platforms.json) supplies model-specific packages and installed boot arguments through exact vendor/product matches. Both targets use the package-owned `linux-aarch64-pkgbase-shim` for kernel-image handling.

### Snapdragon live DSP startup

The DSP driver stays disabled in the initramfs because loading it can reset USB-C installation media. On the Yoga Slim 7x, `omarchy-live-dsp.service` starts it later to enable USB hotplug and battery status, but only after verifying that the live filesystem is entirely in RAM, with no mounted block devices or active swap. Other boards and the installed system are unchanged.

Add `omarchy.live_dsp=0` to the live boot arguments to disable this service when troubleshooting. Inspect its decisions with `journalctl -b -u omarchy-live-dsp.service`, or run `omarchy-live-dsp --check` to validate the guards without loading the driver. An unsafe or unfamiliar storage layout leaves the driver disabled.

## Testing the ISO

Run `./bin/omarchy-iso-boot [release/omarchy.iso]`.

Run `./test/all` for the fast, VM-free tests under `test/unit/`, which cover cidata autoinstall loading and the orchestrator's phases without needing a built ISO.

Set `OMARCHY_RUNTIME_PATH=/path/to/omarchy ./test/all` to also check that the
runtime's actual package lists supply the installer's default kernel and headers
for both ARM media targets and x86. This checks package selection, not downloads
or a full ISO build.

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

## Upgrade testing

`test/upgrade-test` checks what an existing user gets. It takes an installed system, moves it to another channel with `omarchy-channel-set`, reboots it, and checks what came back: the update's exit status, skipped migrations, that the reboot comes back by itself into an installed kernel, failed units, the desktop, the user's wallpaper and the boot menu.

```bash
./test/integration release/omarchy.iso boot                                # installs once, leaves the installed disk
./test/upgrade-test test-runs/omarchy-integration edge upgrade-evidence    # edge or rc
```

The evidence folder gets `report.md`, the update's output, and a picture of the desktop before and after.

The "Upgrade test" workflow does both steps from a release's ISO. Start it by hand, from the latest release to edge by default:

```bash
gh workflow run upgrade-test.yml -f to=edge
```

It only runs when started. When the branch it ran on has a pull request, the result is posted there as one comment and updated in place on later runs.

## Signing the ISO

Run `./bin/omarchy-iso-sign [release/omarchy.iso]`. The signing key is retrieved from the shared Omarchy vault with the 1Password CLI.

## Uploading the ISO

Run `./bin/omarchy-iso-upload [release/omarchy.iso]`. This requires rclone configuration (`rclone config`). The `.sig` and `.sha256` sidecars go up with the ISO when they exist beside it.

## Full release of the ISO

Run `./bin/omarchy-iso-release VERSION` to create, test, sign, and upload the ISO in one flow. Add `--rc` to release an RC build instead.
