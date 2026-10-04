# HP EliteBook and ThinkPad T14s Snapdragon support

This directory contains board firmware preparation, audio configuration and
boot dependencies used by the Omarchy Snapdragon ISO builder. It uses Dragon's
Arch Linux ARM kernel, systemd UKI hardware selection, installer and Limine flow.

## Build from a clean checkout

With Docker available and ARM64 execution supported (native ARM64 or configured
binfmt/QEMU emulation), run from the repository root:

```sh
git submodule update --init --recursive
./bin/omarchy-iso-make-snapdragon
```

For QEMU user emulation that cannot implement pacman's Landlock sandbox, prefix
the command with `OMARCHY_BUILD_DISABLE_SANDBOX=1`. This changes the disposable
build configuration; the live/installed pacman configuration retains sandboxing.

The launcher fetches pinned official Dragon runtime and package sources and
passes them to the standard builder's `--local-source` mode. The package channel
currently lacks two required ARM packages and its settings recipe drops ARM UEFI
boot files, so the launcher applies the small checked-in ARM UEFI recipe patch.
The hardware builder fetches the team's pending kernel-metadata and firmware
extraction recipes by commit. None of this requires a preexisting source checkout.
Remove these temporary recipe adaptations when the package channel supplies the
same ARM contracts. Pins and patch are in `builder/prepare-snapdragon-sources.sh`,
`builder/fetch-snapdragon-recipes.sh`, and `builder/patches/snapdragon-arm-package-config.patch`.

The builder installs its extraction tools, downloads the [pinned inputs](inputs/README.md),
verifies their hashes, extracts the selected firmware, builds AudioReach topology,
generates HP UCM, and builds the board packages in a separate local hardware
repository. Dragon's edge channel supplies remaining dependencies. No
sibling checkout, manually built package archive, prior ISO or extracted root
is required. Output follows the normal launcher naming under `release/`.

The vendor downloads include a 4.15 GB Ubuntu ISO; budget disk space for both
archives and extraction. Builds require access to the pinned vendor URLs and
the selected Arch/Omarchy package mirrors. Firmware is pinned; the normal
rolling package channels are not a bit-for-bit ISO lockfile.

At the USB boot menu, HP/T14 owners select **Omarchy HP EliteBook / ThinkPad T14s**
for the tested early-DSP path. The standard entry retains the DSP guard used by
other Snapdragon boards.

The T14 Bluetooth DTB is built from the selected kernel's base tree and checked
against the tested input/output hashes. A different kernel DTB fails the build
for review instead of silently applying stale board data. The live UKI retains
`.dtbauto` sections and hardware-ID selection. The Wi-Fi power-ownership
hypothesis remains unimplemented in this foundation.

## Firmware-only verification

This optional native container isolates input preparation from ISO assembly:

```sh
docker build -t omarchy-firmware-builder:local -f builder/hardware/hp-t14/inputs/Dockerfile builder/hardware/hp-t14/inputs
mkdir -p build/firmware-check
docker run --rm -v "$PWD/builder/hardware/hp-t14:/hardware:ro" \
  -v "$PWD/build/firmware-check:/work" omarchy-firmware-builder:local --work-dir /work
```

`fetch-firmware.py --work-dir DIR` creates `DIR/firmware` only after every selected
file passes the checked-in manifests. Downloads are verified again before reuse.
`prepare-packages.py --work-dir DIR` requires those verified files and the pinned
ALSA UCM source contents supplied by `alsa-ucm-conf`; it creates `DIR/hardware`.
The normal Snapdragon builder runs both steps automatically. Vendor installers are extracted
as data, never executed. No Qualcomm SDK or QNN runtime is bundled.

## Hardware status

Both boards clean-installed the September 21 combined image with kernel 7.2.6-1.
That image predates the clean-checkout launcher above; physical boot of an ISO
assembled by the new launcher remains untested.
Speakers work on both. HP speech capture is owner-confirmed with one active PCM
channel; T14 microphone and media keys work. Bluetooth headphone playback works
on both. Automatic reconnection remains incomplete.

**Known T14 regression:** blocking Bluetooth drops the Wi-Fi PCIe link. The
isolated test captured Wi-Fi removal and kernel waits. A warm reboot left Wi-Fi
absent; power-off/start restored it. HP radio toggles work independently. Live
inspection finds both Wi-Fi and Bluetooth consumers on HP's WCN PMU, but only
Bluetooth on T14. That missing dependency remains under investigation. This
build-workflow change does not claim to fix it.

Camera, cDSP/NPU, suspend and battery validation remain open; HP function keys
are deferred. The pull request records physical results and remaining gaps;
hardware investigations can continue in a Dragon discussion.

The command above is the maintained build path.

## Validation of the clean-input workflow

Validated public downloads in a fresh native container against both archive and
final payload hashes. Built six hardware/support packages plus pinned Dragon
runtime and settings in fresh ARM containers; ARM package-content checks passed.
Reproduced the base/patched T14 DTB hashes. The 52 selected unit tests, BusyBox
boot-hook test and both upstream helper-recipe tests passed.

A first full clean build also completed the pinned Neovim source package. It
stopped at offline dependency resolution: the staged ARM pacman configuration
omitted Arch Linux ARM's `[alarm]` repository, which contains `libpisp` for
`libcamera`. The builder now includes ARM's standard `[alarm]` and `[aur]`
repositories in that disposable online config; an ARM pacman sync resolved
`libpisp 1.5.0-1` from `[alarm]`. A second full build was paused before ISO
assembly. A completed clean ISO and physical boot remain acceptance work.

Vendor binaries are fetched at build time and are absent from Git. Distribution
of an ISO containing extracted HP/Lenovo firmware requires a separate review of
their redistribution terms.
