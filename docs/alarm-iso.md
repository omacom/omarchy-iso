# Building the Omarchy ISO for aarch64 / Arch Linux ARM

Working notes for the `aarch64-support` branch. Companion to
`plans/aarch64-support.md` — that document is upstream's plan; this one records
what actually happened when it was implemented, including the places the plan is
wrong.

Status: **the ISO builds and passes structural verification. It has never been
booted or installed.** Treat "builds", "boots", and "installs a working system"
as three separate claims; only the first is demonstrated. Everything below
marked "verified" was checked directly on this machine.

`test/unit/iso-structure-test.sh` asserts the invariants that separate an ISO
which merely built from one that can boot. It runs against `release/*.iso` when
one is present and skips otherwise, so `test/all` stays fast and VM-free.

---

## Build command

```bash
cd ~/Projects/omarchy-iso
OMARCHY_PKGS_MIRROR='https://snapdragon-omarchy.mattgilg.com/aarch64' \
OMARCHY_EXTRA_PKGBUILDS='tzupdate tensaku hyprland-preview-share-picker' \
  ./bin/omarchy-iso-make --arch aarch64 --keep-pkg-cache --no-boot-offer \
    --local-source ../omarchy ../omarchy-pkgs
```

The tracked aarch64 configs use a global HTTPS mirror set: a CDN first, then
independent mirrors in Denmark, Germany, California, and Florida. The ALARM
GeoIP hostname is deliberately absent because its certificate does not cover
`mirror.archlinuxarm.org`. Set `OMARCHY_BASE_MIRROR` only when a build must pin
every base repository to one server; single-quote its value so pacman's `$arch`
/ `$repo` placeholders reach the config unexpanded.

`--keep-pkg-cache` is not optional in practice. Without it, `omarchy-iso-make`
runs `sudo rm -rf /var/cache/pacman/pkg/*` against the **host**, which (a) needs
an interactive password so unattended runs die immediately, and (b) wipes the
local package cache — worth keeping on a hand-assembled ALARM box.

`--no-boot-offer` skips the post-build QEMU offer, which cannot work yet (see
Remaining work).

### Prerequisites on the package host

The bucket must serve a database whose filename matches the pacman section name.
The tracked configs declare `[omarchy]`, so the bucket needs `omarchy.db` —
pacman derives the database name from the section name, and a mismatch 404s every
sync. `snapdragon-omarchy.db` alone is not enough.

This was solved by adding an `omarchy.db` copy alongside the existing one rather
than by renaming anything, so the local `/etc/pacman.conf` `[snapdragon-omarchy]`
section keeps working. That copy goes stale on republish, and the failure is
quiet — the build just resolves an older package set. Make it a step in whatever
publishes the repo.

---

## Environment facts (verified)

| Fact | Value |
|---|---|
| Kernel package | `linux-aarch64` — there is **no** `linux` package on ALARM |
| Package compression | `.pkg.tar.xz` (Arch uses `.pkg.tar.zst`) |
| `archiso` package | **not packaged for ALARM** |
| `mkinitcpio-archiso` | `extra 73-1` — present, and required |
| `limine` | `extra 12.6.1-1` |
| `archinstall` | `extra 4.4-1` |
| `edk2-armvirt` | **not in ALARM** — blocks QEMU boot testing |
| Repo layout | `$arch/$repo`, e.g. `/aarch64/core/core.db` |

ALARM's layout is **not** Arch's `$repo/os/$arch`, and has no `/os/` component:

```
https://fl.us.mirror.archlinuxarm.org/aarch64/core/core.db    200
https://fl.us.mirror.archlinuxarm.org/aarch64/alarm/alarm.db  200
https://mirror.archlinuxarm.org/aarch64/core/core.db          TLS hostname failure
https://mirror.archlinuxarm.org/core/os/aarch64/core.db       wrong layout
https://pkgs.omarchy.org/stable/aarch64/omarchy.db           404
```

