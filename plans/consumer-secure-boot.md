# Consumer Secure Boot Plan: Microsoft Shim + MOK + UKI

## Goal

Support Omarchy installs on consumer laptops that ship with UEFI Secure Boot enabled and trust the Microsoft UEFI CA, without requiring users to disable Secure Boot.

This plan targets normal consumer hardware, especially Windows dual-boot machines. OEM-controlled hardware with Omarchy-owned firmware keys is a separate path.

## Current State (August 2026)

Where the repo stands today, and what that changes about this plan:

- The ISO builds with `bootmodes=('bios.syslinux' 'uefi.grub')` (`configs/profiledef.sh`): an unsigned GRUB as `BOOTX64.EFI` loading an unsigned kernel and initramfs. Firmware that trusts only the Microsoft UEFI CA rejects the ISO at the first stage, so Secure Boot must be disabled today.
- The vendored mkarchiso already supports a `uefi.systemd-boot` bootmode (mutually exclusive with `uefi.grub`), so the live-ISO half of `shim -> systemd-boot -> UKI` needs no archiso surgery — a bootmode switch plus signing.
- The installed system already boots a UKI: the orchestrator's `finalize_limine_boot` phase has mkinitcpio build the UKI onto the ESP, and `validate_boot` asserts it exists. "Build an installed UKI" is no longer new work; the new work is signing that UKI and choosing a second stage that enforces signatures.
- Kernel updates already regenerate the UKI through the target's mkinitcpio pacman hooks. The update flow below reduces to adding a signing step and fallback retention to machinery that exists.

The critical path is external: the Microsoft-signed shim. That requires an EV code-signing certificate for the Omarchy org, a shim built from a reviewed upstream release with Omarchy SBAT identity and NX compatibility, and a `shim-review` submission — historically weeks to months of calendar time, with standing obligations afterward (SBAT revocation response, resubmission when the embedded cert or shim version changes). Start it first; every phase below except release signing can proceed in parallel on dev test keys in QEMU.

## Core Architecture

Use a Microsoft-signed first-stage shim, then boot only signed Omarchy-controlled artifacts.

```text
Firmware Secure Boot
  -> Microsoft-signed Omarchy shim
    -> MokManager when key enrollment is pending
    -> signed second-stage boot manager
      -> signed Unified Kernel Image (UKI)
        -> encrypted Omarchy root
```

For the installed OS, use machine-local Machine Owner Key (MOK) signing for UKIs generated during install and later kernel updates.

## Why MOK For Installed Systems

Omarchy's installed UKI is machine-specific because it includes or depends on install-time data such as:

- Kernel command line for encrypted root.
- Initramfs generated for the installed system.
- Kernel package version selected at install or update time.

We must not ship Omarchy's private release signing key on the ISO or installed system. Therefore:

1. The official ISO is signed by Omarchy release infrastructure.
2. During install, generate a machine-local Secure Boot keypair.
3. Enroll the public certificate through MokManager.
4. Sign installed UKIs and update-generated UKIs with the local private key.
5. Store the local private key only on the encrypted installed root, never on the ESP.

This preserves offline tamper resistance for `/boot` while avoiding any central private key on user machines.

## Scope Constraints

- UEFI only.
- Microsoft UEFI CA trust path only for consumer machines.
- No custom firmware key enrollment for v1 consumer installs.
- No TPM auto-unlock for Omarchy root in v1.
- No attempt to modify Windows BitLocker protectors or TPM ownership.
- Secure Boot mode uses signed UKIs only; no unsigned external kernel, initramfs, or command line files.
- Secure Boot mode may use a different boot manager than the current Limine path until Limine has a proven verified-boot story.

## Bootloader Decision

Installed systems already boot a UKI through Limine, so the boot *artifact* needs no change. But signing Limine as an EFI binary is not sufficient if Limine will then load unsigned payloads or take direction from an unsigned `limine.conf`. For v1 Secure Boot support, use a boot path with a small, enforceable verification surface:

```text
shim -> systemd-boot -> signed UKI
```

Policy:

- Keep Limine as the normal non-Secure-Boot bootloader unless we later prove Limine enforces signed payloads correctly.
- Use systemd-boot only for Secure Boot installs if that is the fastest reliable path.
- Boot only UKIs with embedded command line and initramfs.
- Disable or avoid unsigned boot entry editing in Secure Boot mode.

If later validation proves Limine can enforce signed payloads behind shim, this plan can swap the second stage while keeping the shim, MOK, UKI, and signing architecture.

