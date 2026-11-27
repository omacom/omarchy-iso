# Omarchy ISO

[![Nightly ISO Build](https://github.com/omacom/omarchy-iso/actions/workflows/nightly-build.yml/badge.svg?branch=quattro&event=schedule)](https://github.com/omacom/omarchy-iso/actions/workflows/nightly-build.yml?query=branch%3Aquattro+event%3Aschedule)

The Omarchy ISO is the supported way to install Omarchy on x86_64 and non-Apple aarch64 machines (Apple Silicon Macs install from macOS instead). It boots into the Omarchy Configurator to install a pre-built Arch Linux + Omarchy system, or — on x86_64 — lets you **Just try** Omarchy live without touching any drive.

## Get Omarchy

1. [Download the ISO](https://omarchy.org).
2. Write it to a USB stick. Use [balenaEtcher](https://etcher.balena.io/) on Mac or Windows, or [caligula](https://github.com/ifd3f/caligula) on Linux.
3. Turn off Secure Boot and/or TPM in the BIOS.
4. Boot from the stick.
5. Press Return to start the install (or Space on x86_64 to try Omarchy live), then answer the configuration questions and select a drive.

The install takes seconds on fast modern hardware and up to 5 minutes on an older computer.

### Verify the download

Verify the ISO before you write it to the stick. The live ISO checks the SHA-256 checksums of its bundled mirror and root image at boot and refuses a corrupt medium before touching the disk; verifying upfront saves flashing a bad stick and catches corruption in the live boot files too.

Every release ISO has a `.sha256` file and a `.sig` file next to it. Run these commands to download and verify the ISO of the latest release of [omacom/omarchy](https://github.com/omacom/omarchy/releases):

```bash
version=$(curl -fsSL https://api.github.com/repos/omacom/omarchy/releases/latest | jq -r .tag_name)
version=${version#v}
iso=omarchy-$version-x86.iso
curl -fLO "https://iso.omarchy.org/$iso"
curl -fsSLO "https://iso.omarchy.org/$iso.sha256"
sha256sum -c "$iso.sha256"
```

The checksum only catches a corrupted download. The `.sig` file proves that Omarchy built the ISO. Fetch the Omarchy signing key by its full fingerprint, then verify the ISO with GnuPG:

```bash
gpg --keyserver hkps://keys.openpgp.org --recv-keys 40DFB630FF42BCFFB047046CF0134EE680CAC571
curl -fsSLO "https://iso.omarchy.org/$iso.sig"
gpg --verify "$iso.sig" "$iso"
```

The output must say `Good signature from "Omarchy <pkgs@omarchy.org>"` and show the key `40DFB630FF42BCFFB047046CF0134EE680CAC571`. A warning that the key is not certified with a trusted signature is expected. It means only that you have not signed the key yourself.

### More in the manual

- [Getting started](https://omarchy.org/manual/getting-started/): the install step by step, installing for another owner, and installing without encryption.
- [Dual-boot install](https://omarchy.org/manual/dual-boot-install/): install Omarchy in the free space of a drive, beside Windows or another OS.
- [Unattended installs](https://omarchy.org/manual/unattended-installs/): let the ISO install itself from a configuration on a second drive, with no keyboard and no wizard.

# For maintainers

The rest of this file covers how to build, test, and publish the ISO, and how the installer works.

## Creating the ISO

The builder image is pinned by digest in `bin/omarchy-iso-make`; update it through review and build on a disposable host without credentials (pinning does not remove the container's `--privileged` access).

Run `./bin/omarchy-iso-make` to build into `./release`. By default it installs `omarchy` and `omarchy-settings` from the stable mirror. Pass `--edge` (or `--dev`) for `omarchy-dev` and `omarchy-settings-dev` tracking `quattro` from the edge mirror, `--rc` for the release-candidate channel, or `--fast` for minimal zstd compression (`-fast-<ref>.iso`, never selected by `omarchy-iso-release`). For local development against sibling checkouts:

```bash
./bin/omarchy-iso-make --local-source ../omarchy-installer ../omarchy-pkgs
```

Despite the folder name, the first argument is the Omarchy runtime checkout (commands, configs, themes, shell, migrations); the installer itself lives in this repository.

### Preset ISOs

`--preset <code>` builds `omarchy-<code>-*.iso` from `presets/<code>.json` (ISO 3166-1 alpha-2 code) to pre-answer installer questions. Each key is optional:

| Key | Value | Effect |
| --- | --- | --- |
| `language` | Omarchy language code (e.g. `zh-CN`, `da`) | Skips the language screen and runs the installer in that language. |
| `keyboard` | Setup-form keyboard label (e.g. `Chinese (Simplified, Pinyin)`) | Skips the keyboard screen and loads that layout for the disk password. |
| `timezone` | tzdata zone (e.g. `Asia/Shanghai`) | Skips the timezone question. |
| `region` | Omarchy region (`default/regions/<code>/`, currently `cn`) | Sets `/etc/omarchy/region` so `omarchy-apply-pacman` prefers that region's mirrors with `.org` as fallback. A timezone matching another profile — or Hong Kong, Macau, or Taiwan — still overrides it. |

The pre-disk summary lists only answers the user gave (and is skipped if only username and password remain). `presets/cn.json` builds the China ISO (Chinese, Pinyin/fcitx5 on a US layout, `Asia/Shanghai`, x86-only `*.omarchy.cn` mirrors); `test/unit/test_installer_i18n.py` validates every preset. Presets combine with channel flags and `--oem` (`--oem --preset cn` builds `omarchy-oem-cn-*.iso`, opening first-boot setup in Chinese). A preset language also removes the Ctrl+C owner-prep shortcut, and `omarchy-iso-release` publishes only `omarchy-[0-9]*` so preset ISOs are never released as the global image.

### aarch64

```bash
./bin/omarchy-iso-make --arch aarch64 --local-source ../omarchy-installer ../omarchy-pkgs
./bin/omarchy-iso-make --snapdragon --local-source ../omarchy-installer ../omarchy-pkgs
```

The plain image (`--arch aarch64`) serves NVIDIA boards, Raspberry Pi, and other USB-booting hardware, and pre-packs the N1x NVIDIA stack as a platform layer beside the root image. The Snapdragon image (`--snapdragon`, released as `omarchy-<version>-snapdragon.iso`) adds the Snapdragon live UKI (GRUB boots it on Snapdragon and `systemd-stub` matches the SMBIOS device tree; other boards boot the kernel directly), `linux-firmware-qcom`, `qcom-firmware-extract`, baked Qualcomm platform packages, and >1 GiB of OEM signed firmware. Apple Silicon Macs install from macOS instead.

Both images default to the stable channel (`--rc` or `--edge` selects another via `configs/pacman-online-aarch64-<channel>.conf` and `arm-*mirror.omarchy.org`) and build on `linux-omarchy`; `--package-dir` can place a test kernel or pinned packages ahead of it (see [N1X.md](N1X.md)). At install time, `omarchy-hw-platform` detects the board, extracts any matching platform layer, installs remaining platform packages from the offline mirror, and — on Snapdragon machines with Windows — copies vendor-signed firmware off the Windows partition before touching the disk. The build refuses a runtime missing the platform detector or `install/hardware/qualcomm/`.

## Testing the ISO

- **Unit tests:** `./test/all` runs the fast, VM-free suite under `test/unit/` (cidata autoinstall, orchestrator phases, ISO builds, OEM bundles, boot/UKI setup, LUKS calibration, release tooling). Requires `shellcheck` (`test/unit/shellcheck-test.sh`).
- **Interactive VM boot:** `./bin/omarchy-iso-boot [release/omarchy.iso]`.
- **Dual-boot fixture:** `./bin/omarchy-iso-test-windows-disk [release/omarchy.iso]` builds a synthetic `/tmp` disk with an ESP, data partition, and unallocated space (no Windows) to exercise partition preservation.

### Acceptance testing

`./bin/omarchy-iso-test [release/omarchy.iso]` drives the real interactive install in a headless VM (QMP screendumps + OCR + virtual keystrokes), boots the installed system, and runs `test/acceptance` synced from `$OMARCHY_PATH`. Visual checkpoints (`success-<step>.png` / `failure-<step>.png`) and logs land in `test-runs/<iso>/runs/<timestamp>/` and open in `imv` (skip with `--no-preview`; add `--encrypt` for the encrypted flow).

```bash
./bin/omarchy-iso-test release/omarchy.iso --install-only                              # build reusable base
./bin/omarchy-iso-test release/omarchy.iso --reuse-base --sync-omarchy ../omarchy      # iterate on tests
./bin/omarchy-iso-test release/omarchy-oem-*.iso --oem --oem-config acme/oem.json --install-only
```

With `--oem`, the harness waits for the unattended factory install to reboot, drives first-boot owner setup (and the EULA flow when `--oem-config` is passed), and verifies the OEM bundle and acceptance record (`oem-setup.txt`).

### Integration testing

Scenarios in `test/integration.d/` install the ISO once (unattended via cidata) into a reusable base image and boot throwaway overlays with isolated firmware NVRAM (shared harness in `test/integration.d/base-test.sh`; artifacts in `test-runs/<iso>-integration/runs/<timestamp>-<scenario>/`; supports `--no-preview`).

```bash
./test/integration release/omarchy.iso                   # install once, run all scenarios
./test/integration release/omarchy.iso --reuse-base      # rerun against saved base
./test/integration release/omarchy.iso factory-reset     # single named scenario
```

- `factory-reset` fixtures Windows and foreign Linux boot entries on the ESP (and Limine entries on BIOS), runs `omarchy-system-factory-reset`, and asserts foreign entries survive while the old Omarchy identity is retired.
- `corrupt-image` flips one byte inside `omarchy-root.sfs` (located via `xorriso`) and proves `omarchy-root-image-verify.service` halts pre-flight with "re-flash" before touching the disk (runs standalone with `OMARCHY_INTEGRATION_ISO`).

### Upgrade testing

`test/upgrade-test` switches an installed system to another channel via `omarchy-channel-set`, reboots, and checks exit status, skipped migrations, channel and Omarchy package updates, booted kernel, failed units, desktop/shell theme, wallpaper, and `systemd-boot` or Limine boot config, writing `report.md` and before/after screenshots to the evidence folder.

```bash
./test/integration release/omarchy.iso boot                                # pass --release-iso for shipped ISOs
./test/upgrade-test test-runs/omarchy-integration edge upgrade-evidence    # edge or rc
gh workflow run upgrade-test.yml -f to=edge                                # add -f from=<version> for older releases
```

Pass `--release-iso` to `test/integration` when starting from a shipped release (such as `4.0.6`) so legacy first-boot `ConditionNeedsUpdate=` units are noted rather than failed. The workflow posts and updates a PR comment when run on a PR branch.

### Release rehearsal and RC validation

Twice a day, "Install test" builds `quattro`'s tip as a release using `test/rehearsal-pins` (`bin/omarchy-pkgs release rc`, lockstep `omarchy-boot-systemd` when present, `--local-source --rehearsal` producing `*-rehearsal.iso`, all other packages from edge) and runs every install job. Trigger or build it manually:

```bash
gh workflow run install-test.yml --ref <branch> -f channel=rehearsal
./test/rehearsal-pins x86_64 /path/to/rehearsal && ./bin/omarchy-iso-make --local-source /path/to/rehearsal/omarchy /path/to/rehearsal/omarchy-pkgs --rehearsal
```

Validate a feature release candidate cut from `quattro` in this order (example `4.6.0-rc1`):

```bash
gh workflow run install-test.yml -R omacom/omarchy-iso --ref quattro -f channel=rehearsal  # 1. before cutting RC
gh workflow run install-test.yml -R omacom/omarchy-iso --ref quattro -f channel=rc         # 2. fresh x86_64 + aarch64 RC install
gh workflow run upgrade-test.yml -R omacom/omarchy-iso --ref quattro -f to=rc -f from=4.5.0 # 3. latest release -> RC (wait to finish)
gh workflow run upgrade-test.yml -R omacom/omarchy-iso --ref quattro -f to=rc -f from=4.0.6 # 4. older supported series & prior RC
```

Finish the fresh `rc` install and upgrade runs before publishing the next candidate to `rc`. Always pass `from`, and run one upgrade workflow at a time (a new run on the same branch cancels the one in progress). `upgrade-test.yml` tests unencrypted x86_64 only — verify an aarch64 upgrade and an encrypted upgrade manually in a VM.

## Releasing and publishing

- **Full release:** `./bin/omarchy-iso-release VERSION` builds, signs, checksums, and uploads an x86_64 ISO (does not run tests). Pass `--arch aarch64`, `--snapdragon`, `--rc`, or `--no-make` (publishes the latest existing build).
- **Sign:** `./bin/omarchy-iso-sign <release/omarchy.iso>` writes `<iso>.sig` using the signing key from the shared Omarchy 1Password vault.
- **Upload:** `./bin/omarchy-iso-upload <release/omarchy.iso>` uploads the ISO plus adjacent `.sig` and `.sha256` sidecars to R2 (configure rclone first via `./bin/omarchy-iso-rclone-config`).

### What is published, and where

| What | Where | When |
| --- | --- | --- |
| Release ISO | `https://iso.omarchy.org/omarchy-<version>-x86.iso`, `-aarch64.iso` and `-snapdragon.iso` (before 4.5.0: `omarchy-<version>.iso`) | Each release |
| Edge ISO | `https://nightly.omarchy.org/edge/<version>/omarchy-edge-<version>.iso`, `.../edge-aarch64/<version>/omarchy-edge-<version>-aarch64.iso` and `.../edge-snapdragon/<version>/omarchy-edge-<version>-snapdragon.iso` | Every night |
| VM image of edge (x86_64) | `https://nightly.omarchy.org/edge/<version>/omarchy-edge-<version>.qcow2` | Every night |
| VM image of the latest release | `https://nightly.omarchy.org/stable/<version>/<run>/omarchy-<version>.qcow2` | Once per release |
| `latest.json` | `https://nightly.omarchy.org/<channel>/latest.json` (`edge`, `edge-aarch64`, `edge-snapdragon`, `stable`) | With each nightly build |

Every ISO and VM image ships with a `.sha256` sidecar (release ISOs also have `.sig`; VM images have an `unpacked/` folder). On `nightly.omarchy.org`, published files are immutable; only `latest.json` updates, written last after CDN readback verification.

### Nightly builds and `latest.json`

`.github/workflows/nightly-build.yml` runs nightly for four channels: `edge` (x86_64 ISO + VM image from `omarchy-dev`), `edge-aarch64` (`--arch aarch64 --edge`, ISO only, plus N1x install test), `edge-snapdragon` (`--snapdragon --edge`, ISO only), and `stable` (downloads and GPG-verifies the latest release ISO from `iso.omarchy.org` to seal a VM image; scheduled runs skip already-published releases while manual runs rebuild).

Every ISO passes the PR install test, and x86_64 channels also pass `test/vm-image/vm-seal` and `test/vm-image/vm-verify` before publishing. Only the separate publish job holds the bucket key, and it runs only on `quattro` (on schedule, or manually when `publish` is enabled; default `false`). `test/vm-image/nightly-plan` and `test/vm-image/nightly-layout` drive the layout and `latest.json`, tested by `test/unit/nightly-test.sh`.

| Field | What it is |
| --- | --- |
| `version`, `channel`, `arch` | Date + run number (`2026.10.09.431`) or release (`4.0.4`); channel name; `arch: "aarch64"` on ARM channels (omitted on x86_64). |
| `built_at`, `url`, `sha256`, `size` | UTC write timestamp; installed ISO URL (nightly or `iso.omarchy.org`), SHA-256, and byte size. |
| `iso_commit`, `omarchy_version`, `omarchy_commit`, `kernel` | `omarchy-iso` commit, Omarchy package version, Omarchy commit (empty on `stable`), and `uname -r`. |
| `vm.url`, `vm.sha256`, `vm.size`, `vm.unpacked`, `vm.unpacked_files` | VM `.qcow2` metadata and `unpacked/` folder URL + file list (`edge` and `stable` only). |
| `vm.user`, `vm.password`, `vm.ssh` | Desktop/`sudo` credentials and key-only SSH notice (`edge` and `stable` only). |

## How the install works

- **Live boot & Just try:** Interactive media boot into the Omarchy Configurator inside `kmscon`. On x86_64 consumer ISOs, the welcome screen also offers **Just try**, which soft-reboots (`systemctl soft-reboot`) into a live Omarchy desktop over a tmpfs + `omarchy-root.sfs` + `omarchy-try.sfs` overlay without touching any disk.
- **Background prep units:** Once the greeter draws its logo (`omarchy-greeter-ready.service`, released immediately on unattended and OEM paths), background units verify the medium's SHA-256 checksums (`omarchy-mirror-verify.service`, `omarchy-root-image-verify.service`), calibrate LUKS Argon2id (`omarchy-luks-calibrate.service`), pre-build a per-machine pacman keyring, and warm the page cache.
- **Disk, encryption, and root image:** Before touching any disk, the orchestrator checks the verification verdicts, partitions and optionally encrypts the target (reusing cached LUKS Argon2id calibration when valid, and on capable machines — at least 4 CPUs, 4 GiB usable RAM, and 2.5 GiB available RAM — deferring full-disk slot-0 Argon2id enrollment to a background thread in parallel with the rest of the install before removing the temporary slot prior to `@factory`), and writes the pre-built Arch Linux + Omarchy btrfs root image (`omarchy-root.sfs`) in parallel with `omarchy-image-write`.
- **System setup, boot, and handoff:** The orchestrator assigns a fresh filesystem ID, grows the filesystem and reshapes its subvolumes, extracts any matching pre-packed hardware/platform layer and installs remaining per-machine packages from the bundled offline mirror, creates the user, and runs `omarchy-apply-system` in the chroot. Boot setup (`systemd-boot` on UEFI, Limine on BIOS and Intel T2 Macs) then runs in parallel with `omarchy-provision-user` (or defers user setup to first boot), followed by boot validation, a read-only `@factory` btrfs snapshot, and target unmount/close so the stick can be removed before rebooting.

## Guides

- [VM images](docs/vm-images.md) — booting nightly and release `.qcow2` images with QEMU, `vm-boot`, or libvirt, and injecting SSH keys via SMBIOS credentials.
- [Autoinstall](docs/autoinstall.md) — unattended installs from a `cidata` drive, SSH and Tailscale provisioning, region selection, and Proxmox setup.
- [OEM ISO](docs/oem.md) — factory installation media, OEM branding/logo/EULA bundles, and post-install setup scripts.
- [Translations](docs/translations.md) — installer language catalogs, `kmscon` XKB/CJK rendering, and Terminus console fallbacks.
- [NVIDIA N1x laptops](N1X.md) — normal and dev-SSH aarch64 builds, platform differences, and hardware notes for N1x laptops.