ALARM also carries a third base repo, `[alarm]`, alongside `core` and `extra`.
There is no `[multilib]` (32-bit x86) and no `[arch-mact2]` (Apple T2, x86-only).

---

## Package availability

Omarchy's install lists are written for x86_64. Populating the offline mirror on
aarch64 surfaced **41 unresolvable packages**, and pacman aborts the entire
`-Syw` transaction on the first one — so every single one has to be dealt with
before a build completes.

They split three ways:

**38 excluded** — `builder/aarch64-excludes.packages`. Mostly hardware that
cannot exist on ARM: Apple T2 (`linux-t2`, `t2fanrd`, `apple-bcm-firmware`),
Intel (`thermald`, `intel-media-driver`, `vpl-gpu-rt`, `linux-ptl`), NVIDIA and
32-bit x86, x86 laptop drivers (`tuxedo-drivers`, `yt6801-dkms`, Dell XPS), and
x86 VM guest tooling.

The last group in that file is different in kind and worth revisiting: `obsidian`,
`obs-studio`, `pinta`, `dotnet-runtime`, `reflector`, `yay-debug` are not ARM
impossibilities, just absent from ALARM. Excluding them is a real reduction in
what the installed system offers. Build them for aarch64 and drop them from the
exclude list if any matter.

**3 built locally** — via `OMARCHY_EXTRA_PKGBUILDS`:

| Package | Why it cannot be excluded |
|---|---|
| `tzupdate` | listed in `arch_packages`, so the **live ISO itself** installs it |
| `tensaku` | Omarchy runtime dependency |
| `hyprland-preview-share-picker` | Hyprland screen-share picker |

All three have PKGBUILDs in `omarchy-pkgs` but no aarch64 build published. They
do **not** need publishing to the bucket first: `profiledef.sh` sets
`pacman_conf="pacman-offline.conf"`, so the live ISO pacstraps out of the offline
mirror, and a locally built package lands there directly. Building them properly
into the repo is still the better long-term answer.

The remaining 12 with PKGBUILDs (`linux-ptl`, `macbook12-spi-driver-dkms`,
`nvidia-580xx-utils`, `intel-ipu7-camera`, `asusctl`, `qmk-hid`, the Dell ones,
…) are x86 hardware support — correct to exclude, not to build.

---

## Errors in `plans/aarch64-support.md`

Each of these would break a build or produce a broken artifact.

| § | Plan says | Reality |
|---|---|---|
| 3, 6 | "use plain `linux`" | ALARM has only `linux-aarch64`; releng's `linux` entry must be **remapped**, not dropped |
| 6 | "releng's own `linux.preset` covers the stock kernel" | Presets are keyed by **pkgbase**. `linux.preset` is sourced by nothing on ARM, so the package's stock preset wins and builds an initramfs with **no archiso hook** — ISO builds clean, then won't boot |
| 7 | one `custom_servers` block at lines 422–424 | **Two** blocks (now 861 and 1248). Fixing one leaves the installer broken depending on which wizard path the user walks |
| 7 | T2 kernel probe needs "no change strictly required" | `detect_kernel()`'s `else` returns `linux`, which does not exist on ALARM — archinstall would install a system with no kernel |
| 8 | `$repo/os/$arch` "adapts automatically" | False for ALARM; the `Server` template must be rewritten, not re-pointed |
| — | not mentioned | `archiso` is not packaged for ALARM. `mkarchiso` must come from the pinned submodule, and `mkinitcpio-archiso` must be installed separately for the hooks |
| — | not mentioned | Package compression differs (xz vs zstd). Four hardcoded `.pkg.tar.zst` globs; the `repo-add` one **silently indexes nothing** rather than erroring |
| — | not mentioned | The offline-repo build cache is keyed only on channel, so parallel dual-arch builds poison each other with wrong-arch packages |
| — | mentions only microcode in `archinstall.packages` | Omarchy's own install lists carry **41** packages unavailable on ARM. pacman aborts the whole transaction on the first, so all 41 must be resolved |
| — | not mentioned | ALARM installs its kernel as `/boot/Image`; archiso hard-globs `/boot/vmlinuz-*` in four places and finds nothing |
| — | not mentioned | `linux-aarch64` **owns** `/etc/mkinitcpio.d/linux-aarch64.preset`, so the profile cannot ship one, and its stock preset builds against `/etc/mkinitcpio.conf` — which `omarchy-settings` replaces with the *target* system's hooks. The live initramfs then has no `archiso` hook and the ISO panics on boot, after building perfectly |
| — | not mentioned | archiso's `grub-mkstandalone` module list is x86-derived; 7 modules have no arm64-efi equivalent and it aborts on the first missing one |
| — | not mentioned | Excluding `syslinux` (x86 BIOS) also removes `memdiskfind`, which archiso's `memdisk` initramfs hook needs. The hook must be dropped from `HOOKS` too |

