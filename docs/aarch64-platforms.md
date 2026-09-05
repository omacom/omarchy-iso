# AArch64 platform support

`configs/aarch64/platforms.json` is the source of truth for ARM machines that
need more than the generic `linux-aarch64` boot path. It keeps hardware support
in one ISO: the builder stages the union of the declared resources, and the
installer applies only the entry matching the target machine.

An entry in the manifest is not, by itself, a claim that a machine has been
tested. See [Current coverage](#current-coverage) for the validation state of
the entries shipped today.

## The support model

AArch64 support has three layers:

1. `linux-aarch64` is a multi-platform kernel. A separate kernel or ISO is not
   normally required for each board.
2. A SoC family shares most kernel modules, firmware packages, and boot
   arguments. For example, Snapdragon X Elite laptops based on `x1e80100` can
   start from the same family requirements.
3. Each board still needs its own hardware description and identity. A DTB is
   exact board data, not a generic driver bundle; it describes regulators,
   GPIOs, panels, input devices, buses, and power domains. Never substitute a
   DTB from a similar product.

The kernel package currently carries hundreds of Qualcomm DTBs, including the
upstream laptop DTBs. They are available inside the live root after Linux has
booted. A board whose firmware does not give Linux a usable hardware
description needs its selected DTB copied outside the squashfs so GRUB can load
it *before* the kernel. Declaring `boot.hardware_description` as
`dtb-override` is what asks the builder to make that second copy.

Staging the supported Snapdragon laptop DTB catalog is safe and inexpensive;
choosing the wrong board description is not. Do not turn the kernel's entire
Qualcomm tree (which also contains phones, routers, development boards, and
revision-specific variants) into an undifferentiated boot menu. Add one product
entry per board, with its exact DTB and SMBIOS selector. A manual live-boot
choice may be added while identity data is being collected, but automatic and
installed-system selection require a reliable match.

The same rule applies to initramfs contents. Drivers present in the universal
kernel are not necessarily included by `mkinitcpio`, and firmware filenames
constructed at runtime are not necessarily visible to `modinfo`. Everything
needed between kernel entry and encrypted-root unlock must be made explicit.

## Current coverage

| Platform | Hardware description | Declared coverage | Physical validation |
| --- | --- | --- | --- |
| Lenovo Yoga Slim 7x (83ED) | Explicit `x1e80100` DTB | DTB, Qualcomm package, pre-LUKS display/input/watchdog/retimer modules, dynamic GPU firmware | Full encrypted installation validated: the corrected initramfs renders the Plymouth LUKS prompt, Limine finalization completes, and the installed OS boots successfully |
| NVIDIA DGX Spark | Firmware | NVIDIA runtime and DKMS packages only | Early-boot dependency audit and physical installation are not complete |
| ASUS Ascent GX10 | Firmware | NVIDIA runtime and DKMS packages only | Early-boot dependency audit and physical installation are not complete |

Package-only entries for Spark and GX10 are intentional bring-up entries. They
must not be described as complete platform support until their storage,
display, input, watchdog, firmware, and encrypted-boot paths have been tested.

## Manifest reference

The document has a `schema_version`, a human-readable `description`, and a
`platforms` array. Each platform contains the following fields.

### Identity

- `id`: stable lowercase identifier used by tests and logs.
- `name`: human-readable product name.
- `match`: one or more SMBIOS selectors. Selectors are ORed; all fields inside
  one selector are ANDed. Matching is exact and case-sensitive after leading
  and trailing whitespace is removed. Supported fields are `sys_vendor`,
  `product_name`, and `product_version` from `/sys/class/dmi/id/`.

Use the smallest selector that uniquely identifies the board. Do not guess a
marketing name or match only a broad vendor string. Multiple selectors are
appropriate for confirmed firmware revisions that report different identities.

### Boot description

- `boot.hardware_description`: `firmware` when UEFI/ACPI supplies Linux with a
  usable description; `dtb-override` when the bootloader must supply one.
- `boot.dtb`: required only for `dtb-override`. It is the path relative to
  `/boot/dtbs` in the `linux-aarch64` package, such as
  `qcom/x1e80100-lenovo-yoga-slim7x.dtb`.
- `boot.kernel_cmdline`: persistent, platform-specific arguments appended to
  installed Limine entries. Each array item is one argument with no whitespace.

Kernel arguments must have a demonstrated requirement. Diagnostic arguments
such as extra logging, removed quiet mode, or a temporary timeout belong in a
test boot entry until hardware results justify making them permanent.

### Kernel

- `kernel.package` identifies the package used by the platform.
- `kernel.availability` is `iso` when the configured repositories can place it
  in the offline mirror, or `vendor-required` when support cannot be shipped in
  the ISO yet.

The existence of an upstream DTB does not prove the selected kernel has every
required driver enabled. Confirm the DTB exists in the exact kernel package
being built and verify the resulting machine, rather than relying on a newer
upstream source tree.

### Initramfs

- `initramfs.modules`: modules that must be present before root unlock. Use
  module names, not `.ko` paths.
- `initramfs.files`: absolute firmware paths under `/usr/lib/firmware` that
  must be copied even when automatic discovery misses them.
- `initramfs.omit_hooks`: exceptional removal of an inherited mkinitcpio hook.
  This is a diagnostic or last-resort compatibility mechanism; explain and
  test every use.

The installer writes these values to
`/etc/mkinitcpio.conf.d/zz-omarchy-aarch64-platform.conf`. The drop-in persists
across kernel upgrades. Do not solve a missing-firmware failure by embedding an
entire firmware tree in every initramfs.

### Packages

`packages` contains target packages needed only by the matched platform. The
builder downloads the union of all platform packages into the ISO's offline
repository; the installer installs only the matched entry's list. Every package
must exist for AArch64 in the configured repositories.

Package installation and initramfs inclusion are separate concerns. Installing
`linux-firmware-qcom` or `nvidia-utils` into the target does not make firmware
available before an encrypted root has been opened. Add early firmware to
`initramfs.files` when automatic inclusion cannot be proven.

## Adding a platform

### 1. Record exact identity

Collect the values on the physical machine; do not infer them from a product
page:

```sh
for field in sys_vendor product_name product_version; do
  printf '%s: ' "$field"
  cat "/sys/class/dmi/id/$field"
done
```

Record the firmware version and the exact product/SKU used for testing in the
pull request. If the installer cannot boot yet, obtain the same data from the
factory OS or a working ARM live environment.

### 2. Determine the hardware-description path

Establish whether the kernel successfully consumes ACPI or a DTB supplied by
firmware, or instead requires a bootloader DTB override. For an override:

- Select the exact upstream board DTB, including revision or display variants.
- Confirm it exists and is non-empty in the built `linux-aarch64` package.
- Add a distinct live GRUB entry so generic ARM systems never receive it.
- Verify the installed Limine entry receives the same DTB.

An upstream DTB makes a board a good support candidate, not automatically a
supported system. We still need its boot identity and pre-root dependency set.

### 3. Find the pre-root dependency closure

For an encrypted installation, inventory everything required before the LUKS
prompt can be displayed and operated:

- boot storage and its bus/controller;
- display controller, GPU, clocks, resets, PHYs, and panel/output path;
- built-in keyboard or the USB/I2C path used for input;
- watchdog and power-domain drivers that can reset or disable the board;
- firmware requested by any of those drivers.

Use the working system's journal and driver bindings as evidence. `lsmod`,
`modinfo -F firmware`, `/sys/bus/*/devices/*/driver`, and kernel logs are useful,
but none is complete alone. Search driver source or trace firmware requests
when filenames are selected from DT properties, SMBIOS identity, or chip IDs.

Start a same-SoC board from the established family list, then verify it. Copying
the X Elite baseline is reasonable for another `x1e80100` laptop; treating it
as proven without checking board-specific firmware and input/display paths is
not. A later SoC generation such as Kaanapali/X2 needs a separate family
baseline even though it uses the same multi-platform kernel.

### 4. Separate diagnosis from the permanent fix

Change one boot boundary at a time. Useful diagnostic images include a full
no-`autodetect` image and a delayed-KMS image. A black screen with a responsive
keyboard and successful blind passphrase is evidence of a display handoff
failure, not a stalled kernel or broken encryption.

Do not commit a huge diagnostic initramfs, permanently disable Plymouth, or
remove early KMS merely because it masks the symptom. Translate the result into
the smallest explicit module and firmware set that preserves the branded
unlock flow.

### 5. Validate the installed lifecycle

A platform is ready to be marked physically validated only after checking:

1. The live ISO boots using the intended entry.
2. Display and input work in the installer.
3. Installation completes from the offline repository.
4. The normal encrypted Limine entry shows a usable LUKS prompt.
5. The installed desktop starts and the expected hardware is functional.
6. `limine-update` preserves the selected DTB and arguments.
7. Regenerating the initramfs, including after a kernel update, preserves the
   declared modules and firmware.
8. A cold boot succeeds; a warm reboot alone is insufficient for firmware and
   watchdog validation.

In the pull request, state which checks were performed and retain logs for any
behavior that motivated a platform-specific setting.

### 6. Run repository checks

At minimum:

```sh
python -m unittest \
  test.unit.test_aarch64_platforms \
  test.unit.test_protected_esp_mount -q
git diff --check
```

Add or update matching tests for every new SMBIOS identity, DTB, required
package, and exceptional initramfs rule. The ISO build also fails when a
declared DTB is absent from the exact kernel package used for that image.

## Build and persistence boundaries

- `builder/build-iso.sh` copies the manifest into the live root, downloads the
  union of platform packages, and stages declared DTB overrides outside the
  squashfs.
- `_current_aarch64_platform()` matches the physical machine's SMBIOS identity.
- `_runtime_package_list()` installs packages only for the matched entry.
- `_configure_aarch64_platform_boot()` writes persistent mkinitcpio and Limine
  drop-ins into the target.
- The installed Limine post-hook reinserts the selected DTB into every generated
  Linux entry because `limine-update` rewrites `limine.conf`.
- `test/unit/test_aarch64_platforms.py` checks manifest safety, matching,
  persistent DTB injection, and early-boot configuration.

## Lenovo Yoga Slim 7x (83ED) findings

Observed on physical hardware on 2026-09-03:

1. The generic installed Limine entry supplied no DTB. The kernel did not
   initialize `sbsa_gwdt`, and firmware's reported 10-second watchdog reset the
   machine. Supplying `x1e80100-lenovo-yoga-slim7x.dtb` changed this from a boot
   loop to a continuing kernel boot.
2. The live ISO contained `linux-firmware-qcom`, but the target package set did
   not. The installed root therefore had no `/usr/lib/firmware/qcom`. The Yoga
   entry now selects that package from the offline mirror.
3. The target initramfs was about 20 MiB versus about 191 MiB for the working
   live image. The working unencrypted system's journal showed EFI framebuffer
   and NVMe at about 1.8 seconds, root mount at 2.86 seconds, and the Qualcomm
   firmware, I2C keyboard, and MSM display takeover at about 5 seconds. The
   encrypted target runs `kms` before root unlock.
4. A 159 MiB no-`autodetect` diagnostic image included 573 modules but omitted
   DT-selected firmware and reproduced the black screen. A 17 MiB delayed-KMS
   image booted after a blind passphrase, proving storage, encryption, watchdog,
   keyboard, kernel, and installed userspace were healthy.
5. An EFI-backed pre-unlock trace proved that loading the initial MSM module set
   was insufficient: from 2 through 17 seconds the only framebuffer remained
   `EFI VGA`, no DRM connectors appeared, and all three external DisplayPort
   controllers remained in deferred probe. Their `aux_bridge` instances could
   not acquire the downstream DRM bridges supplied by the Yoga's three Parade
   PS8830 USB-C retimers. The `ps883x` module appeared only after switch-root;
   it must therefore be explicit in the initramfs even though the internal
   panel is eDP.
6. The production entry retains early KMS and the branded Plymouth unlock. It
   explicitly includes the MSM display stack, PS8830 retimer bridge, I2C
   keyboard, SBSA watchdog, and the three dynamically selected GPU firmware
   files. On 2026-09-05, a full encrypted installation rendered the unlock
   prompt, completed Limine finalization, and booted successfully.