## Required Artifacts

### Omarchy Shim Artifacts

These are release artifacts, not generated on normal developer machines:

- `shimx64.efi`, signed by Microsoft UEFI CA.
- `mmx64.efi` / MokManager artifact compatible with the shim.
- Optional `fbx64.efi` fallback artifact if needed by the selected shim packaging.
- Shim SBAT metadata owned by Omarchy.
- Omarchy public release certificate embedded in shim.

Do not depend on another distribution's shim as a permanent product strategy. Omarchy needs its own shim submission, SBAT identity, revocation path, and release process.

### Omarchy Signing Material

Release infrastructure owns:

- Omarchy Secure Boot release private key, stored offline or in an HSM-backed CI secret store.
- Omarchy Secure Boot release public certificate, embedded in shim and shipped for verification.

Installed systems own:

- Machine-local MOK private key, stored on encrypted root with `0600` permissions.
- Machine-local MOK public certificate, enrolled through MokManager.

Private keys must never be committed to this repo.

## Build-Time Flow

Add a Secure Boot-capable ISO build mode.

```text
bin/omarchy-iso-make --secure-boot
```

Build behavior:

1. Switch the UEFI bootmode from `uefi.grub` to `uefi.systemd-boot` in `configs/profiledef.sh` (mkarchiso forbids running both). BIOS syslinux stays as-is; Secure Boot is UEFI-only.
2. Add Microsoft-signed Omarchy shim artifacts to the ISO UEFI boot path.
3. Build the live environment boot payload as a UKI.
4. Sign the live UKI with the Omarchy release key in official builds.
5. Sign any second-stage EFI binary with the Omarchy release key.
6. Assert that every Secure Boot UEFI entry uses the signed shim path.
7. Assert that no unsigned kernel/initramfs path is offered in Secure Boot UEFI mode.

Local developer builds should support a dev-signing mode for QEMU validation:

```text
OMARCHY_SECURE_BOOT_SIGNING_MODE=dev
```

Dev mode creates local test keys and is only expected to boot in QEMU firmware enrolled with those test keys. It must not be presented as Microsoft Secure Boot compatible.

## Installed-System Flow

When the live installer detects Secure Boot enabled:

1. Show a Secure Boot explanation before disk mutation.
2. If Windows is detected, follow the configurator's dual-boot BitLocker checks: free-space installation accepts suspended protection only when a working clear-key protector can be verified. Remind the user to keep the recovery key available.
3. Install Omarchy's shim to its own ESP directory, for example `EFI/Omarchy`.
4. Do not modify `EFI/Microsoft`.
5. Generate a machine-local MOK keypair under the installed encrypted root.
6. Build an installed UKI with embedded kernel, initramfs, command line, and OS release data.
7. Sign the installed UKI with the machine-local MOK private key.
8. Sign the selected second-stage boot manager with the machine-local MOK private key, unless it is release-signed and expected to remain static.
9. Schedule public certificate enrollment with `mokutil --import`.
10. Tell the user they must complete MokManager enrollment on the next reboot.
11. Preserve current firmware boot order by default on dual-boot machines.

Expected first reboot sequence after install:

```text
Firmware -> Omarchy shim -> MokManager -> user enrolls Omarchy machine key -> reboot -> Omarchy shim -> signed boot manager -> signed UKI -> LUKS unlock
```

## Kernel Update Flow

Secure Boot installs need deterministic UKI regeneration and signing after kernel or initramfs changes.

The regeneration half already exists: the target's mkinitcpio pacman hooks rebuild the UKI on kernel or initramfs changes. Add the signing half — a hook ordered after the UKI build that:

1. Signs the freshly built UKI with the machine-local MOK private key.
2. Writes it atomically to the ESP.
3. Keeps at least one previously booted signed UKI as fallback.

Failure policy:

- If signing fails, do not replace the currently bootable UKI.
- If ESP space is low, keep the current UKI and fail loudly.
- If the local signing key is missing, block the update from producing an unsigned boot artifact.

## File Changes

### `bin/omarchy-iso-make`

Add flags:

```text
--secure-boot       build Secure Boot-capable ISO flavor
--secure-boot-dev   build with local test keys for QEMU only
```

Pass mode and signing configuration into the Docker build environment.

### `builder/build-iso.sh`

Add Secure Boot build support:

- Copy shim artifacts into the UEFI boot path.
- Build live UKI.
- Sign live UKI and second-stage EFI artifact.
- Fail official Secure Boot builds if release signing material is unavailable.
- Write `/root/omarchy_secure_boot_mode` into the live environment.
- Assert that Secure Boot boot entries do not point at unsigned payloads.

### `builder/secure-boot/`

Add non-secret Secure Boot build inputs:

- Public release certificate.
- SBAT template.
- Artifact manifest with expected shim/MokManager checksums.
- Developer test-key generation script for QEMU only.

Do not store private keys in this directory.

### `configs/airootfs/root/configurator`

Add Secure Boot detection and UX:

- Detect UEFI Secure Boot state through efivars and/or `mokutil --sb-state`.
- Detect Windows through ESP vendor paths and partition metadata (the dual-boot path's `detect_windows_esp` and BitLocker checks already exist — extend, don't duplicate).
- Explain one-time MokManager enrollment.
- Write `secure_boot.sh` with simple shell state for the install orchestrator.

Example state:

```bash
SECURE_BOOT_ENABLED=true
SECURE_BOOT_INSTALL=true
SECURE_BOOT_BOOTLOADER=systemd-boot
SECURE_BOOT_UKI=true
SECURE_BOOT_MOK_COMMON_NAME="Omarchy Machine Owner Key"
```

### `configs/airootfs/usr/share/omarchy-iso/orchestrator/`

Add Secure Boot install support to the install phases:

- Read the `secure_boot.sh` state the configurator wrote.
- When `SECURE_BOOT_INSTALL=true`, install the shim boot path and the enforcing second stage instead of (or in front of) the plain Limine setup in `_configure_limine_boot`.
- Generate the machine-local MOK keypair on the installed encrypted root.
- Sign the UKI that `finalize_limine_boot` already builds.
- Schedule MOK enrollment with `mokutil --import`.
- Install the UKI signing hook alongside the existing mkinitcpio hooks.
- Preserve dual-boot firmware boot order unless explicitly promoted.
- Extend `validate_boot` to assert the UKI on the ESP carries a valid signature.

### Target System Files

Add installed files similar to:

```text
/etc/omarchy/secure-boot.conf
/etc/kernel/cmdline
/etc/pacman.d/hooks/90-omarchy-uki.hook
/usr/local/sbin/omarchy-build-uki
/usr/local/sbin/omarchy-sign-uki
/boot/EFI/Omarchy/shimx64.efi
/boot/EFI/Omarchy/mmx64.efi
/boot/EFI/Omarchy/systemd-bootx64.efi
/boot/EFI/Linux/omarchy-linux.efi
/boot/EFI/Linux/omarchy-linux-fallback.efi
```

Exact paths can change during implementation, but signed boot artifacts must stay under Omarchy-owned ESP directories.

## Package Requirements

Live ISO and installed Secure Boot path need tools for:

- Building UKIs.
- Signing PE/COFF EFI binaries.
- Importing MOK certificates.
- Inspecting Secure Boot state.

Candidate packages:

```text
sbsigntools
efitools
mokutil
openssl
systemd
```

Validate Arch package availability before implementation. Do not assume an official Arch `shim-signed` package exists.

## Dual-Boot Policy

On Windows dual-boot machines:

- Never modify Windows boot files.
- Never clear or change TPM state.
- Never change BitLocker protectors.
- Preserve existing firmware default boot order by default.
- Warn that adding a boot entry or changing ESP contents can trigger BitLocker recovery.
- Follow the configurator's current dual-boot policy. Keep the recovery key available, and do not change BitLocker protectors from the installer.

If the user chooses to make Omarchy first in boot order, capture the old `BootOrder` and provide rollback guidance.

## Security Model

Protected against:

- Offline replacement of unsigned kernels on the ESP.
- Offline modification of initramfs or kernel command line when UKI signature verification is enforced.
- Accidental boot of unsigned Omarchy boot payloads in Secure Boot mode.

Not protected against in v1:

- A compromised running root user signing malicious future UKIs with the local MOK key.
- Evil-maid attacks that trick the user into enrolling a malicious MOK.
- Attacks requiring TPM-measured boot or remote attestation.

Mitigations:

- Store local private key only on encrypted root.
- Make MokManager enrollment instructions explicit and brand-specific.
- Display expected certificate fingerprint before reboot.
- Keep release signing key outside shipped media.
- Keep SBAT metadata current for revocation response.

## QEMU Validation

Use QEMU with OVMF Secure Boot enabled and test keys enrolled.

Test matrix:

1. Secure Boot ISO boots with test shim/test db in OVMF.
2. Unsigned live UKI fails to boot.
3. Tampered live UKI fails to boot.
4. Secure Boot install completes to empty disk.
5. First installed boot enters MokManager enrollment flow.
6. After MOK enrollment, installed Omarchy boots and prompts for LUKS unlock.
7. Tampered installed UKI fails to boot.
8. Kernel update regenerates and signs a new UKI.
9. Failed signing leaves previous UKI bootable.
10. Dual-boot disk with Windows-style ESP preserves `EFI/Microsoft` and boot order.

QEMU cannot fully prove Microsoft production trust. Hardware validation is required with firmware that trusts Microsoft UEFI CA and has Secure Boot enabled.

## Hardware Validation

Minimum hardware tests:

1. Microsoft Secure Boot enabled laptop boots official Secure Boot ISO.
2. Windows dual-boot install preserves Windows boot.
3. BitLocker-decrypted install boots both OSes cleanly afterward.
4. BitLocker-active install warning is visible before any disk mutation.
5. Installed Omarchy boots only after MOK enrollment.
6. Secure Boot remains enabled after install.
7. Kernel update boots with newly signed UKI.
8. Manually tampered UKI is rejected.
9. Firmware boot order is preserved unless user opted to promote Omarchy.

## Rollout Plan

### Phase 1: Research And Decisions

- Kick off the EV certificate purchase and `shim-review` submission prep immediately — this is the calendar-bound item that gates Phase 4, and nothing else depends on it being done first.
- Confirm shim submission requirements and timeline.
- Confirm selected second-stage boot manager (systemd-boot unless Limine's signature enforcement is proven).
- ~~Confirm UKI generation mechanism on Arch~~ — resolved: mkinitcpio already builds the installed UKI today.
- Confirm package availability for signing and MOK workflows.
- Decide local MOK key storage and update-hook policy.
- Decide the DKMS/out-of-tree module signing story (see Open Questions — this is a v1 blocker, not a nice-to-have).

### Phase 2: Dev Secure Boot In QEMU

- Add dev keys and QEMU OVMF Secure Boot harness.
- Build a dev-signed live UKI.
- Boot ISO in QEMU with test keys.
- Prove unsigned and tampered payload rejection.

### Phase 3: Installed UKI + MOK Flow

- Generate local MOK key during install.
- Build and sign installed UKI.
- Schedule MokManager enrollment.
- Boot installed system in QEMU after enrollment.
- Add kernel update hook and fallback UKI handling.

### Phase 4: Official Shim And Release Signing

- Build Omarchy shim with SBAT metadata and embedded release cert.
- Submit shim artifacts for Microsoft signing.
- Integrate signed shim artifacts into official build pipeline.
- Add release signing with HSM/offline key handling.

### Phase 5: Consumer Dual-Boot UX

- Add Secure Boot and BitLocker warnings to configurator.
- Preserve Windows boot order by default.
- Add MOK enrollment instructions and certificate fingerprint display.
- Validate on real Windows hardware.

## Acceptance Criteria

- Official Secure Boot ISO boots on Microsoft Secure Boot hardware without disabling Secure Boot.
- Secure Boot install does not ship or expose Omarchy release private keys.
- Installed Omarchy boots through shim after MOK enrollment.
- Installed Omarchy root remains LUKS-encrypted and passphrase-unlocked.
- Kernel updates produce signed UKIs automatically.
- Tampered UKIs fail to boot.
- Windows ESP contents are preserved.
- Windows boot order is preserved by default.
- Secure Boot mode never offers an unsigned kernel/initramfs boot entry.

## Open Questions

- Whether Limine can enforce signature verification on the UKIs and config it loads; if not proven, Secure Boot installs use systemd-boot as the second stage while non-Secure-Boot installs keep Limine.
- Whether the local MOK private key should be encrypted with a user-supplied passphrase or stored root-only on encrypted root.
- How to support signed out-of-tree kernel modules, especially proprietary GPU drivers or DKMS packages. **This must be answered for v1:** once Secure Boot is enforcing, unsigned modules will not load, and NVIDIA laptops are exactly the consumer hardware this plan targets. The module signing hook must sign with the machine-local MOK alongside the UKI.
- How snapshot booting (factory reset restores from Btrfs snapshots) should work when each bootable kernel must be a signed UKI.
- Whether official builds should always be Secure Boot-capable or ship a separate Secure Boot ISO flavor.
- What user-facing recovery path should exist if MOK enrollment is skipped or fails.