### Where the plan is too pessimistic

- **§2 BCJ filter** — already resolved upstream. The airootfs moved from xz to
  zstd, which has no BCJ concept. Nothing to change.
- **Risk 1, "mkarchiso on aarch64 is less-trodden ground"** — overstated.
  archiso already ships `uefi_arch['aarch64']='AA64'` and emits `BOOTAA64.EFI`
  natively.
- **Build speed** — the plan budgets 30–60 min under QEMU binfmt from an x86
  host. This machine is native aarch64, so no emulation.

### The pattern

The plan covers *conditional logic* thoroughly and assumes the ARM toolchain is
otherwise interchangeable with Arch's. The real failures live in that assumption:
missing packages, different compression, different repo layout. Five of the seven
gaps produce a silently-broken artifact rather than a build error.

---

## Changes made

### `bin/omarchy-iso-make`
- `--arch x86_64|aarch64` flag with validation, default `x86_64`.
- Per-arch container: `menci/archlinuxarm:base-devel` + `--platform linux/arm64`.
- Passes `OMARCHY_ARCH`, `OMARCHY_PKGS_MIRROR`, `OMARCHY_BASE_MIRROR` through.
- Offline-repo cache key now includes the arch.

### `configs/profiledef.sh`
- `arch` reads `OMARCHY_ARCH`; `bootmodes` drops `bios.syslinux` on ARM (no BIOS).
- x86_64 output is byte-identical to `quattro` — verified.

### `builder/build-iso.sh`
- Derives `packages.aarch64` from releng: prunes x86-only entries, **remaps
  `linux` → `linux-aarch64`**.
- Installs `mkinitcpio-archiso` + mkarchiso's callouts instead of `archiso`; runs
  the vendored `/archiso/archiso/mkarchiso`.
- Node.js `linux-arm64` tarball.
- No `linux-t2` on ARM; guards the T2-pruning block.
- Filters microcode from `archinstall.packages` and from the live initramfs
  `HOOKS`.
- Prunes the wrong-arch efiboot entry, points `loader.conf` at the right one,
  removes the syslinux tree, rewrites GRUB kernel filenames, drops the Intel
  `xe.enable_panel_replay` parameter.
- Selects `aarch64/pacman-online-<channel>.conf`; applies mirror overrides to a
  writable copy (`/configs` is mounted read-only).
- Accepts xz **or** zstd packages; `repo-add` now errors on an empty mirror
  instead of silently indexing nothing.

### `builder/build-omarchy-packages.sh`
- Accepts whichever `PKGEXT` the container produced.
- `OMARCHY_EXTRA_PKGBUILDS` builds additional pkgbuilds from `omarchy-pkgs`
  alongside the Omarchy packages, for packages with no build published for this
  architecture. `build-iso.sh` strips them from the `-Syw` list the same way it
  strips the locally built Omarchy packages.

