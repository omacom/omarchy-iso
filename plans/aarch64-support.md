# Plan: aarch64 (Generic UEFI ARM64) build for omarchy-iso

## Context

omarchy-iso currently produces a single x86_64 Arch Linux live ISO. The build is x86-baked from top to bottom — profile arch, package list filename, microcode, kernel choice (`linux-t2`), bootloader configs (BIOS syslinux + UEFI GRUB), squashfs BCJ filter, Node.js download URL, QEMU smoke-test, release filename, and CI runner.

Target: a parallel **generic UEFI aarch64** ISO — boots on Ampere servers, AWS Graviton VMs, Snapdragon X laptops, ARM dev kits. Anything that exposes vanilla UEFI + ACPI. Apple Silicon (Asahi) and SBCs (U-Boot/rpi-firmware) are out of scope.

**Assumption:** cross-repo dependencies are someone else's problem to land first. This plan only covers omarchy-iso. The hard prerequisites are listed up front so it's clear what blocks the first green build.

---

## Hard prerequisites (NOT in this plan, but block any green build)

These exist outside omarchy-iso. Flagged for visibility — without them, nothing here boots:

1. **aarch64 base packages must exist somewhere we can pacman from.** Vanilla Arch (`geo.mirror.pkgbuild.com`) is x86_64-only — there is no `core/os/aarch64`. The realistic source is **Arch Linux ARM** (`mirror.archlinuxarm.org`) for `core`/`extra`/`alarm`/`aur`. Decision required: target Arch Linux ARM as the aarch64 base distribution.
2. **`pkgs.omarchy.org/{stable,edge}/aarch64/`** must serve a real repo. Probed today, both return 404. omarchy-pkgs already has multi-arch build support per its README, so this is a publish step, not a port.
3. **Omarchy ISO architecture guard** must allow supported architectures or scope any x86_64-only checks behind an explicit guard.
4. **archinstall + Limine** must work end-to-end on aarch64. archinstall supports it; Limine supports aarch64 UEFI. Worth a manual verification before committing to this bootloader path on ARM.

---

## Approach

Add an `--arch aarch64` flag to `bin/omarchy-iso-make`. Branch on it everywhere x86_64 is currently assumed. Don't fork the profile directory — overlay arch-specific files at build time so the two architectures share one source of truth.

Output artifact naming already uses no arch suffix until release-time renaming, so two parallel builds coexist cleanly.

---

## Concrete changes

### 1. Build entrypoint — `bin/omarchy-iso-make`

- Add `--arch x86_64|aarch64` flag (default `x86_64` for backward compat).
- Pass `OMARCHY_ARCH` env var into the container.
- Switch the docker image / platform per arch:
  - x86_64: `archlinux/archlinux:latest` (unchanged)
  - aarch64: `archlinuxarm/archlinuxarm:latest` (or `menci/archlinuxarm` — pick whichever publishes a recent multi-arch image), with `--platform linux/arm64`. Native arm64 host preferred; QEMU emulation works but is slow.
- Don't change pacman cache mount on the host: pacman keeps per-arch subdirs, so the cache is safe to share.

### 2. Profile — `configs/profiledef.sh`

Change `arch` and the squashfs BCJ filter at runtime. Either:
- Keep one `profiledef.sh` and have `builder/build-iso.sh` `sed` the arch line + BCJ filter (`x86` → `arm`) before `mkarchiso` runs, **or**
- Source `OMARCHY_ARCH` directly inside `profiledef.sh` (mkarchiso sources this file with bash, so env access is fine).

`bootmodes` also needs to drop `bios.syslinux` for aarch64 (BIOS boot is x86-only) — `bootmodes=('uefi.grub')` on ARM.

### 3. Build script — `builder/build-iso.sh`

- **Line 56–57**: Node.js URL grep. Branch on `OMARCHY_ARCH`:
  - `x86_64` → `linux-x64.tar.gz`
  - `aarch64` → `linux-arm64.tar.gz`
- **Line 73**: package additions. Drop `linux-t2` for aarch64 (T2-only x86 kernel) — use plain `linux`. Write to `packages.${OMARCHY_ARCH}` instead of hardcoded `packages.x86_64`.
- **Line 77**: read same `packages.${OMARCHY_ARCH}` for offline mirror enumeration.
- **archiso releng overlay** (`cp -r /archiso/configs/releng/*`): the upstream `releng` profile ships only `packages.x86_64`. For aarch64, copy `packages.x86_64` to `packages.aarch64` and prune obviously x86-only entries (`memtest86+`, `intel-ucode`, `amd-ucode`, `edk2-shell` x64 binary, `syslinux`). Land this as a small fixup step in `build-iso.sh` rather than a full fork of `releng`.