### `builder/aarch64-excludes.packages` (new)
- The 38 packages dropped from the offline mirror on aarch64, grouped by reason.

### `configs/airootfs/root/configurator`
- `detect_kernel()` returns `linux-aarch64` on ARM.
- `MIRROR_SERVERS_JSON` branches on `uname -m`; both `custom_servers` blocks now
  reference it. x86_64 output unchanged — verified.

- Generates a `customize_airootfs.sh` that runs in the chroot after pacstrap:
  aliases `/boot/Image` to `/boot/vmlinuz-linux-aarch64` for archiso's globs, and
  rebuilds the live initramfs with
  `mkinitcpio -c /etc/mkinitcpio.conf.d/archiso.conf`. The kernel version comes
  from the package preset's `ALL_kver`, which is authoritative; the preset itself
  is left alone. It then asserts `archiso` and `archiso_loop_mnt` are present and
  the initramfs kernel matches, failing the build rather than shipping an ISO
  that panics. mkarchiso runs this under `set -e`, which a post-transaction
  pacman hook could not match (`AbortOnFail` is pre-transaction only).
- Patches a copy of the vendored `mkarchiso` to drop the 7 GRUB modules with no
  arm64-efi equivalent. The submodule itself stays pristine. This is the most
  fragile change here: if archiso reformats that list, the sed silently stops
  matching and the original error returns.

### New files
- `configs/efiboot/loader/entries/01-archiso-aarch64-linux.conf`
- `configs/aarch64/pacman-online-{stable,rc,edge}.conf`
- `builder/aarch64-excludes.packages`
- `test/unit/iso-structure-test.sh`

---

## Design note: mirrors stay out of tracked files

The tracked configs name **public** defaults: `pkgs.omarchy.org` plus a global
set of ALARM-compatible HTTPS mirrors. The GeoIP redirector is not included:
ALARM publishes it as HTTP, while forcing HTTPS fails hostname validation. The
private package bucket is supplied per build through `OMARCHY_PKGS_MIRROR`.

This means no tracked file names a personal mirror, so nothing has to be stripped
before upstreaming, and this branch works for anyone else the moment
`pkgs.omarchy.org` publishes an aarch64 tree. `OMARCHY_BASE_MIRROR` remains an
escape hatch for pinning a build to a single ALARM mirror.

`efiboot/loader/entries/` is worth understanding before editing: the
`uefi.grub` bootmode **validates** that the directory exists and holds at least
one `.conf`, but the code that installs those entries lives in the
`uefi.systemd-boot` path. So the files must exist, but `grub/grub.cfg` is what
actually boots. The load-bearing fix for ARM was the kernel filename in
`grub.cfg`, not the loader entry.

---

## Remaining work

- **§9** — `bin/omarchy-iso-boot`, `bin/omarchy-vm`: swap in
  `qemu-system-aarch64 -machine virt -cpu max`. Blocked on UEFI firmware:
  `qemu-system-aarch64` is in ALARM (`extra 11.1.1-1`) but `edk2-armvirt` is not,
  so AAVMF has to come from somewhere else before the ISO can be boot-tested
  locally.
- **§10** — `bin/omarchy-iso-release`: the ISO glob is hardcoded to `*x86_64-*`.
- **§11** — CI matrix.
- **End-to-end install** has never been run. Until it is, treat "the ISO builds"
  and "the ISO installs a working system" as separate claims.
- **The ISO has never been booted.** Bootability is currently inferred from the
  initramfs carrying the archiso hooks, not demonstrated.
- Three `mkinitcpio` errors during pacstrap are expected noise: `failed to detect
  root filesystem`, `Hook 'btrfs-overlayfs' cannot be found`, `module not found:
  'thunderbolt'`. They come from the stock preset building against the target
  system's config; that image is discarded and rebuilt by `customize_airootfs.sh`,
  and pacman treats hook failures as non-fatal. `btrfs-overlayfs` would only
  matter on the installed system, where the hook is present.