### 4. archinstall package list — `builder/archinstall.packages`

Drop microcode for aarch64 — `intel-ucode` and `amd-ucode` don't exist for ARM. Either:
- Two lists (`archinstall.packages.x86_64`, `archinstall.packages.aarch64`), or
- One list with sentinel comments and a filter step in `build-iso.sh:80` that drops microcode lines when `OMARCHY_ARCH=aarch64`.

The second is less duplication for one-line drift.

### 5. Bootloader configs

aarch64 has no BIOS — only UEFI. Drop the syslinux path entirely on ARM.

- **Skip on aarch64**: `configs/syslinux/*` (BIOS syslinux), `configs/grub/*` references to `shellx64.efi`/`shellia32.efi` (lines 81–85 of `grub.cfg`).
- **`configs/efiboot/loader/loader.conf`**: change `default 01-archiso-x86_64-linux.conf` to a per-arch entry. Either two loader.conf files (selected by build-iso.sh) or rename the entry generically (`01-archiso-linux.conf`) and keep one file.
- **`configs/efiboot/loader/entries/01-archiso-x86_64-linux.conf`**: produce an aarch64 sibling (`01-archiso-aarch64-linux.conf`) at build time — same template, drop microcode initrd lines, swap title. The kernel/initrd paths use `%ARCH%` already in `grub.cfg` but are hardcoded `x86_64` in this file (line 3–4).
- **`configs/grub/grub.cfg` and `loopback.cfg`**: remove or guard the x86_64 conditionals. The `%ARCH%` placeholder gets substituted by mkarchiso from `profiledef.sh:arch`, so the kernel/initrd paths flip automatically. Manually-written `grub_cpu == 'x86_64'` blocks (lines 34–39, 68, 81–85) should drop on aarch64 builds — easiest done with a build-time sed for the aarch64 path, or by extracting them into a separate `grub-x86_64.cfg.fragment` only included on x86 builds.

The cleanest cut: keep one `grub.cfg` shared, strip the x86 shell/memtest fragments at build time when `OMARCHY_ARCH=aarch64`. Don't fork the file.

### 6. mkinitcpio preset — `configs/airootfs/etc/mkinitcpio.d/linux-t2.preset`

Names `vmlinuz-linux-t2` and `initramfs-linux-t2.img`. The filename is the pkgbase and the alpm hook keys off it, so aarch64 does not rename this file — it simply does not ship it, and releng's own `linux.preset` covers the stock kernel. Drop `linux-t2` from `arch_packages` on aarch64 and the boot entries point at `vmlinuz-linux` / `initramfs-linux.img`.

### 7. Configurator — `configs/airootfs/root/configurator`

Lines 320–325:
```bash
if lspci -nn 2>/dev/null | grep -q "106b:180[12]"; then
  kernel_choice="linux-t2"
else
  kernel_choice="linux"
fi
```
T2 detection is harmless on aarch64 (`lspci` returns no match), so `kernel_choice` falls through to `linux`. **No change strictly required**, but clearer to wrap the lspci probe in `[[ $(uname -m) == "x86_64" ]]` so the intent reads correctly. Cheap.

The archinstall JSON's `mirror_config.custom_servers` (lines 422–424) points at `mirror.omarchy.org`, `mirror.rackspace.com/archlinux`, `geo.mirror.pkgbuild.com` — none of these serve aarch64. For aarch64 the list must be `mirror.archlinuxarm.org` and friends. Branch the JSON template on `OMARCHY_ARCH` (or `uname -m` at runtime, since this file runs on the live ISO).

### 8. pacman configs — `configs/pacman-online-{stable,rc,edge,offline}.conf`

The `$arch` placeholder is pacman-resolved (matches `Architecture = auto`), so `https://stable-mirror.omarchy.org/$repo/os/$arch` adapts automatically — **as long as the mirror serves aarch64**. The omarchy mirror is the bottleneck (prerequisite #2). The `arch-mact2` repo is x86-only by definition; gate it behind arch on aarch64 builds (drop the section).

### 9. Smoke-test scripts — `bin/omarchy-iso-boot`, `bin/omarchy-vm`

Detect arch from the ISO filename (or accept a flag) and switch:
- x86_64: `qemu-system-x86_64`, `/usr/share/edk2/x64/OVMF_CODE.4m.fd` + `OVMF_VARS.4m.fd` (unchanged).
- aarch64: `qemu-system-aarch64`, `-machine virt -cpu max`, `/usr/share/edk2/aarch64/QEMU_CODE.fd` + `QEMU_VARS.fd` (Arch package: `edk2-armvirt`).

Both scripts hardcode the OVMF path; small, mechanical fix.

### 10. Release script — `bin/omarchy-iso-release:52`

```bash
latest_iso=$(\ls -t "$BUILD_RELEASE_PATH"/*${OMARCHY_ARCH}-"$ISO_REF".iso | head -n1)
```
Hardcoded `x86_64` glob. Take an arch arg, or do `*${OMARCHY_ARCH}-${ISO_REF}.iso`. The ISO filename already contains arch (set by archiso from `profiledef.sh`), so this just needs the glob parameterized.

### 11. CI — `.github/workflows/nightly-build.yml`

Add a matrix:
```yaml
strategy:
  matrix:
    arch: [x86_64, aarch64]
    include:
      - arch: x86_64
        runner: ubuntu-latest
      - arch: aarch64
        runner: ubuntu-24.04-arm   # GitHub-hosted ARM runner, GA
```
Pass `--arch ${{ matrix.arch }}` to the build. Upload artifacts named per-arch.

If GitHub-hosted ARM runners aren't available on this org's plan, fall back to QEMU emulation on `ubuntu-latest` (slow, ~3-4× build time) or self-hosted.

---

## Files to modify (summary)

Code:
- `bin/omarchy-iso-make` — add `--arch` flag, branch docker image/platform
- `bin/omarchy-iso-boot` — branch QEMU binary + OVMF path
- `bin/omarchy-vm` — same as iso-boot
- `bin/omarchy-iso-release` — parameterize ISO glob
- `builder/build-iso.sh` — main branching: Node.js URL, package list filename, releng overlay fixups, kernel package
- `builder/archinstall.packages` — filter microcode on aarch64 (sentinel comments + filter step)
- `configs/profiledef.sh` — env-driven `arch` + BCJ filter + bootmodes
- `configs/efiboot/loader/loader.conf` — per-arch default entry
- `configs/efiboot/loader/entries/01-archiso-x86_64-linux.conf` — generate aarch64 sibling at build time
- `configs/grub/grub.cfg`, `loopback.cfg` — strip x86-only fragments on aarch64
- `configs/airootfs/etc/mkinitcpio.d/linux-t2.preset` — omit on aarch64 (drop linux-t2 there; releng's linux.preset covers the stock kernel)
- `configs/airootfs/root/configurator` — branch archinstall JSON mirror list on `uname -m`; optionally guard lspci T2 probe
- `.github/workflows/nightly-build.yml` — matrix x86_64/aarch64

No new files unless we go the dual-list route on archinstall.packages or efiboot loader entries; preferred path is build-time templating to keep one source of truth.

---

## Verification

**Local (host is x86_64):**
1. `bin/omarchy-iso-make --arch x86_64` — must produce a byte-similar ISO to today's nightly (smoke test for regressions in the refactor).
2. `bin/omarchy-iso-make --arch aarch64` — succeeds (slow under QEMU binfmt; expect 30-60 min).
3. `bin/omarchy-iso-boot release/omarchy-*-aarch64-*.iso` — boots to the configurator under `qemu-system-aarch64 -machine virt`. Walk through the picker, confirm archinstall lays down a working system, reboot into the installed system.
4. Live-iso shell: `pacman -Sy && pacman -Si linux` returns an aarch64 package from `mirror.archlinuxarm.org`.

**On real hardware (post green QEMU run):**
- AWS Graviton VM (`c7g.medium`, dd ISO to a volume, attach as boot) — fastest cloud check, no hardware needed.
- One physical ARM64 UEFI box if available (Ampere dev kit, Snapdragon X laptop, etc.) — the long pole.

**CI:**
- Both matrix legs go green on a manual `workflow_dispatch` before merging.
- Nightly produces both ISOs as artifacts.

---

## Open risks (call out before implementation)

1. **mkarchiso on aarch64 is less-trodden ground.** It accepts `arch="aarch64"`, but the upstream Arch project doesn't dogfood it. Expect to file/patch around small bugs in archiso's helper scripts. Keep the archiso submodule pin tight so a regression doesn't surprise nightly.
2. **Limine + LUKS + Btrfs + Snapper on aarch64** — every one of these works individually on ARM, but the combination is what omarchy ships. Worth one manual end-to-end pass before declaring done.
3. **Apple T2 / linux-t2 / `arch-mact2` repo** are silently dropped on aarch64; users mistakenly trying to install the aarch64 ISO on a T2 Mac will get an obviously-wrong result. The configurator could refuse to install when arch mismatch is detected, but that's outside this plan.

---

## Implementation status

The `--arch aarch64` build path from this plan is implemented as far as
omarchy-iso alone can take it; the hard prerequisites above still gate a
bootable image. What landed, by section:

| Section | State | Where |
| --- | --- | --- |
| 1. Build entrypoint | Done. `--arch x86_64\|aarch64` (default `x86_64`), `OMARCHY_ARCH` passed into the container, `menci/archlinuxarm:latest` with `--platform linux/arm64` for aarch64, arch-scoped offline-mirror cache directory, arch-suffixed ISO glob at rename time. | `bin/omarchy-iso-make` |
| 2. Profile | Done, the second option: `profiledef.sh` reads `OMARCHY_ARCH`; `bootmodes=('uefi.grub')` and an xz squashfs on aarch64 (ALARM's generic kernel has no SquashFS zstd). | `configs/profiledef.sh` |
| 3. Build script | Done. Arch selection lives in `builder/architecture.sh` + `builder/package-architecture.sh` (keyring, Node tarball, `packages.$ARCH`, build-host and live package sets, online pacman config, live kernel names); `build-iso.sh` stays one linear script reading those. The releng `packages.x86_64` → `packages.aarch64` rename-and-prune is `prepare_package_profile`. | `builder/build-iso.sh`, `builder/architecture.sh`, `builder/package-architecture.sh` |
| 4. archinstall package list | Done, the filter-step option: `filter_target_packages` drops microcode (and `tzupdate`, unpackaged on ALARM) and maps `linux` → `linux-aarch64` for the shipped `omarchy-*.packages` copies and `archinstall.packages`. `archlinuxarm-keyring` is added to the shipped base list. | `builder/package-architecture.sh` |
| 5. Bootloader configs | Done for GRUB: `bootmodes` drops syslinux on aarch64, and `prepare_media_profile` points `grub.cfg`/`loopback.cfg` at ALARM's `Image`/`initramfs-linux.img`; the `grub_cpu` guards already hide the memtest/shell entries. `efiboot/loader` (systemd-boot) is not in `bootmodes` and was left alone. | `builder/architecture.sh` |
| 6. mkinitcpio preset | Done: on aarch64 both `linux.preset` and `linux-t2.preset` are replaced by a generated `linux-aarch64.preset` (pkgbase-named, archiso preset only), and the `microcode`/`memdisk` hooks are dropped from `archiso.conf`. | `builder/architecture.sh` |
| 7. Configurator | Done: `LIMINE_EFI_BINARY` from `uname -m` (`limine_aa64.efi` on ARM), `detect_kernel` returns `linux-aarch64` there, and the `ttfx` logo animation is skipped when the binary is absent (no ALARM package). The orchestrator derives the Limine binary names per machine instead of hard-coding `limine_x64.efi`/`BOOTX64.EFI`. Keyboard layouts are validated against the target's kbd catalog rather than `localectl` (needs PID 1). | `configs/airootfs/root/configurator`, `orchestrator/phases_impl.py`, `orchestrator/context.py`, `orchestrator/keyboard.py` |
| 8. pacman configs | Done: `configs/pacman-online-arm.conf` (ALARM core/extra/alarm/aur, no `arch-mact2`). Its `[omarchy]` section points at `pkgs.omarchy.org/stable/aarch64`, which does not exist yet — see prerequisite 2 (omacom/omarchy-pkgs#277, issue #199). | `configs/pacman-online-arm.conf` |
| mkarchiso | archiso v87 assumes `vmlinuz-*`, an edk2-shell binary, and the full x86 GRUB module list. `builder/archiso-aarch64.patch` is applied to a copy of the submodule's `mkarchiso` for aarch64 builds only. | `builder/archiso-aarch64.patch`, `builder/architecture.sh` |
| 9. Smoke-test scripts | `bin/omarchy-iso-test` boots aarch64 ISOs (`qemu-system-aarch64 -machine virt`, `edk2-armvirt` on Linux, HVF + Homebrew qemu on Apple Silicon macOS). `bin/omarchy-iso-boot` and `bin/omarchy-vm` are still x86_64-only. | `bin/omarchy-iso-test` |
| 10. Release script | Not done: `bin/omarchy-iso-release` still globs `x86_64`. | — |
| 11. CI | Not done: no aarch64 matrix leg yet. | — |

Unit coverage: `test/unit/architecture-selector-test.sh` (flag → container/platform/naming),
`test/unit/arm-profile-test.sh` (selection, profile rewrite, patch, profiledef, pacman conf,
and that x86_64 is byte-for-byte untouched), `test/unit/test_arm_limine.py` (installer
architecture detection), `test/unit/test_keyboard.py`.

Still open before the first green aarch64 build, beyond the prerequisites: nobody has
run `--arch aarch64` end to end against a published aarch64 `[omarchy]` tree, so the
package closure (Hyprland and friends on ALARM's `extra`/`alarm`) is unverified.
