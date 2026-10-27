"""Concrete phase implementations.

Phase ordering (full-disk and protected/pre-mounted):

    prepare_live           → disk cleanup when wiping, load configurator
                             handlers (archinstall patch happens in the
                             wrapper before Python imports it)
    prepare_install_target → everything that can fail before the disk is
                             touched: the pre-mounted target/ESP when the JSON
                             uses pre_mounted_config (a freshly made btrfs,
                             since the image replaces all of it), the root
                             image and its checksum, the package mirror's
                             checksums, and a disk layout the image can land
                             on
    arch_install_system    → one archinstall flow for partition/mount-or-use,
                             root image write, per-machine
                             package delta, Limine setup, useradd, fstab; the
                             per-machine pacman keyring starts as a transient
                             systemd unit after the last pacstrap
    configure_hibernation  → root-owned swap/resume drop-ins
    run_system_finalizer   → arch-chroot root omarchy-apply-system, including Snapper
    finalize_limine_boot   → final Limine config/UKI build after hardware drop-ins
    run_chroot_finalizer   → arch-chroot -u user omarchy-provision-user
    configure_login        → sddm state + encrypted-install autologin
    configure_ssh_access   → authorized_keys for autoinstall; no-op otherwise
    configure_tailscale    → tailnet join staged for first boot; no-op otherwise
    validate_boot          → assert UKI / limine.conf / kernel cmdline are sane,
                             that at least one UEFI boot route exists, and
                             that the target keyring trusts its packages
    create_factory_snapshot→ joins the keyring unit, then snapshots @ as @factory
"""

from __future__ import annotations
import platform

import fcntl
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import textwrap
import threading
import time
from dataclasses import replace
from pathlib import Path

from . import archinstall_adapter as arch
from .command import capture, capture_identifier, require_text
from .context import InstallContext, hw_platform, iso_kernel
from .keyboard import configure_keyboard
from .phases import write_state
from .ui import error, info


# Package targets are written by builder/build-iso.sh. Stable ISOs use the
# stable package names, while dev/local-source ISOs install the dev package
# names explicitly instead of relying on provides=omarchy resolution.
def _iso_ref() -> str:
    if ref := os.environ.get("OMARCHY_ISO_REF"):
        return ref.strip()

    ref_file = Path("/root/omarchy_iso_ref")
    if ref_file.exists():
        try:
            return ref_file.read_text().strip()
        except OSError:
            pass

    return "stable"


def _default_package_targets() -> dict[str, str]:
    if _iso_ref() in {"dev", "local"}:
        return {
            "runtime": "omarchy-dev",
            "settings": "omarchy-settings-dev",
            "nvim": "omarchy-nvim",
        }

    return {
        "runtime": "omarchy",
        "settings": "omarchy-settings",
        "nvim": "omarchy-nvim",
    }


def _package_targets() -> dict[str, str]:
    targets = _default_package_targets()

    targets_file = Path("/usr/share/omarchy-iso/package-targets")
    if targets_file.exists():
        try:
            for raw in targets_file.read_text().splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                value = value.strip().strip('"\'')
                match key.strip():
                    case "OMARCHY_RUNTIME_PACKAGE":
                        targets["runtime"] = value
                    case "OMARCHY_SETTINGS_PACKAGE":
                        targets["settings"] = value
                    case "OMARCHY_NVIM_PACKAGE":
                        targets["nvim"] = value
        except OSError:
            pass

    env_to_key = {
        "OMARCHY_RUNTIME_PACKAGE": "runtime",
        "OMARCHY_SETTINGS_PACKAGE": "settings",
        "OMARCHY_NVIM_PACKAGE": "nvim",
    }
    for env_name, key in env_to_key.items():
        if value := os.environ.get(env_name):
            targets[key] = value

    return targets


def _omarchy_runtime_package() -> str:
    return _package_targets()["runtime"]


def _omarchy_settings_package() -> str:
    return _package_targets()["settings"]


def _omarchy_nvim_package() -> str:
    return _package_targets()["nvim"]


# Sub-step timing: anything that takes 0.05 s or more gets a [step] line in
# the install log (/var/log/omarchy-install.log).
from contextlib import contextmanager as _contextmanager

def _check_dd_full_blocks(dd_stderr: str) -> None:
    """dd reports "N+M records out": N full blocks, M partial ones. More than
    one partial block means dd wrote pipe-sized pieces without O_DIRECT (see
    the image write), which costs a real disk a minute and a half and is
    invisible in a VM, so say so in the install log."""
    match = re.search(r"(\d+)\+(\d+) records out", dd_stderr or "")
    if not match:
        return
    full, partial = int(match.group(1)), int(match.group(2))
    info(f"› image write: {full} full blocks, {partial} partial")
    if partial > 1:
        info(f"› WARNING: dd wrote {partial} partial blocks; the image write "
             "was buffered, not direct (iflag=fullblock missing?)")


@_contextmanager
def _time_step(label: str):
    _t0 = time.monotonic()
    try:
        yield
    finally:
        _elapsed = time.monotonic() - _t0
        if _elapsed >= 0.05:
            info(f"[step] {label}: {_elapsed:.6f}s")


# The root image: the invariant target system as a btrfs filesystem image
# (build-root-image.sh), packed as independent 256 KiB zstd frames with a seek
# table and written onto the target partition in place of pacstrapping it.
# build-iso.sh ships it as a plain file on the ISO, read straight off the boot
# medium, with its sha256 next to it. Its one subvolume becomes @.
# archiso names the directory after the architecture, which is what
# platform.machine() says on the live system: arch/x86_64 or arch/aarch64.
ROOT_IMAGE_DIR = Path("/run/archiso/bootmnt/arch") / platform.machine()
ROOT_IMAGE = ROOT_IMAGE_DIR / "omarchy-root.img.zst"
ROOT_IMAGE_SUBVOLUME = "omarchy-root"
# Writes ROOT_IMAGE in parallel; compiled and installed by build-iso.sh.
IMAGE_WRITE = Path("/usr/local/bin/omarchy-image-write")


# The live ISO starts omarchy-root-image-verify.service at boot: `sha256sum -c`
# of the image, running while the user is in the configurator. It is the only
# verifier. Both this phase and the free-space configurator gate collect its
# verdict through this helper, which logs the boot medium and its I/O scheduler,
# waits for the unit if it is still hashing, and starts it if it never ran.
ROOT_IMAGE_VERIFY_HELPER = "/usr/local/bin/omarchy-wait-root-image-verify"
ROOT_IMAGE_VERIFY_UNIT = "omarchy-root-image-verify.service"
# The other half of the medium check: the shipped package mirror, hashed by
# its own unit (build-iso.sh writes the sums).
MIRROR_VERIFY_UNIT = "omarchy-mirror-verify.service"
MIRROR_SUMS = Path("/usr/share/omarchy-iso/offline-mirror.sha256")
OFFLINE_MIRROR = Path("/var/cache/omarchy/mirror/offline")


BOOT_MEDIUM_MOUNT = Path("/run/archiso/bootmnt")


def _root_image() -> Path:
    if not ROOT_IMAGE.is_file():
        # The archiso hook unmounts the boot medium after copying the airootfs
        # to RAM (copytoram). The boot entries pin copytoram=n, so this only
        # happens when someone edits the kernel command line.
        if not BOOT_MEDIUM_MOUNT.is_dir():
            raise RuntimeError(
                f"boot medium is not mounted at {BOOT_MEDIUM_MOUNT}: the live system was "
                "copied to RAM (copytoram) and the medium released; boot with copytoram=n"
            )
        raise RuntimeError(f"root image missing: {ROOT_IMAGE}")
    return ROOT_IMAGE

# Packages the image must carry for the rest of the install to work: Limine
# setup reads the settings package's limine config, useradd copies the skel the
# settings and nvim packages populate, and the target-side setup commands come
# from the runtime package. Checked right after the image is written so a
# mismatched image fails here with a clear message instead of three phases
# later.
ROOT_IMAGE_REQUIRED_PACKAGES = ("limine", "omarchy-keyring")


def _root_image_required_packages() -> list[str]:
    return [
        *ROOT_IMAGE_REQUIRED_PACKAGES,
        _omarchy_runtime_package(),
        _omarchy_settings_package(),
        _omarchy_nvim_package(),
    ]


# ─────────────────────────────────────────────────────────────────────────────
# prepare_live: ready the live ISO for the install — tear down any previous
# holders on the install disk (via the bash helper), then parse the
# configurator output.
#
# The live pacman keyring is deliberately NOT waited on. The offline repo is
# SigLevel = Never (see configs/pacman-offline.conf for why that is required:
# pacstrap verifies against the LIVE GpgDir, so anything short of Never makes
# installs depend on archiso's boot-time pacman-init.service). That service
# (gpg key generation + populating every keyring, Type=oneshot with no start
# timeout) can take minutes on real hardware reading from USB — blocking on
# it here stalled installs at 5% while it ground away in the background, and
# racing it failed pacstrap with "required key missing from keyring".
#
# archinstall is patched in the wrapper (omarchy-iso-install) BEFORE Python
# imports it, so no patching happens here.
# ─────────────────────────────────────────────────────────────────────────────

# Stage vendor-signed Qualcomm firmware before the Windows partition is removed.
LIVE_FIRMWARE_STAGE = Path("/run/omarchy/firmware")
TARGET_FIRMWARE_STAGE = Path("var/lib/omarchy/firmware-stage")


def _stage_qualcomm_firmware() -> None:
    tool = shutil.which("qcom-firmware-extract")
    if not tool:
        return
    info("› saving Qualcomm firmware from Windows before the disk is written")
    # Firmware extraction is idempotent and optional.
    subprocess.run([tool, "--stage", str(LIVE_FIRMWARE_STAGE)], check=False)


def _copy_firmware_stage_into_target(ctx: InstallContext) -> None:
    if not (LIVE_FIRMWARE_STAGE / "manifest").is_file():
        return
    dst = ctx.target / TARGET_FIRMWARE_STAGE
    shutil.copytree(LIVE_FIRMWARE_STAGE, dst, dirs_exist_ok=True)


def prepare_live(ctx: InstallContext) -> None:
    _stage_qualcomm_firmware()
    if ctx.is_protected:
        info("› protected mode: skipping whole-disk cleanup")
    else:
        disk = _install_disk(ctx)
        if disk:
            info(f"› cleaning up holders on install disk: {disk}")
            result = capture(["omarchy-iso-cleanup-disk", disk])
            for line in (result.stdout + result.stderr).splitlines():
                info(f"  {line}")
            if result.returncode != 0:
                # Its last line says what still holds the disk, for the failure screen.
                lines = result.stdout.strip().splitlines()
                raise RuntimeError(lines[-1] if lines else f"Could not release {disk}")

    info("› loading configurator output")
    ctx.state["arch_config_handler"] = arch.load_arch_config(
        ctx.arch_config_path, ctx.creds_path
    )
    ctx.state["mirror_handler"] = arch.make_mirror_handler(offline=True)


def _install_disk(ctx: InstallContext) -> str | None:
    """Return the device path of the disk being wiped, or None for
    pre_mounted / no-wipe configs."""
    config = ctx.user_configuration
    for mod in config.get("disk_config", {}).get("device_modifications", []):
        if mod.get("wipe"):
            return mod.get("device")
    return None


# ─────────────────────────────────────────────────────────────────────────────
# arch_install_system: everything inside a single Installer context manager.
# Reorders guided.py's perform_installation() so early Omarchy packages install
# before user creation and before our Omarchy-owned Limine setup copies files
# from the target's limine package.
# ─────────────────────────────────────────────────────────────────────────────

def prepare_install_target(ctx: InstallContext) -> None:
    """Everything that can fail before the disk is touched. The next phase
    partitions, formats and encrypts as its first step, and a failure after
    that leaves a wiped (or wiped and encrypted) disk with no system on it:
    so the image, its checksum and a layout the image can land on are all
    checked here, where failing costs nothing."""
    if ctx.is_protected:
        verify_protected_mounts(ctx)
        # The protected layout exists already; check the real mounts.
        _, device = _root_image_target_mounts(ctx.target)
        verify_pre_mounted_root_empty(ctx, device)
    else:
        verify_root_image_layout(ctx.user_configuration.get("disk_config") or {})
    verify_install_medium(ctx)


def verify_root_image_layout(disk_config: dict) -> None:
    """The root image replaces the target's @ subvolume, so the configurator
    JSON must put the root on a btrfs @ subvolume, and the image path has no
    LVM support (install_base_delta). Checked from the JSON so a layout the
    image cannot land on fails before archinstall creates it."""
    if disk_config.get("lvm_config"):
        raise RuntimeError("root image install does not support LVM layouts")

    for mod in disk_config.get("device_modifications") or []:
        for part in mod.get("partitions") or []:
            if part.get("fs_type") != "btrfs":
                continue
            subvols = part.get("btrfs") or []
            for subvol in subvols:
                if subvol.get("mountpoint") == "/" and subvol.get("name") in ("@", "/@"):
                    _verify_nested_subvolumes(subvols)
                    return
    raise RuntimeError(
        "root image install needs the target root on a btrfs @ subvolume; "
        "disk_config mounts / from no such subvolume"
    )


def _verify_nested_subvolumes(subvols: list[dict]) -> None:
    """A subvolume named inside another one (@/srv/data, @data/x) is made at
    that path after the image write and given the image's files under its
    mountpoint (_place_root_image). That only works where the path and the
    mountpoint agree: @/srv/data mounted at /srv would be copied into itself,
    and @/usr mounted at /opt would take the place of the image's /usr."""
    where = {
        str(sv["name"]).strip("/"): Path(sv["mountpoint"])
        for sv in subvols
        if sv.get("name") and sv.get("mountpoint")
    }
    for name, mountpoint in where.items():
        parents = [other for other in where if name.startswith(other + "/")]
        if not parents:
            continue
        parent = max(parents, key=len)
        expected = where[parent] / name[len(parent) + 1:]
        if mountpoint != expected:
            raise RuntimeError(
                f"root image install cannot place subvolume {name} at {mountpoint}: "
                f"a subvolume inside {parent} must be mounted at {expected}"
            )
        # An extra subvolume mounted between the two takes the image's files
        # there, this one's included (@/var/lib under a separate /var).
        between = [
            other for other, other_mountpoint in where.items()
            if other not in (name, parent, "@") and other not in CONFIGURATOR_SUBVOLUMES
            and mountpoint.is_relative_to(other_mountpoint) and other_mountpoint != mountpoint
            and other_mountpoint.is_relative_to(where[parent]) and other_mountpoint != where[parent]
        ]
        if between:
            raise RuntimeError(
                f"root image install cannot place subvolume {name} at {mountpoint}: "
                f"{between[0]} is mounted between it and {parent}; it must be mounted at "
                f"{mountpoint} inside {between[0]} instead"
            )


# The subvolumes the configurator creates on the btrfs it hands over.
PRE_MOUNTED_SUBVOLUMES = ("@", "@home", "@log", "@pkg")


def _pre_mounted_root_contents(top: Path, limit: int = 3) -> list[str]:
    """What the btrfs whose top level is mounted at top holds that a freshly
    made one does not, up to limit paths: anything at the top level but the
    configurator's subvolumes, and anything in those but directories (the
    configurator leaves the mountpoints for the others and the ESP in @).
    A snapshot or a nested subvolume with files in it shows up as its files."""
    found: list[str] = []
    pending = [top]
    while pending and len(found) < limit:
        directory = pending.pop()
        with os.scandir(directory) as entries:
            for entry in sorted(entries, key=lambda e: e.name):
                path = Path(entry.path)
                name = str(path.relative_to(top))
                if directory == top and entry.name not in PRE_MOUNTED_SUBVOLUMES:
                    found.append(name)
                elif entry.is_dir(follow_symlinks=False):
                    pending.append(path)
                else:
                    found.append(name)
                if len(found) >= limit:
                    break
    return found


def verify_pre_mounted_root_empty(ctx: InstallContext, device: str) -> None:
    """The root image is written over the whole device behind the target's
    @, not into @, so whatever else that btrfs holds goes with it: a /home
    on @home, snapshots, another system's subvolumes. A pre-mounted target
    must therefore be a filesystem made for this install, as the
    configurator's free-space path makes one (four empty subvolumes).
    Checked on the top level, mounted read-only, where each subvolume's
    own content shows without the mounts on top of it. Used space cannot
    tell: a small file in @home is stored inline in metadata blocks a fresh
    filesystem already has, and leaves it unchanged."""
    top = ctx.state_dir / "pre-mounted-top"
    top.mkdir(parents=True, exist_ok=True)
    subprocess.run(["mount", "-o", "ro,subvolid=5", device, str(top)], check=True)
    try:
        found = _pre_mounted_root_contents(top)
    finally:
        # Left mounted, it would hold the device the image is written to.
        subprocess.run(["umount", str(top)], check=True)
    if found:
        raise RuntimeError(
            f"protected mode: the btrfs on {device} already holds data "
            f"(found {', '.join(found)}). The root image replaces that whole "
            "filesystem, so Omarchy needs a freshly made btrfs there with only "
            "empty @, @home, @log and @pkg subvolumes; nothing has been written"
        )
    info(f"› pre-mounted btrfs on {device} is freshly made")


def verify_install_medium(ctx: InstallContext) -> None:
    """The image (and the package mirror) are present and hash to what the
    build recorded. A truncated or corrupt copy (a badly flashed USB is the
    common case) would also fail the write's per-frame checksums, but only
    after the disk is formatted.

    ROOT_IMAGE_VERIFY_HELPER is the single source of truth: it collects the
    boot-time hasher's verdict, waiting for the unit if it is still running
    and starting it if it never did, and logs the boot medium and its I/O
    scheduler. The free-space configurator gate runs the same helper before it
    partitions, so both disk-touching paths clear the same check; whoever gets
    there first pays the wait. The hasher's read also leaves as much of the
    image as fits in the page cache for the write that follows.

    The progress mirroring runs beside the helper, not before it: it waits as
    long as a hasher is activating, and a medium that stopped answering keeps
    it there until the size-based timeout, while the helper says so after a
    minute without progress."""
    helper_done = threading.Event()
    progress = threading.Thread(target=_publish_verify_progress, args=(ctx, helper_done), daemon=True)
    progress.start()
    try:
        result = subprocess.run(
            [ROOT_IMAGE_VERIFY_HELPER],
            capture_output=True, text=True, check=False,
        )
    except OSError as exc:
        raise RuntimeError(f"could not run {ROOT_IMAGE_VERIFY_HELPER}: {exc}") from exc
    finally:
        helper_done.set()
        progress.join()

    for line in result.stdout.splitlines():
        if line.strip():
            info(f"› {line.strip()}")

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or f"{ROOT_IMAGE_VERIFY_HELPER} failed with status {result.returncode}"
        )


def _publish_verify_progress(ctx: InstallContext, helper_done: threading.Event | None = None) -> None:
    """While the boot-time hashers are still reading the medium, mirror how far
    they are into phase_progress so the dashboard tracks the actual hash
    instead of the phase's time-driven band: the package mirror first, then the
    root image (the order their units run in), as one fraction of the bytes
    both read. Best effort throughout: the helper is the authority on the
    verdict, and any hiccup here (unit already done, hasher between opens,
    /proc gone) just skips a sample. Stops once helper_done is set: the
    helper has its verdict, even if a hasher is still activating."""
    def hashing(state: str) -> bool:
        return state == "activating" and not (helper_done and helper_done.is_set())

    try:
        image = ROOT_IMAGE.stat().st_size
    except OSError:
        return
    mirror = _mirror_files()
    mirror_total = sum(size for _, size in mirror)
    total = image + mirror_total
    if mirror:
        state = _verify_state_when_started(MIRROR_VERIFY_UNIT)
        while hashing(state):
            done = _mirror_bytes_hashed(mirror)
            if done is not None:
                _write_phase_progress(ctx, done / total)
            time.sleep(0.5)
            state = _verify_unit_property("ActiveState", MIRROR_VERIFY_UNIT)
        # The image's unit starts once the mirror's is done (the mirror's is
        # ordered Before= it).
        image_state = _verify_state_when_started(ROOT_IMAGE_VERIFY_UNIT)
    else:
        image_state = _verify_unit_property("ActiveState")
    while image and hashing(image_state):
        pos = _hasher_read_pos()
        if pos is not None:
            _write_phase_progress(ctx, (mirror_total + pos) / total)
        time.sleep(0.5)
        image_state = _verify_unit_property("ActiveState")


def _verify_state_when_started(unit: str) -> str:
    """A verify unit's ActiveState, given a moment to leave inactive: one
    ordered after another sits there until systemd starts its queued job."""
    for _ in range(10):
        state = _verify_unit_property("ActiveState", unit)
        if state != "inactive":
            return state
        time.sleep(0.2)
    return state


def _verify_unit_property(prop: str, unit: str = ROOT_IMAGE_VERIFY_UNIT) -> str:
    res = subprocess.run(
        ["systemctl", "show", unit, "-p", prop, "--value"],
        capture_output=True, text=True, check=False,
    )
    return res.stdout.strip()


def _hasher_positions(unit: str = ROOT_IMAGE_VERIFY_UNIT) -> dict[Path, int]:
    """Read offset of every file the unit's hasher has open: its MainPID is
    sha256sum while it runs, and fdinfo's pos is how far it has read."""
    pid = _verify_unit_property("MainPID", unit)
    positions: dict[Path, int] = {}
    if not pid.isdigit() or pid == "0":
        return positions
    fd_dir = Path("/proc") / pid / "fd"
    try:
        for fd in fd_dir.iterdir():
            try:
                path = fd.resolve()
                fdinfo = (fd_dir.parent / "fdinfo" / fd.name).read_text()
            except OSError:
                continue
            for line in fdinfo.splitlines():
                if line.startswith("pos:"):
                    positions[path] = int(line.split()[1])
    except OSError:
        pass
    return positions


def _hasher_read_pos() -> int | None:
    """How far the root image hasher has read the image."""
    return _hasher_positions().get(ROOT_IMAGE)


def _mirror_files() -> list[tuple[Path, int]]:
    """The files omarchy-mirror-verify.service hashes, in the order it hashes
    them (the sums file's), with their sizes; empty without a sums file."""
    files = []
    try:
        lines = MIRROR_SUMS.read_text().splitlines()
    except OSError:
        return files
    for line in lines:
        parts = line.split(None, 1)
        if len(parts) != 2:
            continue
        path = OFFLINE_MIRROR / parts[1].lstrip("*")
        try:
            files.append((path.resolve(), path.stat().st_size))
        except OSError:
            continue
    return files


def _mirror_bytes_hashed(mirror: list[tuple[Path, int]]) -> int | None:
    """Bytes of the mirror hashed so far: every file before the one the hasher
    has open, plus how far into that one it is."""
    positions = _hasher_positions(MIRROR_VERIFY_UNIT)
    done = 0
    for path, size in mirror:
        if path in positions:
            return done + positions[path]
        done += size
    return None


def arch_install_system(ctx: InstallContext) -> None:
    """Install the target system: archinstall partitions and mounts per the
    configurator JSON, the root image is written onto the mounted layout, and
    archinstall finishes with the per-machine package delta, users, and fstab.

    The phase sequence is the same for full-disk and protected installs. The
    JSON decides whether archinstall should create/mount a disk layout or use
    a pre-mounted target, and Omarchy derives boot/fstab details from that same
    input.
    """
    handler = ctx.state["arch_config_handler"]
    mirror_handler = ctx.state["mirror_handler"]
    config = handler.config
    pre_mounted = arch.is_pre_mount(config)

    if not pre_mounted:
        info("› partitioning + formatting + encrypting")
        with _time_step("STEP.perform_filesystem_operations"):
            # The btrfs archinstall makes here is overwritten by the root
            # image a moment later, so it need not TRIM the device first.
            arch.perform_filesystem_operations(
                config,
                throwaway_root_fs=True,
            )

    info("› opening installer context")
    with arch.open_installer(config, ctx.target, silent=True) as installer:
        if not pre_mounted:
            with _time_step("STEP.mount_ordered_layout"):
                installer.mount_ordered_layout()

        with _time_step("STEP.sanity_check"):
            arch.sanity_check(installer)

        with _time_step("STEP.install_root_image"):
            _install_root_image(ctx)

        if not pre_mounted and arch.is_encrypted(config):
            installer.generate_key_files()

        if config.mirror_config:
            installer.set_mirrors(mirror_handler, config.mirror_config, on_target=False)

        _mount_offline_package_cache(ctx)
        _mask_mkinitcpio_pacman_hooks(ctx)
        try:
            info("› installing per-machine packages (mkinitcpio deferred to final Limine UKI build)")
            kb_layout = config.locale_config.kb_layout if config.locale_config else ""
            with _time_step("STEP.install_base_delta"):
                arch.install_base_delta(
                    installer,
                    config,
                    hostname=config.hostname,
                    locale_config=(
                        replace(config.locale_config, kb_layout="")
                        if config.locale_config else None
                    ),
                )

            # Headers are optional kernel dependencies. Install them before any
            # DKMS package so generic installs have them too, and module builds
            # use the target kernel instead of the live ISO's kernel.
            # The root image carries the default kernel's headers, so this
            # is a pacman run only for a kernel the image does not hold (linux-t2).
            missing_headers = [
                f"{kernel}-headers" for kernel in config.kernels
                if not arch.target_has_package(installer.target, f"{kernel}-headers")
            ]
            if missing_headers:
                with _time_step(f"STEP.kernel_headers ({' '.join(missing_headers)})"):
                    installer.add_additional_packages(missing_headers)

            # The image holds the plain default set. A board with a default set
            # of its own (the N1x, the Snapdragon laptops) gets what that set
            # adds, in this masked-hooks transaction like the rest of the delta.
            platform_packages = _platform_delta_packages(installer.target)
            if platform_packages:
                with _time_step(f"STEP.platform_packages ({_base_package_file().name})"):
                    installer.add_additional_packages(platform_packages)

            with _time_step("STEP.configure_keyboard"):
                if not configure_keyboard(
                    installer.target, kb_layout,
                    ctx.omarchy_install.get("input_method"),
                    ctx.omarchy_install.get("input_xkb_layout", ""),
                ):
                    error(f"Invalid keyboard language specified: {kb_layout}")

            if config.mirror_config:
                with _time_step("STEP.set_mirrors on-target"):
                    installer.set_mirrors(mirror_handler, config.mirror_config, on_target=True)

            if config.swap and config.swap.enabled:
                with _time_step("STEP.setup_zram_swap"):
                    arch.setup_zram_swap(installer)
                    _drop_archinstall_zram_conf(ctx)

            with _time_step("STEP.configure_limine_boot (mkinitcpio + ukify + limine-install)"):
                _configure_limine_boot(ctx, installer, config)

            info("› creating user (with /etc/skel populated)")
            if config.auth_config and config.auth_config.users:
                with _time_step("STEP.create_users"):
                    installer.create_users(config.auth_config.users)

            if config.app_config:
                # The image carries the PipeWire packages; this adds the audio
                # firmware archinstall's hardware detection asks for and wires
                # the per-user PipeWire units.
                info("› applying archinstall application selections")
                arch.install_applications(installer, config)

            _write_language_marker(ctx)

            # Tailscale is bundled in the offline mirror but only installed
            # when an autoinstall drive staged an auth key; must happen here,
            # while the mirror is still bind-mounted, not in the phase that
            # configures the join.
            if ctx.tailscale_authkey_path is not None:
                info("› installing tailscale (auth key staged for first boot)")
                installer.add_additional_packages(["tailscale"])
        finally:
            _unmask_mkinitcpio_pacman_hooks(ctx)
            _unmount_offline_package_cache(ctx)

        # After the last pacstrap: each one runs its own pacman-key --init on
        # the target's gnupg dir. Runs on while the phases below configure the
        # target; create_factory_snapshot joins it.
        _start_target_keyring_init(ctx)

        # Standard arch finishers.
        if config.timezone:
            installer.set_timezone(config.timezone)
        if config.ntp:
            installer.activate_time_synchronization()
        if root := arch.root_user(config):
            installer.set_user_password(root)

        if pre_mounted:
            _write_pre_mounted_fstab(ctx)
        else:
            installer.genfstab()


# ─────────────────────────────────────────────────────────────────────────────
# Root image: write the build-time filesystem over the target root and make
# its subvolume @.
#
# archinstall (or the configurator, for protected installs) has created and
# mounted the subvolume layout by the time this runs: @ at the target, with
# @home, @log, @pkg and the ESP mounted inside it. The layout is unmounted,
# the image written over the root partition (or its LUKS mapper), and the
# layout mounted again exactly as it was. The mount table is replayed from
# findmnt rather than asking archinstall to mount a second time, which would
# also unlock LUKS a second time; the mapper stays open throughout.
# ─────────────────────────────────────────────────────────────────────────────

def _findmnt_mounts(root: Path) -> list[dict]:
    """Every mount at or below root, parents before children, as dicts with
    target/source/fstype/options."""
    res = subprocess.run(
        ["findmnt", "-R", "-J", "-o", "TARGET,SOURCE,FSTYPE,OPTIONS", str(root)],
        capture_output=True, text=True, check=True,
    )
    flat: list[dict] = []

    def walk(nodes):
        for node in nodes:
            flat.append({k: node.get(k) for k in ("target", "source", "fstype", "options")})
            walk(node.get("children") or [])

    walk(json.loads(res.stdout).get("filesystems") or [])
    return flat


# The subvolumes the configurator mounts besides @. They are made again empty
# after the image write, as archinstall made them.
CONFIGURATOR_SUBVOLUMES = ("@home", "@log", "@pkg")


def _extra_subvolumes(mounts: list[dict], target: Path, device: str) -> list[tuple[str, Path]]:
    """Every other subvolume the target mounted from device, which an
    autoinstall layout can add (@srv, @.snapshots, @var, @/srv/data), as
    (name, mountpoint relative to the target root), parent names first."""
    found: dict[str, Path] = {}
    for mount in mounts:
        if mount["fstype"] != "btrfs" or (mount["source"] or "").split("[")[0] != device:
            continue
        for opt in (mount["options"] or "").split(","):
            if opt.startswith("subvol="):
                name = opt[len("subvol="):].strip("/")
                if name and name != "@" and name not in CONFIGURATOR_SUBVOLUMES:
                    found.setdefault(name, Path(mount["target"]).relative_to(target))
    return sorted(found.items(), key=lambda item: item[0].count("/"))


def _make_subvolume_with_image_files(top: Path, name: str, content: Path) -> None:
    """Make subvolume name under top holding what content holds, and leave
    content an empty directory to mount it on. The image wrote the files
    under that mountpoint into @; a subvolume made empty and mounted over
    them would hide them (a separate /var hides the package database). A
    name already present as a plain directory, one nested in @, is moved
    aside first and its files brought back in. cp --reflink shares the
    extents, so nothing is copied on the disk."""
    dest = top / name
    staged = None
    if dest.exists():
        staged = dest.with_name(dest.name + ".omarchy-image")
        dest.rename(staged)
        if content == dest:
            content = staged
    dest.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["btrfs", "subvolume", "create", str(dest)], check=True, capture_output=True)
    if content.is_dir():
        entries = list(content.iterdir())
        if entries:
            subprocess.run(["cp", "-a", "--reflink=always", f"{content}/.", str(dest)], check=True)
            for entry in entries:
                if entry.is_dir() and not entry.is_symlink():
                    shutil.rmtree(entry)
                else:
                    entry.unlink()
    if staged is not None:
        shutil.rmtree(staged)


# The filesystems an ESP has: no symlinks, owners or modes, so what is copied
# onto them is the files, with links followed.
FAT_FILESYSTEMS = ("vfat", "msdos", "fat", "exfat")


def _fat_mounts(mounts: list[dict], target: Path) -> list[Path]:
    """Every FAT filesystem mounted below the target (the ESP at /boot),
    relative to the target root, parents first."""
    return [Path(m["target"]).relative_to(target) for m in mounts
            if m["fstype"] in FAT_FILESYSTEMS and Path(m["target"]).is_relative_to(target)
            and Path(m["target"]) != target]


def _image_dir_for(placed: list[tuple[Path, str]], mountpoint: Path) -> tuple[str, Path]:
    """The subvolume holding the image's files at mountpoint (relative to the
    target root), and the path inside it: @, or the placed subvolume whose
    mountpoint is the nearest one above."""
    under, rest, depth = "@", mountpoint, -1
    for placed_mountpoint, placed_name in placed:
        if mountpoint.is_relative_to(placed_mountpoint) and len(placed_mountpoint.parts) > depth:
            under, rest = placed_name, mountpoint.relative_to(placed_mountpoint)
            depth = len(placed_mountpoint.parts)
    return under, rest


def _stage_image_files_under(top: Path, placed: list[tuple[Path, str]],
                             mountpoints: list[Path], stage: Path) -> None:
    """Move what the image holds under each FAT mountpoint out of its
    subvolume into stage: once that filesystem is mounted it would hide them.
    The kernel package puts its device trees in /boot/dtbs, where the ESP
    mounts, and Snapdragon setup reads them from there. A subvolume or
    another FAT filesystem mounted below the mountpoint is left to its own
    mount, and a stage left by an earlier attempt is dropped first.

    FAT has no symlinks, so a link is staged as what it names. Everything is
    copied before anything is removed, so every link is read while what it
    names is still in place; a link that names nothing is dropped."""
    shutil.rmtree(stage, ignore_errors=True)
    own_mounts = [mountpoint for mountpoint, _ in placed] + mountpoints
    trees = []
    for rel in mountpoints:
        under, rest = _image_dir_for(placed, rel)
        content = top / under / rest
        if content.is_dir() and not content.is_symlink():
            keep = {mountpoint.relative_to(rel) for mountpoint in own_mounts
                    if mountpoint.is_relative_to(rel) and mountpoint != rel}
            trees.append((rel, content, keep))
    for rel, content, keep in trees:
        _copy_tree_except(content, stage / rel, keep, frozenset())
    for rel, content, keep in trees:
        _remove_tree_except(content, keep)


def _inside(keep: set[Path], name: Path) -> set[Path]:
    return {k.relative_to(name) for k in keep if k.is_relative_to(name)}


def _copy_tree_except(content: Path, dest: Path, keep: set[Path], seen: frozenset[Path]) -> None:
    """Copy what content holds into dest with links followed, except the
    paths in keep (relative to content). A directory a link leads back into
    is not copied again."""
    real = content.resolve()
    if real in seen:
        return
    seen = seen | {real}
    dest.mkdir(parents=True, exist_ok=True)
    for entry in content.iterdir():
        name = Path(entry.name)
        if name in keep:
            continue
        if entry.is_dir():
            _copy_tree_except(entry, dest / name, _inside(keep, name), seen)
        elif entry.is_file():
            shutil.copy2(entry, dest / name)


def _remove_tree_except(content: Path, keep: set[Path]) -> None:
    """Remove what content holds except the paths in keep (relative to
    content) and the directories leading to them."""
    for entry in list(content.iterdir()):
        name = Path(entry.name)
        if name in keep:
            continue
        inner = _inside(keep, name)
        if entry.is_dir() and not entry.is_symlink():
            if inner:
                _remove_tree_except(entry, inner)
            else:
                shutil.rmtree(entry)
        else:
            entry.unlink()


def _restore_image_files_onto(stage: Path, target: Path, mountpoints: list[Path]) -> None:
    """Copy what _stage_image_files_under moved aside onto the mounted FAT
    filesystems, where a pacstrap install would have put it."""
    for rel in mountpoints:
        staged = stage / rel
        if staged.is_dir() and any(staged.iterdir()):
            subprocess.run(["cp", "-r", f"{staged}/.", str(target / rel)], check=True)
    shutil.rmtree(stage, ignore_errors=True)


def _remount_option_string(options: str) -> str:
    # subvolid refers to the subvolume replaced here; subvol= names it.
    return ",".join(opt for opt in options.split(",") if not opt.startswith("subvolid="))


def _root_image_target_mounts(target: Path) -> tuple[list[dict], str]:
    """The mount table under target, checked for what the image write needs:
    target itself mounted, btrfs, on the @ subvolume. Returns the mounts and
    the device backing the root."""
    mounts = _findmnt_mounts(target)
    if not mounts or Path(mounts[0]["target"]) != target:
        raise RuntimeError(f"{target} is not a mountpoint")
    root_mount = mounts[0]
    if root_mount["fstype"] != "btrfs":
        raise RuntimeError(f"root image install needs a btrfs target root, got {root_mount['fstype']}")
    root_options = (root_mount["options"] or "").split(",")
    if not any(opt in ("subvol=/@", "subvol=@") for opt in root_options):
        raise RuntimeError(f"root image install needs the target root on the @ subvolume, got {root_mount['options']}")
    device = (root_mount["source"] or "").split("[")[0]
    if not device:
        raise RuntimeError(f"could not determine the btrfs device backing {target}")
    return mounts, device


def _wait_for_blkid_uuid(device: str, attempts: int = 50) -> None:
    """Re-probe `device` until blkid's UUID matches the btrfs superblock fsid."""
    want = ""
    dump = subprocess.run(["btrfs", "inspect-internal", "dump-super", device],
                          capture_output=True, text=True, check=False).stdout
    for line in dump.splitlines():
        if line.startswith("fsid"):
            want = line.split()[-1]
            break
    for _ in range(attempts):
        subprocess.run(["udevadm", "trigger", "--settle", "--action=change", device],
                       check=False, capture_output=True)
        got = subprocess.run(["blkid", "-p", "-s", "UUID", "-o", "value", device],
                             capture_output=True, text=True, check=False).stdout.strip()
        cached = subprocess.run(["blkid", "-s", "UUID", "-o", "value", device],
                                capture_output=True, text=True, check=False).stdout.strip()
        if want and got == want and cached == want:
            info(f"› fsid {want} visible to blkid")
            return
        time.sleep(0.1)
    raise RuntimeError(f"blkid still reports an old UUID for {device} after the fsid change (want {want})")


SYSFS_BLOCK = Path("/sys/class/block")


def _medium_bytes_read() -> int | None:
    """Bytes the kernel has read from the boot medium's block device so far
    (sectors read, from /sys/class/block/<dev>/stat), or None when there is no
    block device to ask (a netboot over NFS, a dev tree)."""
    source = _findmnt_value(BOOT_MEDIUM_MOUNT, "SOURCE")
    if not source or not source.startswith("/dev/"):
        return None
    try:
        fields = (SYSFS_BLOCK / Path(source).resolve().name / "stat").read_text().split()
        return int(fields[2]) * 512
    except (OSError, IndexError, ValueError):
        return None


def _write_root_image_frames(image: Path, device: str) -> bool:
    """Write the image with omarchy-image-write (builder/omarchy-image-write.c):
    the ISO packs it as independent 256 KiB zstd frames with a seek table,
    which N threads decode and pwrite with O_DIRECT, so the drive sees N
    requests in flight where zstdcat | dd gives it one (2.5 s -> 0.9 s on a
    990 PRO, stream in RAM). False when the tool is not on the ISO or the
    image is not one it writes (exit 2, nothing written), so the caller can
    use the pipe instead. Exit 1 is an error: the target could not be used
    (in use, too small) or the write failed partway."""
    if not IMAGE_WRITE.is_file():
        return False
    with _time_step("F1.image_write (parallel frames, O_DIRECT)"):
        proc = subprocess.run([str(IMAGE_WRITE), "write", str(image), device],
                              stderr=subprocess.PIPE, text=True, check=False)
    for line in proc.stderr.splitlines():
        info(f"› {line}")
    if proc.returncode == 2:
        info("› image-write refused the image; writing it through zstdcat | dd")
        return False
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, proc.args, stderr=proc.stderr)
    return True


def _write_root_image_pipe(image: Path, device: str) -> None:
    with _time_step("F1.dd (zstdcat | dd oflag=direct)"):
        # dd blocks on its writes, so the pipe paces zstd to the disk,
        # and the decoding runs on another core.
        #
        # iflag=fullblock is what makes oflag=direct true. A read from a
        # pipe returns at most one pipe buffer (64 KiB), dd treats that
        # as a partial block, and for a partial block it silently drops
        # O_DIRECT, so without fullblock every write is buffered. On a
        # LUKS mapper with 512-byte sectors the block device's writeback
        # then goes out 512 bytes at a time: 2 million NVMe requests per
        # GiB, 87 s for this image on a 980 PRO against 2.7 s
        # with full blocks. QEMU hides it (4.9 s there), real disks do
        # not. bs: 1M-4M measure the same within noise, 2M best, 16M and
        # 64M slower (on the same drive, stream in RAM).
        # status=noxfer keeps dd's record counts for the check below.
        #
        # The pipe is ours, not the shell's, for two reasons. Size: with
        # the default 64 KiB pipe zstd stalls on every dd write and dd on
        # every read; 4 MiB lets zstd stay two blocks ahead (2.5 s -> 2.1 s
        # on a 990 PRO, stream in RAM; 1-16 MiB measure the same, 64 MiB
        # and up slower). Above 1 MiB, F_SETPIPE_SZ needs
        # CAP_SYS_RESOURCE, which the orchestrator has as root. Status:
        # a shell pipeline reports dd's alone, so a zstd that died on a
        # bad frame read as a short image written successfully.
        read_end, write_end = os.pipe()
        try:
            fcntl.fcntl(write_end, fcntl.F_SETPIPE_SZ, 4 << 20)
        except OSError:
            pass  # a smaller pipe is slower, not wrong
        # zstd's stderr is captured so its reason ("premature end", a bad
        # frame) travels with the failure; it only writes there on an error.
        zstd = subprocess.Popen(["zstdcat", str(image)], stdout=write_end,
                                stderr=subprocess.PIPE, text=True)
        dd = subprocess.Popen(
            ["dd", f"of={device}", "bs=2M", "iflag=fullblock",
             "conv=sparse,fsync", "oflag=direct", "status=noxfer"],
            stdin=read_end, stderr=subprocess.PIPE, text=True,
        )
        os.close(read_end)
        os.close(write_end)
        _, dd_stderr = dd.communicate()
        _, zstd_stderr = zstd.communicate()
        # dd first: when dd dies, zstd dies of the broken pipe after it.
        if dd.returncode != 0:
            raise subprocess.CalledProcessError(dd.returncode, dd.args, stderr=dd_stderr)
        if zstd.returncode != 0:
            raise subprocess.CalledProcessError(zstd.returncode, zstd.args, stderr=zstd_stderr)
        _check_dd_full_blocks(dd_stderr)


def _place_root_image(ctx: InstallContext) -> None:
    """Write the pre-built btrfs image onto the target root device, give it a
    fresh fsid, grow it to the partition, and reshape it into the @ layout:
    the same ~940 packages a pacstrap would install, at the speed of the
    drive."""
    target = ctx.target
    raw_image = _root_image()
    mounts, device = _root_image_target_mounts(target)

    info(f"› writing root image ({raw_image.stat().st_size >> 20} MiB from {raw_image})")

    with _time_step("F1.umount_target_tree"):
        _umount_tree(target)

    # How much of the image the write had to read off the medium rather than
    # the page cache: near zero when the verify left it all cached, up to the
    # whole image on a machine whose RAM could not hold it.
    medium_before = _medium_bytes_read()
    if not _write_root_image_frames(raw_image, device):
        _write_root_image_pipe(raw_image, device)
    medium_after = _medium_bytes_read()
    if medium_before is not None and medium_after is not None:
        info(f"› read {(medium_after - medium_before) / 1048576:.0f} MiB of the "
             f"{raw_image.stat().st_size / 1048576:.0f} MiB image off the install medium while writing it")

    # -m sets a fresh fsid via the METADATA_UUID feature (kernel 5.0+) by
    # writing the superblocks only; -u rewrites every metadata block of the
    # 4.5 GB image, which takes 0.8-2.0 s. The visible UUID (blkid, fstab,
    # snapper) is the new one either way; two installs from the same image
    # are distinct filesystems to the kernel because they differ in fsid.
    with _time_step("F1.btrfstune -m (new fsid via metadata_uuid)"):
        subprocess.run(["btrfstune", "-f", "-m", device], check=True)
    # genfstab and the Limine cmdline read the UUID through libblkid, whose
    # cache only refreshes once udev has re-probed the device. On a slow
    # machine genfstab can run first and record the image's old fsid, and the
    # installed system then waits forever for /dev/disk/by-uuid/<old>. Force
    # the re-probe and do not continue until blkid reports what the
    # superblock says.
    with _time_step("F1.udev_reprobe_after_fsid_change"):
        _wait_for_blkid_uuid(device)

    # Give the filesystem the layout archinstall's fstab expects. The write
    # replaced the empty subvolumes archinstall had created (@, @home, @log,
    # @pkg, and whatever else an autoinstall layout named), and the image
    # holds a single subvolume named ROOT_IMAGE_SUBVOLUME: rename that one to
    # @ and create the others again. Then grow the filesystem, which was
    # shrunk for the ISO, to fill the partition.
    top = ctx.state_dir / "image-top"
    top.mkdir(parents=True, exist_ok=True)
    stage = ctx.state_dir / "image-under-esp"
    fat_mounts = _fat_mounts(mounts, target)
    with _time_step("F1.mount_top_for_reshape"):
        subprocess.run(["mount", "-o", "subvolid=5", device, str(top)], check=True)
    try:
        with _time_step("F1.btrfs_resize_max"):
            subprocess.run(["btrfs", "filesystem", "resize", "max", str(top)], check=True)

        image_subvol = top / ROOT_IMAGE_SUBVOLUME
        at_subvol = top / "@"
        with _time_step("F1.mv_omarchy-root_to_@"):
            image_subvol.rename(at_subvol)

        with _time_step("F1.create_@home_@log_@pkg"):
            for name in CONFIGURATOR_SUBVOLUMES:
                p = top / name
                if not p.exists():
                    subprocess.run(["btrfs", "subvolume", "create", str(p)],
                                   check=True, capture_output=True)

        with _time_step("F1.copy_pacman_log"):
            image_log = at_subvol / "var" / "log" / "pacman.log"
            log_subvol = top / "@log"
            if image_log.is_file() and log_subvol.is_dir():
                shutil.copy2(image_log, log_subvol / "pacman.log")

        # An autoinstall layout's own subvolumes take the image's files under
        # their mountpoints along. Those files are in @, or in a subvolume
        # already placed here whose mountpoint is the nearest one above.
        with _time_step("F1.place_extra_subvolumes"):
            placed: list[tuple[Path, str]] = []
            for name, mountpoint in _extra_subvolumes(mounts, target, device):
                under, rest = _image_dir_for(placed, mountpoint)
                _make_subvolume_with_image_files(top, name, top / under / rest)
                placed.append((mountpoint, name))

        with _time_step("F1.stage_image_files_under_the_esp"):
            _stage_image_files_under(top, placed, fat_mounts, stage)
    finally:
        subprocess.run(["umount", str(top)], check=False)

    with _time_step("F1.remount_subvols_on_target"):
        for mount in mounts:
            mountpoint = Path(mount["target"])
            mountpoint.mkdir(parents=True, exist_ok=True)
            opts = _remount_option_string(mount["options"] or "")
            source = (mount["source"] or "").split("[")[0]
            subprocess.run(["mount", "-o", opts, source, str(mountpoint)], check=True)

    with _time_step("F1.restore_image_files_onto_the_esp"):
        _restore_image_files_onto(stage, target, fat_mounts)

    _write_phase_progress(ctx, 1.0)


def _install_root_image(ctx: InstallContext) -> None:
    _place_root_image(ctx)
    _finish_root_image(ctx)


def _finish_root_image(ctx: InstallContext) -> None:
    """What the written image owes the rest of the install: it carries
    the packages the phases assume, and the target has a machine-id (the
    image deliberately ships an empty one) before limine-entry-tool and the
    factory snapshot read it."""
    target = ctx.target
    missing = [pkg for pkg in _root_image_required_packages() if not arch.target_has_package(target, pkg)]
    if missing:
        raise RuntimeError(f"root image lacks required packages: {', '.join(missing)}")
    subprocess.run(["systemd-machine-id-setup", f"--root={target}"], check=True, capture_output=True)


# Transient systemd unit that initialises the target's pacman keyring.
TARGET_KEYRING_UNIT = "omarchy-target-keyring"


def _start_target_keyring_init(ctx: InstallContext) -> None:
    """Initialise and populate the target's per-machine pacman keyring, as a
    transient systemd unit that runs on while the install continues.

    The image ships no /etc/pacman.d/gnupg: its master key would be the same
    on every install, and a shared signing key must never be distributed. On
    a target pacstrapped directly, pacstrap -K initialised the keyring and
    the keyring packages' scriptlets populated it; here those packages come
    from the image, where their scriptlets ran with no keyring to populate.
    The delta pacstrap's -K still ran --init (generating the master key), and
    --init is idempotent, so run it again for installs that pacstrapped
    nothing, then populate from the target's own keyring files. Chroot-free:
    --gpgdir and --populate-from address the target directly, so no API
    mounts are held.

    Started after the last pacstrap (each runs its own --init on this dir)
    and joined by create_factory_snapshot: on x86_64 nothing in between
    reads the keyring (the offline repo is SigLevel = Never) or writes it,
    and the snapshot must not capture it half-written. On aarch64 the
    runtime's post-install inits and populates it itself, so
    run_system_finalizer joins it first. A unit rather than a plain
    child process: pacman-key leaves a gpg-agent and dirmngr behind, which
    systemd kills with the rest of the unit's cgroup the moment pacman-key
    exits (sockets under the target's gnupg dir would otherwise block the
    unmount); the dashboard's process-group kill does not reach it, while
    `systemctl stop` still does (stop_target_keyring_init); and its output
    is in the journal whatever happens to the orchestrator. --wait --pipe
    give a child to join with the unit's exit status and output.
    """
    gpgdir = shlex.quote(str(ctx.target / "etc" / "pacman.d" / "gnupg"))
    keyrings = shlex.quote(str(ctx.target / "usr" / "share" / "pacman" / "keyrings"))
    script = (
        f"pacman-key --gpgdir {gpgdir} --init && "
        f"pacman-key --gpgdir {gpgdir} --populate-from {keyrings} --populate {' '.join(_target_keyrings())}"
    )
    info("› initializing per-machine pacman keyring (background unit)")
    # A failed unit from an earlier attempt would hold the name (--collect
    # releases it, but not for a unit started without it).
    subprocess.run(["systemctl", "reset-failed", TARGET_KEYRING_UNIT], check=False, capture_output=True)
    ctx.state["target_keyring_proc"] = subprocess.Popen(
        ["systemd-run", "--wait", "--pipe", "--collect", "--quiet",
         f"--unit={TARGET_KEYRING_UNIT}", "sh", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def _target_keyrings() -> list[str]:
    """The keyrings the target's pacman must trust. Arch Linux ARM signs every
    package in its repositories, archlinux-keyring included, with its own build
    keys, which only archlinuxarm-keyring carries; the aarch64 image holds it."""
    keyrings = ["archlinux", "omarchy"]
    if platform.machine() == "aarch64":
        keyrings.append("archlinuxarm")
    return keyrings


def _join_target_keyring_init(ctx: InstallContext, *, raise_on_error: bool = True) -> None:
    """Wait for the keyring unit if one is running; no-op otherwise."""
    proc = ctx.state.pop("target_keyring_proc", None)
    if proc is None:
        return
    out, _ = proc.communicate()
    if raise_on_error and proc.returncode != 0:
        raise RuntimeError(
            f"per-machine pacman keyring init failed (exit {proc.returncode}):\n"
            f"{(out or '').strip()}"
        )


def stop_target_keyring_init(ctx: InstallContext) -> None:
    """Exit path: end the keyring unit if it is still running, so nothing
    keeps writing into the target after the install has stopped. The
    install's own error must win, so a keyring failure is not raised here."""
    if ctx.state.get("target_keyring_proc") is None:
        return
    subprocess.run(["systemctl", "stop", TARGET_KEYRING_UNIT], check=False, capture_output=True)
    _join_target_keyring_init(ctx, raise_on_error=False)


def _umount_tree(root: Path, attempts: int = 20) -> None:
    """umount -R with a few retries: the dashboard polls the target's pacman
    db from another process, and a poll landing mid-unmount is EBUSY."""
    for attempt in range(1, attempts + 1):
        res = subprocess.run(["umount", "-R", str(root)], capture_output=True, text=True)
        if res.returncode == 0:
            return
        if attempt == attempts:
            raise RuntimeError(f"could not unmount {root}: {res.stderr.strip()}")
        time.sleep(0.25)


def _write_phase_progress(ctx: InstallContext, fraction: float) -> None:
    """Record how far the current phase has come (0..1) in the state file the
    dashboard polls. Best effort: progress display must never fail an install."""
    state_path = ctx.state_dir / "state.json"
    try:
        state = json.loads(state_path.read_text())
    except (OSError, ValueError):
        return
    state["phase_progress"] = max(0.0, min(1.0, fraction))
    try:
        write_state(state_path, state)
    except OSError:
        pass


def _configure_limine_boot(ctx: InstallContext, installer, config) -> None:
    if not arch.bootloader_enabled(config):
        return
    if not arch.is_limine(config):
        raise RuntimeError("Omarchy installs only support Limine bootloader setup")

    info("› installing bootloader (Limine)")
    if arch.is_pre_mount(config):
        _install_pre_mounted_limine(ctx)
    else:
        _install_limine_omarchy(ctx, installer, config)

    info("› writing Limine config")
    if arch.is_pre_mount(config):
        _write_pre_mounted_limine_defaults(ctx)
    else:
        _write_limine_defaults_from_config(ctx, installer, config)


def _install_limine_omarchy(ctx: InstallContext, installer, config) -> None:
    boot_partition = installer._get_boot_partition()
    efi_partition = installer._get_efi_partition()
    root = installer._get_root()

    if boot_partition is None:
        raise RuntimeError(f"Could not detect boot at mountpoint {ctx.target}")
    if root is None:
        raise RuntimeError(f"Could not detect root at mountpoint {ctx.target}")

    bootloader_config = config.bootloader_config
    bootloader_removable = bool(
        getattr(bootloader_config, "removable", False) if bootloader_config else False
    )

    if arch.has_uefi():
        if efi_partition is None:
            raise RuntimeError("Could not detect EFI partition")
        if not efi_partition.mountpoint:
            raise RuntimeError("EFI partition is not mounted")

        _install_limine_efi(
            ctx,
            esp_mount=str(efi_partition.mountpoint),
            disk=arch.parent_device_path(efi_partition.safe_dev_path),
            part=int(efi_partition.partn),
            removable=bootloader_removable,
        )
    else:
        _install_limine_bios(ctx, boot_partition)

    installer._helper_flags["bootloader"] = "limine"


def _install_pre_mounted_limine(ctx: InstallContext) -> None:
    boot = _boot_intent(ctx)
    storage = _storage_intent(ctx)
    esp_device = storage.get("esp_device")
    if not esp_device:
        raise RuntimeError("omarchy_install.storage.esp_device missing")

    pre_state = _read_efibootmgr()
    windows_before = _find_label_entries(pre_state["entries"], "Windows")
    disk, part = _split_partition_device(esp_device)
    _install_limine_efi(
        ctx,
        esp_mount=boot["esp_mount"],
        disk=Path(disk),
        part=part,
        esp_path=boot.get("esp_path", "/EFI/limine"),
        efi_binary=boot.get("efi_binary", _default_limine_efi_binary()),
        pre_state=pre_state,
    )

    post_state = _read_efibootmgr()
    windows_after = _find_label_entries(post_state["entries"], "Windows")
    # A store that cannot be read on either side cannot be compared; the
    # registration has already said why, and nothing was written to it.
    readable = not (pre_state.get("unreadable") or post_state.get("unreadable"))
    if readable and windows_before and not windows_after:
        raise RuntimeError("Windows boot entry disappeared during Limine install — aborting")


# UEFI binary names follow the machine architecture. The live ISO and the
# target share one architecture, so the running kernel is authoritative.
def _efi_arch_suffix() -> str:
    return "AA64" if platform.machine() == "aarch64" else "X64"


def _default_limine_efi_binary() -> str:
    return f"limine_{_efi_arch_suffix().lower()}.efi"


def _install_limine_efi(
    ctx: InstallContext,
    *,
    esp_mount: str,
    disk: Path,
    part: int,
    removable: bool = False,
    esp_path: str = "/EFI/limine",
    efi_binary: str | None = None,
    pre_state: dict | None = None,
) -> None:
    if efi_binary is None:
        efi_binary = _default_limine_efi_binary()
    if removable:
        esp_path = "/EFI/BOOT"
        efi_binary = f"BOOT{_efi_arch_suffix()}.EFI"

    limine_path = ctx.target / "usr" / "share" / "limine"
    source_name = f"BOOT{_efi_arch_suffix()}.EFI"
    target_dir = Path(esp_mount) / esp_path.lstrip("/")
    target_path = target_dir / efi_binary
    _copy_required(limine_path / source_name, ctx.target / target_path.relative_to("/"))

    hook_command = f"/usr/bin/cp /usr/share/limine/{source_name} {target_path}"
    _write_limine_pacman_hook(ctx.target, hook_command)

    _register_limine_efi_entry(disk, part, _limine_efi_loader(esp_path, efi_binary), pre_state=pre_state)


def _limine_efi_loader(esp_path: str, efi_binary: str) -> str:
    """The loader path a "Limine" boot entry starts, as efibootmgr --loader
    takes it: \\EFI\\limine\\limine_x64.efi for the default esp_path."""
    return "\\" + str(Path(esp_path) / efi_binary).strip("/").replace("/", "\\")


def _register_limine_efi_entry(
    disk: Path,
    part: int,
    loader: str,
    *,
    pre_state: dict | None = None,
) -> None:
    pre_state = pre_state or _read_efibootmgr()
    if pre_state.get("unreadable"):
        # Every write below would be refused the same way.
        _warn_boot_entry_refused(
            f"The EFI variable store cannot be read ({pre_state['unreadable']}), "
            "so no boot entry can be written"
        )
        return
    # An entry identical to the one a create would add (active, labelled
    # "Limine", this ESP, this loader) already boots this install: the loader
    # it names was just written. It is reused and nothing is created, so the
    # entry that boots the machine is never deleted to make way for a new
    # one, and a full NVRAM needs no room. One switched off in the firmware
    # is not identical, since BootOrder skips it. Other "Limine" entries
    # belong to other installs, such as the Omarchy a free-space install is
    # put next to, and a second loader on this same ESP, such as
    # \EFI\backup\limine.efi, is a separate boot option; neither is touched.
    # An efibootmgr that prints no paths matches nothing, and a reinstall
    # onto the same ESP then leaves one duplicate behind, which is harmless.
    esp = _partition_guid(disk, part)
    identical = [
        num
        for num, text in pre_state["entries"].items()
        if _is_limine_entry_for(text, esp, loader) and num not in pre_state.get("inactive", ())
    ]
    if identical:
        limine_num = identical[0]
        info(f"› Reusing the 'Limine' boot entry Boot{limine_num}, which already starts this loader")
    else:
        created = _create_limine_efi_entry(disk, part, loader)
        detail = (created.stderr or "").strip()
        if created.returncode != 0:
            # Attach the reason to the failure. efibootmgr's stderr did reach
            # the install log before (the dashboard merges the child's
            # streams), but CalledProcessError carries only argv and the exit
            # status, so the traceback people paste into a report says nothing
            # about why.
            reason = f"efibootmgr --create exited {created.returncode}"
            _warn_boot_entry_refused(f"{reason}: {detail}" if detail else reason)
            return
        if detail:
            error(f"efibootmgr: {detail}")

        # The entry just created: a "Limine" entry the earlier listing did not
        # show. Firmware that keeps one option per device path can answer the
        # create with an option it already has, which counts the same way.
        # The first such entry may be another install's, so one that starts
        # this loader on this ESP comes first; a listing without device paths
        # keeps list order.
        post_state = _read_efibootmgr()
        if post_state.get("unreadable"):
            _warn_boot_entry_refused(
                "efibootmgr --create exited 0 but the boot entries cannot be read back "
                f"({post_state['unreadable']}), so BootOrder and BootNext are left alone"
            )
            return
        new_limine = sorted(
            [
                num
                for num in _find_label_entries(post_state["entries"], "Limine")
                if num not in pre_state["entries"]
            ],
            key=lambda num: not _is_limine_entry_for(post_state["entries"][num], esp, loader),
        )
        if not new_limine:
            _warn_boot_entry_refused(
                "efibootmgr --create exited 0 but no 'Limine' entry is registered, so this "
                "firmware discarded the variable as soon as it was written"
            )
            return
        limine_num = new_limine[0]

    # Duplicates of the reused entry go, never the reused one. One whose
    # delete fails is still a working copy, and stays in BootOrder.
    deleted = [
        num
        for num in identical[1:]
        if subprocess.run(
            ["efibootmgr", "--bootnum", num, "--delete-bootnum"],
            check=False, capture_output=True,
        ).returncode == 0
    ]

    keep = [
        num
        for num in pre_state["order"]
        if num not in deleted
        and num != limine_num
        and num in pre_state["entries"]
    ]
    # capture(): efibootmgr prints the boot list after a write, and legacy
    # entries can carry bytes that are not UTF-8.
    ordered = capture(["efibootmgr", "--bootorder", ",".join([limine_num, *keep])])
    if ordered.returncode != 0:
        # BootOrder is another NVRAM write and can be refused on its own. The
        # entry exists either way, so this costs Omarchy its place at the front
        # of the list, not its boot route.
        order_detail = (ordered.stderr or "").strip() or f"exit status {ordered.returncode}"
        error(
            "Warning: the 'Limine' boot entry was registered but this firmware would "
            f"not reorder BootOrder to put it first ({order_detail}). Omarchy is reachable "
            "from the firmware boot menu (F11, F12 or Esc on most boards); move it to "
            "the top of the firmware's own boot priority list to make it the default."
        )

    # Some firmware keeps its own priority list and writes it back over
    # BootOrder at the next POST. An MSI MAG Z690 Tomahawk (BIOS 7D32v1O)
    # moved this entry behind Windows and the other install's, so "Reboot
    # Now" after a free-space install started the other install. BootNext is
    # read before BootOrder and that firmware honours it, so the first boot
    # reaches what was just installed whatever happens to BootOrder.
    nexted = capture(["efibootmgr", "--bootnext", limine_num])
    if nexted.returncode != 0:
        next_detail = (nexted.stderr or "").strip() or f"exit status {nexted.returncode}"
        error(
            f"Warning: this firmware would not set BootNext to the 'Limine' entry ({next_detail}). "
            "If the first reboot starts another system, pick Omarchy from the firmware "
            "boot menu (F11, F12 or Esc on most boards)."
        )


def _create_limine_efi_entry(disk: Path, part: int, loader: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            "efibootmgr",
            "--create",
            "--disk", str(disk),
            "--part", str(part),
            "--label", "Limine",
            "--loader", loader,
            "--unicode",
            "--verbose",
        ],
        check=False,
        stderr=subprocess.PIPE,
        text=True,
        errors="replace",
    )


def _warn_boot_entry_refused(reason: str) -> None:
    """Registration failed. Report it and carry on to the removable-media route.

    Firmware that refuses a boot-variable write still boots this install from
    EFI/BOOT/BOOT<arch>.EFI, which needs no NVRAM, where the install writes that
    loader (an EFI partition of its own). Raising here is what issue #127
    reports: registration runs several phases before finalize_limine_boot writes
    that loader, so the abort leaves the machine with neither route. validate_boot
    is the one place that decides whether an install is reachable, and it already
    refuses to finish when both routes are missing.
    """
    error(
        f"Warning: this firmware would not register a 'Limine' UEFI boot entry. {reason}. "
        f"The install continues: where Omarchy writes EFI/BOOT/BOOT{_efi_arch_suffix()}.EFI on an EFI "
        "partition of its own, firmware takes that path when nothing in NVRAM matches. "
        "The boot check at the end of the install stops an install that ends up with "
        "neither route."
    )


def _install_limine_bios(ctx: InstallContext, boot_partition) -> None:
    boot_limine_path = ctx.target / "boot" / "limine"
    boot_limine_path.mkdir(parents=True, exist_ok=True)

    parent_dev_path = arch.parent_device_path(boot_partition.safe_dev_path)
    if unique_path := arch.unique_device_path(parent_dev_path):
        parent_dev_path = unique_path

    limine_path = ctx.target / "usr" / "share" / "limine"
    _copy_required(limine_path / "limine-bios.sys", boot_limine_path / "limine-bios.sys")
    subprocess.run(
        ["arch-chroot", str(ctx.target), "limine", "bios-install", str(parent_dev_path)],
        check=True,
    )
    hook_command = (
        f"/usr/bin/limine bios-install {parent_dev_path} && "
        "/usr/bin/cp /usr/share/limine/limine-bios.sys /boot/limine/"
    )
    _write_limine_pacman_hook(ctx.target, hook_command)


def _copy_required(src: Path, dst: Path) -> None:
    if not src.exists():
        raise RuntimeError(f"Required Limine file missing: {src}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def _write_limine_pacman_hook(target: Path, hook_command: str) -> None:
    hook_contents = textwrap.dedent(
        f"""\
        [Trigger]
        Operation = Upgrade
        Type = Package
        Target = limine

        [Action]
        Description = Deploying Omarchy Limine after upgrade...
        When = PostTransaction
        Exec = /bin/sh -c "{hook_command}"
        """
    )
    hooks_dir = target / "etc" / "pacman.d" / "hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    (hooks_dir / "99-omarchy-limine.hook").write_text(hook_contents)


def _write_limine_defaults_from_config(ctx: InstallContext, installer, config) -> None:
    if not arch.is_limine(config):
        return

    root = installer._get_root()
    if root is None:
        raise RuntimeError(f"Could not detect root at mountpoint {ctx.target}")

    from .luks_tuning import with_cmdline_options
    cmdline = with_cmdline_options(" ".join(installer._get_kernel_params(root)))
    _write_limine_defaults(ctx, cmdline, esp_mount=_installer_esp_mount(installer))


AARCH64_CONSOLE_CONF = "00-omarchy-console.conf"


def _write_limine_defaults(
    ctx: InstallContext,
    cmdline: str,
    *,
    esp_mount: str,
    enable_fallback: bool | None = None,
) -> None:
    if not cmdline.strip():
        raise RuntimeError("Could not compute kernel cmdline from install config")
    if "root=" not in cmdline:
        raise RuntimeError(f"Computed cmdline has no root=: {cmdline!r}")
    # Every variant's cmdline passes through here (archinstall-derived and
    # pre-mounted alike), so this is where the console parameter goes.
    if CONSOLE_NO_ANSI_QUERY not in cmdline.split():
        cmdline = f"{cmdline} {CONSOLE_NO_ANSI_QUERY}"
    # And the sd-encrypt spelling of cryptdevice=. Added on the
    # archinstall-derived path only, it would leave an encrypted install into
    # free space (the pre-mounted path) with an entry the pre-built UKI cannot
    # unlock: no rd.luks.name=, no cryptsetup job, no passphrase prompt, and
    # "A start job is running for /dev/mapper/omarchy_root" with no limit.
    # No VM scenario installs into free space.
    from .luks_tuning import with_cmdline_options
    cmdline = with_cmdline_options(cmdline)
    if "cryptdevice=" in cmdline and "rd.luks.name=" not in cmdline:
        raise RuntimeError(
            f"encrypted cmdline has cryptdevice= but no rd.luks.name=; the "
            f"pre-built UKI could not unlock the root: {cmdline!r}"
        )

    default_text = _limine_template(ctx, "default.conf").read_text()
    default_text = default_text.replace("@@CMDLINE@@", cmdline)
    default_text = re.sub(r'^ESP_PATH=.*$', f'ESP_PATH="{esp_mount}"', default_text, flags=re.MULTILINE)
    if enable_fallback is not None:
        default_text = default_text.rstrip() + f"\nENABLE_LIMINE_FALLBACK={'yes' if enable_fallback else 'no'}\n"
    if not arch.has_uefi():
        default_text = default_text.rstrip() + "\nENABLE_UKI=no\nENABLE_LIMINE_FALLBACK=no\n"

    default_limine = ctx.target / "etc" / "default" / "limine"
    default_limine.parent.mkdir(parents=True, exist_ok=True)
    default_limine.write_text(default_text)

    kernel_cmdline = ctx.target / "etc" / "kernel" / "cmdline"
    kernel_cmdline.parent.mkdir(parents=True, exist_ok=True)
    kernel_cmdline.write_text(cmdline + "\n")

    if platform.machine() == "aarch64":
        # arm64 firmware commonly publishes an ACPI serial console (SPCR), which
        # the kernel adopts unless told otherwise; the disk passphrase prompt
        # then goes to a serial port nobody is watching. The live ISO boots with
        # the console on the screen; carry that to the installed system.
        console_conf = ctx.target / "etc" / "limine-entry-tool.d" / AARCH64_CONSOLE_CONF
        console_conf.parent.mkdir(parents=True, exist_ok=True)
        console_conf.write_text(
            "# aarch64: keep the console on the screen rather than the firmware's serial port.\n"
            'KERNEL_CMDLINE[default]+=" console=tty0 acpi=nospcr"\n'
        )

    limine_conf = ctx.target / esp_mount.lstrip("/") / "limine.conf"
    limine_conf.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(_limine_template(ctx, "limine.conf"), limine_conf)


def _installer_esp_mount(installer) -> str:
    if efi_partition := installer._get_efi_partition():
        if efi_partition.mountpoint:
            return str(efi_partition.mountpoint)
    return "/boot"



def _limine_template(ctx: InstallContext, filename: str) -> Path:
    candidates = [
        ctx.target / "usr" / "share" / "omarchy" / "install" / "assets" / "limine" / filename,
        ctx.target / "usr" / "share" / "omarchy" / "default" / "limine" / filename,
        ctx.omarchy_path / "install" / "assets" / "limine" / filename,
        ctx.omarchy_path / "default" / "limine" / filename,
    ]
    for candidate in candidates:
        if candidate.exists():
            return candidate
    searched = "\n  ".join(str(p) for p in candidates)
    raise RuntimeError(f"Limine template {filename} not found. Searched:\n  {searched}")


DEFERRED_BOOT_HOOKS = (
    "60-mkinitcpio-remove.hook",
    "60-limine-mkinitcpio-remove-pre.hook",
    "80-limine-efi-deploy.hook",
    "90-limine-mkinitcpio-remove-post.hook",
    "90-mkinitcpio-install.hook",
)

# Inside the target chroot, only the install hook is worth deferring.
# limine-entry-tool's 90-mkinitcpio-install.hook triggers on usr/lib/firmware/*,
# usr/src/*/dkms.conf and usr/lib/modules/*/pkgbase, and anything but a
# usr/lib/modules path makes it rebuild the initramfs and UKI for EVERY
# installed kernel. omarchy-apply-system's hardware scripts routinely install
# such packages (sof-firmware on Intel audio, nvidia-open-dkms, linux-ptl on
# Panther Lake, linux-t2 on Macs), so the phase can pay for several full UKI
# builds. finalize_limine_boot runs limine-update right after, which pipes
# "rebuild" into the same script and rebuilds every kernel unconditionally —
# those mid-phase builds are always thrown away, and are stale anyway (nvidia.sh
# writes its mkinitcpio drop-in after installing the driver).
#
# The kernel-removal hooks stay live: they only prune Limine entries, which is
# exactly what ptl-kernel.sh's "pacman -Rdd linux" needs.
TARGET_DEFERRED_BOOT_HOOKS = ("90-mkinitcpio-install.hook",)


def _drop_archinstall_zram_conf(ctx: InstallContext) -> None:
    """Remove the zram-generator.conf archinstall's setup_swap writes directly.

    omarchy-settings ships the tuning as a vendor drop-in at
    /usr/lib/systemd/zram-generator.conf.d/90-omarchy.conf, which outranks the
    main config file. setup_swap's generic /etc copy decides nothing and only
    implies /etc is where zram gets configured, so drop it — we still want the
    zram-generator package and service that setup_swap installs.
    """
    zram_conf = ctx.target / "etc" / "systemd" / "zram-generator.conf"
    zram_conf.unlink(missing_ok=True)


def _mount_offline_package_cache(ctx: InstallContext) -> None:
    """Let pacstrap consume bundled packages without copying them first.

    Pacstrap always points pacman's CacheDir inside the target. Without this
    bind mount, pacman copies every package from the ISO's file:// repository
    into that cache and then extracts it, duplicating several GiB of I/O.
    Mount the already-populated offline repository at the target cache for the
    duration of package installation. It is unmounted before genfstab so the
    live-only bind can never leak into the installed system's fstab.
    """
    source = Path("/var/cache/omarchy/mirror/offline")
    target = ctx.target / "var" / "cache" / "pacman" / "pkg"
    if not source.is_dir():
        raise RuntimeError(f"offline package cache missing: {source}")

    target.mkdir(parents=True, exist_ok=True)
    subprocess.run(["mount", "--bind", str(source), str(target)], check=True)
    ctx.state.setdefault("bind_mounts", []).append(str(target))


def _unmount_offline_package_cache(ctx: InstallContext) -> None:
    target = str(ctx.target / "var" / "cache" / "pacman" / "pkg")
    subprocess.run(["umount", target], check=True)
    try:
        ctx.state.get("bind_mounts", []).remove(target)
    except ValueError:
        pass


def _is_devnull_symlink(path: Path) -> bool:
    try:
        return path.is_symlink() and path.readlink() == Path("/dev/null")
    except OSError:
        return False


def _mask_mkinitcpio_pacman_hooks(
    ctx: InstallContext,
    root: Path = Path("/"),
    names: tuple[str, ...] = DEFERRED_BOOT_HOOKS,
) -> None:
    """Temporarily suppress boot-image pacman hooks around a package install.

    With the default root this masks the LIVE hook dir, which is what pacstrap
    reads: pacstrap uses the live system's /etc/pacman.conf, and pacman.conf(5)
    notes that HookDir is absolute and the target root is not prepended, so
    target-side /mnt/etc/pacman.d/hooks masks do not override target
    /usr/share/libalpm hooks during installation. The target's real hooks still
    get installed and become active after reboot.

    Passing ctx.target masks the same way inside the target, for pacman runs
    that happen under arch-chroot (see TARGET_DEFERRED_BOOT_HOOKS).
    """
    hooks_dir = root / "etc/pacman.d/hooks"
    hooks_dir.mkdir(parents=True, exist_ok=True)
    for name in names:
        path = hooks_dir / name
        backup = hooks_dir / f"{name}.omarchy-backup"
        if _is_devnull_symlink(path):
            continue
        if path.exists() or path.is_symlink():
            backup.unlink(missing_ok=True)
            path.rename(backup)
        path.symlink_to("/dev/null")


def _unmask_mkinitcpio_pacman_hooks(
    ctx: InstallContext,
    root: Path = Path("/"),
    names: tuple[str, ...] = DEFERRED_BOOT_HOOKS,
) -> None:
    hooks_dir = root / "etc/pacman.d/hooks"
    for name in names:
        path = hooks_dir / name
        backup = hooks_dir / f"{name}.omarchy-backup"
        try:
            if _is_devnull_symlink(path):
                path.unlink()
            if backup.exists() or backup.is_symlink():
                backup.rename(path)
        except OSError as exc:
            info(f"warning: failed to restore pacman hook mask for {name}: {exc}")


def _write_language_marker(ctx: InstallContext) -> None:
    """Hand the installer's language to the runtime's finalizers, which
    generate its locale and set it per user. English writes nothing, so an
    English install stays exactly what it was."""
    language = ctx.omarchy_install.get("language")
    if not language or language == "en":
        return
    marker = ctx.target / "etc/omarchy/language"
    marker.parent.mkdir(parents=True, exist_ok=True)
    marker.write_text(language + "\n")
    marker.chmod(0o644)


# ─────────────────────────────────────────────────────────────────────────────
# Install intent helpers: normalize the Omarchy-specific part of the
# configurator JSON so full-disk and pre-mounted installs feed the same boot
# and target setup code.
# ─────────────────────────────────────────────────────────────────────────────

def _boot_intent(ctx: InstallContext) -> dict:
    boot = dict(ctx.omarchy_install.get("boot") or {})
    boot.setdefault("esp_mount", "/boot")
    boot.setdefault("esp_path", "/EFI/limine")
    boot.setdefault("efi_binary", _default_limine_efi_binary())
    # The removable path EFI/BOOT/BOOTX64.EFI is the only route left when
    # firmware refuses or discards the "Limine" boot variable. A full-disk
    # install owns its ESP, so it always takes it. So does a free-space
    # install from the configurator, which formats a dedicated FAT32 ESP
    # in free space ("Always create our own ESP", ef3b0e4) and says so with
    # enable_fallback: true. Any other protected target is a pre-mounted one
    # handed over as it is, whose esp_device may be another OS's ESP and its
    # removable loader that OS's, so it is left alone unless asked for.
    boot.setdefault("enable_fallback", not ctx.is_protected)
    return boot


def _storage_intent(ctx: InstallContext) -> dict:
    return dict(ctx.omarchy_install.get("storage") or {})


def verify_protected_mounts(ctx: InstallContext) -> None:
    target = ctx.target
    boot = _boot_intent(ctx)
    storage = _storage_intent(ctx)

    # Devices before the mountpoint: when the configurator hands over paths for
    # partitions that do not exist, "root_device /dev/nvme0n1p12 does not
    # exist" is diagnosable from the log alone, where "/mnt is not a
    # mountpoint" sends everyone looking at the mount instead of the paths.
    for key in ("esp_device", "root_device"):
        device = storage.get(key)
        if not device:
            raise RuntimeError(f"protected mode: omarchy_install.storage.{key} missing")
        if not Path(device).exists():
            raise RuntimeError(f"protected mode: {key} {device} does not exist")

    if not _is_mountpoint(target):
        raise RuntimeError(f"protected mode: {target} is not a mountpoint")

    esp_mp = target / boot["esp_mount"].lstrip("/")
    if not _is_mountpoint(esp_mp):
        esp_dev = storage["esp_device"]
        info(f"› remounting protected ESP {esp_dev} at {esp_mp}")
        esp_mp.mkdir(parents=True, exist_ok=True)
        subprocess.run(["mount", esp_dev, str(esp_mp)], check=True)

    info(f"› protected target verified: kernel={storage.get('kernel', 'linux-omarchy')} esp={boot['esp_mount']}")


def _is_mountpoint(path: Path) -> bool:
    res = capture(["findmnt", "-rn", str(path)])
    return res.returncode == 0 and bool(res.stdout.strip())


# ── pre-mounted fstab / crypttab / cmdline ───────────────────────────────────

def _btrfs_root_device(ctx: InstallContext) -> str:
    storage = _storage_intent(ctx)
    if storage.get("luks_uuid"):
        return storage.get("root_mapper") or "/dev/mapper/omarchy_root"
    return storage["root_device"]


def _blkid_uuid(device: str) -> str:
    uuid = capture_identifier(
        ["blkid", "-s", "UUID", "-o", "value", device], f"the UUID of {device}"
    )
    if not uuid:
        raise RuntimeError(f"blkid returned no UUID for {device}")
    return uuid


def _esp_device(ctx: InstallContext) -> str:
    storage = _storage_intent(ctx)
    if esp_device := storage.get("esp_device"):
        return esp_device

    boot = _boot_intent(ctx)
    esp_mp = ctx.target / boot["esp_mount"].lstrip("/")
    dev = capture_identifier(
        ["findmnt", "-n", "-o", "SOURCE", str(esp_mp)], f"the ESP device at {esp_mp}"
    )
    if not dev:
        raise RuntimeError(f"could not resolve ESP device at {esp_mp}")
    return dev


def _write_pre_mounted_fstab(ctx: InstallContext) -> None:
    boot = _boot_intent(ctx)
    btrfs_dev = _btrfs_root_device(ctx)
    btrfs_uuid = _blkid_uuid(btrfs_dev)
    esp_uuid = _blkid_uuid(_esp_device(ctx))
    esp_mount = boot["esp_mount"]

    btrfs_opts = "noatime,compress=zstd,subvol="
    lines = [
        "# /etc/fstab — generated by Omarchy ISO",
        "# <device>  <mount>  <fs>  <options>  <dump>  <pass>",
        f"UUID={btrfs_uuid}  /                      btrfs  {btrfs_opts}@       0 0",
        f"UUID={btrfs_uuid}  /home                  btrfs  {btrfs_opts}@home   0 0",
        f"UUID={btrfs_uuid}  /var/log               btrfs  {btrfs_opts}@log    0 0",
        f"UUID={btrfs_uuid}  /var/cache/pacman/pkg  btrfs  {btrfs_opts}@pkg    0 0",
        f"UUID={esp_uuid}  {esp_mount}                   vfat   umask=0077              0 2",
        "",
    ]
    (ctx.target / "etc" / "fstab").write_text("\n".join(lines))


def _write_pre_mounted_crypttab(ctx: InstallContext) -> None:
    storage = _storage_intent(ctx)
    luks_uuid = storage.get("luks_uuid")
    if not luks_uuid:
        return
    crypttab = ctx.target / "etc" / "crypttab.initramfs"
    crypttab.write_text(f"omarchy_root  UUID={luks_uuid}  none  luks,discard,no-read-workqueue\n")


# systemd (257 and later) asks the console for its size with ANSI escape
# sequences when PID 1 starts, and waits for the reply. With Plymouth holding
# the VT the reply sometimes never comes and the boot sits at "Starting Switch
# Root" until a key is pressed: about 1 boot in 10 in QEMU, on the pre-built
# UKI and on the stock busybox initramfs alike (omacom/omarchy#2931, #2665,
# discussions/6267; systemd/systemd#35499 is the same symptom, and Arch's
# systemd 261.2 still shows it after the March/April 2026 fixes). A dumb
# $TERM for the console makes systemd skip every ANSI query: 0 hangs in 80
# boots against 3-7 in 40 without it. It changes nothing visible under
# "quiet splash". Drop it once a systemd release boots clean in a repeated
# boot test.
CONSOLE_NO_ANSI_QUERY = "systemd.tty.term.console=dumb"


def _build_pre_mounted_cmdline(ctx: InstallContext, btrfs_uuid: str) -> str:
    storage = _storage_intent(ctx)
    if storage.get("luks_uuid"):
        root_mapper = storage.get("root_mapper") or "/dev/mapper/omarchy_root"
        return (
            f"cryptdevice=UUID={storage['luks_uuid']}:omarchy_root:allow-discards,no-read-workqueue "
            f"root={root_mapper} zswap.enabled=0 "
            "rootflags=subvol=@ rw rootfstype=btrfs"
        )
    return (
        f"root=UUID={btrfs_uuid} zswap.enabled=0 "
        "rootflags=subvol=@ rw rootfstype=btrfs"
    )


def _write_pre_mounted_limine_defaults(ctx: InstallContext) -> None:
    boot = _boot_intent(ctx)
    btrfs_uuid = _blkid_uuid(_btrfs_root_device(ctx))
    cmdline = _build_pre_mounted_cmdline(ctx, btrfs_uuid)

    _write_pre_mounted_crypttab(ctx)
    _write_limine_defaults(
        ctx,
        cmdline,
        esp_mount=boot["esp_mount"],
        enable_fallback=bool(boot.get("enable_fallback")),
    )


# ── efibootmgr ───────────────────────────────────────────────────────────────

_BOOT_ENTRY_RE = re.compile(r"^Boot([0-9A-Fa-f]{4})(\*?)\s+(.*)$")
_BOOT_ORDER_RE = re.compile(r"^BootOrder:\s*(.*)$")


def _read_efibootmgr() -> dict:
    """The boot entries and BootOrder, as `efibootmgr --verbose` lists them,
    and under "inactive" the entries listed without the "*" that marks
    LOAD_OPTION_ACTIVE, which firmware skips in BootOrder.

    A UEFI boot can still have no EFI variable store: efi=noruntime, or
    firmware that faulted so the kernel turned runtime services off (T2
    Macs; a Lenovo X13s). efibootmgr then exits 2 with "EFI variables are
    not supported on this system." That reads as no entries, with the reason
    under "unreadable", so each caller can skip what cannot work instead of
    the phase dying before the removable loader is written.
    """
    res = capture(["efibootmgr", "--verbose"])
    entries: dict[str, str] = {}
    inactive: set[str] = set()
    order: list[str] = []
    if res.returncode != 0:
        reason = (res.stderr or "").strip() or f"efibootmgr exited {res.returncode}"
        return {"entries": entries, "inactive": inactive, "order": order, "raw": res.stdout, "unreadable": reason}
    for line in res.stdout.splitlines():
        m = _BOOT_ENTRY_RE.match(line)
        if m:
            num = m.group(1).upper()
            entries[num] = m.group(3).strip()
            if not m.group(2):
                inactive.add(num)
            continue
        m = _BOOT_ORDER_RE.match(line)
        if m:
            order = [n.strip().upper() for n in m.group(1).split(",") if n.strip()]
    return {"entries": entries, "inactive": inactive, "order": order, "raw": res.stdout}


def _find_label_entries(entries: dict[str, str], needle: str) -> list[str]:
    return [num for num, label in entries.items() if needle.lower() in label.lower()]


def _is_limine_entry_for(entry: str, guid: str, loader: str) -> bool:
    """Whether a `efibootmgr --verbose` entry is the one
    _register_limine_efi_entry creates: labelled "Limine", starting `loader`
    from the partition with GPT GUID `guid`. The listing reads
    "Limine<TAB>HD(part,GPT,<guid>,...)/\\EFI\\...", or ".../File(\\EFI\\...)"
    with an older efivar; FAT is case-insensitive, and so is this. The loader's
    name has to end where `loader` ends: \\EFI\\limine\\limine_x64.efi.bak is
    another boot option, not this one."""
    label, _, path = entry.lower().partition("\t")
    loader = re.escape(loader.lower())
    return (
        label.strip() == "limine"
        and bool(guid) and guid in path
        and re.search(rf"(\)/{loader}|file\({loader}\))(?![\w.-])", path) is not None
    )


def _partition_guid(disk: Path, part: int) -> str:
    """The GPT partition GUID of partition `part` on `disk`, lower case, as
    efibootmgr prints it in a boot entry's device path; "" if unknown."""
    res = capture(["lsblk", "-nlo", "PARTN,PARTUUID", str(disk)])
    for line in res.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] == str(part):
            return fields[1].lower()
    return ""


def _mounted_partition_guid(mountpoint: Path) -> str:
    """The GPT partition GUID of what is mounted at `mountpoint`, lower case,
    as efibootmgr prints it; "" if unknown."""
    source = capture(["findmnt", "-no", "SOURCE", str(mountpoint)]).stdout.strip()
    if not source:
        return ""
    return capture(["lsblk", "-ndo", "PARTUUID", source]).stdout.strip().lower()


def _split_partition_device(part_dev: str) -> tuple[str, int]:
    parent = capture_identifier(
        ["lsblk", "-ndo", "PKNAME", part_dev], f"the parent disk of {part_dev}"
    )
    if not parent:
        raise RuntimeError(f"could not find parent disk for {part_dev}")
    part_num = capture_identifier(
        ["lsblk", "-ndo", "PARTN", part_dev], f"the partition number of {part_dev}"
    )
    if not part_num:
        raise RuntimeError(f"could not find partition number for {part_dev}")
    return f"/dev/{parent}", int(part_num)


def configure_hibernation(ctx: InstallContext) -> None:
    """Configure swap/resume in the target as root before user setup.

    Hibernation is system boot configuration, not per-user setup. The final
    Limine UKI build still happens later in finalize_limine_boot after this
    writes the resume hook and kernel cmdline drop-in.
    """
    setup = ctx.target / "usr" / "bin" / "omarchy-hibernation-setup"
    if not setup.exists():
        _debug_log(ctx, "skipping hibernation: /usr/bin/omarchy-hibernation-setup is not installed")
        return

    subprocess.run([
        "arch-chroot", str(ctx.target),
        "env",
        "OMARCHY_PATH=/usr/share/omarchy",
        "OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log",
        "/usr/bin/omarchy-hibernation-setup", "--force", "--no-rebuild",
    ], check=True)


def _install_debug_enabled() -> bool:
    return os.environ.get("OMARCHY_INSTALL_DEBUG") == "1" or Path("/usr/share/omarchy-iso/install-debug").exists()


def _debug_log(ctx: InstallContext, message: str) -> None:
    if not _install_debug_enabled():
        return
    ctx.log_path.parent.mkdir(parents=True, exist_ok=True)
    with ctx.log_path.open("a", encoding="utf-8") as log:
        log.write(f"[install-debug] {message}\n")


def _debug_dump_file(ctx: InstallContext, path: Path, max_lines: int = 120) -> None:
    if not _install_debug_enabled():
        return
    try:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        _debug_log(ctx, f"dumping {path} sha256={digest}")
        with ctx.log_path.open("a", encoding="utf-8") as log:
            for line_no, line in enumerate(path.read_text(errors="replace").splitlines(), start=1):
                if line_no > max_lines:
                    log.write(f"[install-debug] ... truncated after {max_lines} lines ...\n")
                    break
                log.write(f"[install-debug] {path}:{line_no}: {line}\n")
    except OSError as exc:
        _debug_log(ctx, f"unable to dump {path}: {exc}")


def _debug_run(ctx: InstallContext, cmd: list[str]) -> None:
    if not _install_debug_enabled():
        return
    _debug_log(ctx, "+ " + " ".join(cmd))
    proc = capture(cmd)
    if proc.stdout:
        with ctx.log_path.open("a", encoding="utf-8") as log:
            for line in proc.stdout.splitlines():
                log.write(f"[install-debug] stdout: {line}\n")
    if proc.stderr:
        with ctx.log_path.open("a", encoding="utf-8") as log:
            for line in proc.stderr.splitlines():
                log.write(f"[install-debug] stderr: {line}\n")
    _debug_log(ctx, f"exit {proc.returncode}: " + " ".join(cmd))


# ─────────────────────────────────────────────────────────────────────────────
# Target setup phases:
#  1. point the target at the offline pacman.conf
#  2. bind-mount the offline mirror into /mnt for target pacman, and the
#     bundled Node for a runtime from before Omarchy installed Node lazily
#  3. arch-chroot as root → omarchy-apply-system --first-install
#  4. arch-chroot as user → omarchy-provision-user --first-install
# ─────────────────────────────────────────────────────────────────────────────

def _prepare_target_setup(ctx: InstallContext) -> None:
    if ctx.state.get("target_setup_prepared"):
        return

    shutil.copy("/etc/pacman.conf", str(ctx.target / "etc" / "pacman.conf"))

    bind_mounts = [
        ("/var/cache/omarchy/mirror/offline", "/var/cache/omarchy/mirror/offline"),
    ]
    # build-iso.sh bundles Node only for a runtime whose setup still unpacks it.
    if NODE_PACKAGES_DIR.is_dir():
        bind_mounts.append((str(NODE_PACKAGES_DIR), str(NODE_PACKAGES_DIR)))
    ctx.state.setdefault("bind_mounts", [])
    mounted = set(ctx.state["bind_mounts"])
    for src, dst in bind_mounts:
        target_dst = ctx.target / dst.lstrip("/")
        target_dst.mkdir(parents=True, exist_ok=True)
        if str(target_dst) not in mounted:
            subprocess.run(["mount", "--bind", src, str(target_dst)], check=True)
            ctx.state["bind_mounts"].append(str(target_dst))
            mounted.add(str(target_dst))

    _copy_firmware_stage_into_target(ctx)

    ctx.state["target_setup_prepared"] = True


def _ensure_finalizer_log_started(ctx: InstallContext) -> tuple[str, int]:
    if "omarchy_start_time" not in ctx.state:
        ctx.state["omarchy_start_epoch"] = int(time.time())
        ctx.state["omarchy_start_time"] = time.strftime("%Y-%m-%d %H:%M:%S")

    ctx.log_path.parent.mkdir(parents=True, exist_ok=True)
    ctx.log_path.touch(exist_ok=True)
    ctx.log_path.chmod(0o666)

    if not ctx.state.get("omarchy_finalizer_header_written"):
        with ctx.log_path.open("a", encoding="utf-8") as log:
            log.write(f"=== Omarchy Target Setup Started: {ctx.state['omarchy_start_time']} ===\n")
        ctx.state["omarchy_finalizer_header_written"] = True

    return ctx.state["omarchy_start_time"], ctx.state["omarchy_start_epoch"]


def _target_user_env(ctx: InstallContext, user: str) -> list[str]:
    home = f"/home/{user}"
    shell = "/bin/bash"
    passwd = ctx.target / "etc" / "passwd"

    try:
        for line in passwd.read_text(errors="ignore").splitlines():
            fields = line.split(":")
            if len(fields) >= 7 and fields[0] == user:
                home = fields[5] or home
                shell = fields[6] or shell
                break
    except OSError:
        pass

    return [
        f"HOME={home}",
        f"USER={user}",
        f"LOGNAME={user}",
        f"SHELL={shell}",
    ]


# Omarchy's run_logged prints "[<date> <time>] Starting: <script>" as a script
# begins and "Completed:" (or "Failed:") as it ends.
_OMARCHY_SCRIPT_LINE = re.compile(rb"^\[[0-9: -]+\] (Starting|Completed|Failed): (\S+)")


def _run_timing_scripts(cmd: list[str]) -> None:
    """Run cmd with its output passed through line by line, and after each
    Omarchy install script it runs, add a [step] line with its duration in
    microseconds.

    run_logged stamps its lines in whole seconds (bash printf %T), too coarse
    for a phase that runs about 50 scripts in 3 s. It prints them unbuffered as
    each script starts and ends, so the time they arrive here is the script's
    own. The output goes where it went before, stderr folded into stdout as
    the dashboard already merges them.

    An interrupt or a failed write stops and reaps the child before it
    propagates, as subprocess.run does: the caller unmounts the log and tears
    the target down next, which must not race a setup still running."""
    out = sys.stdout.buffer
    started: dict[bytes, float] = {}
    with subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as proc:
        try:
            for line in proc.stdout:
                now = time.monotonic()
                out.write(line)
                out.flush()
                match = _OMARCHY_SCRIPT_LINE.match(line)
                if not match:
                    continue
                event, script = match.groups()
                if event == b"Starting":
                    started[script] = now
                elif script in started:
                    name = script.decode(errors="replace").removeprefix("/usr/share/omarchy/install/")
                    info(f"[step] {name}: {now - started.pop(script):.6f}s")
        except BaseException:
            proc.kill()
            proc.wait()
            raise
        returncode = proc.wait()
    if returncode != 0:
        raise subprocess.CalledProcessError(returncode, cmd)


def _run_target_setup_command(ctx: InstallContext, cmd: list[str], *, user: str | None = None,
                              private_mounts: bool = False) -> None:
    _prepare_target_setup(ctx)
    omarchy_start_time, omarchy_start_epoch = _ensure_finalizer_log_started(ctx)

    target_log = ctx.target / "var" / "log" / "omarchy-install.log"
    target_log.parent.mkdir(parents=True, exist_ok=True)
    target_log.touch(exist_ok=True)
    target_log.chmod(0o666)

    log_bind_mounted = False
    try:
        subprocess.run(["mount", "--bind", str(ctx.log_path), str(target_log)], check=True)
        log_bind_mounted = True
    except subprocess.CalledProcessError as exc:
        with ctx.log_path.open("a", encoding="utf-8") as log:
            log.write(f"[orchestrator] WARNING: failed to bind unified setup log: {exc}\n")

    mirror_channel = _read_omarchy_mirror()
    env_extras = [
        "OMARCHY_PATH=/usr/share/omarchy",
        "OMARCHY_INSTALL=/usr/share/omarchy/install",
        f"OMARCHY_INSTALL_USER={ctx.username}",
        f"OMARCHY_START_TIME={omarchy_start_time}",
        f"OMARCHY_START_EPOCH={omarchy_start_epoch}",
        f"OMARCHY_MIRROR={mirror_channel}",
        f"OMARCHY_ISO_REF={_iso_ref()}",
        f"OMARCHY_RUNTIME_PACKAGE={_omarchy_runtime_package()}",
        f"OMARCHY_SETTINGS_PACKAGE={_omarchy_settings_package()}",
        f"OMARCHY_NVIM_PACKAGE={_omarchy_nvim_package()}",
        "OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log",
        "OMARCHY_LOG_TO_STDOUT=1",
        # The install must not wait on a network it may not have. mise reshim
        # resolves the version list of every tool declared in
        # /etc/mise/conf.d/omarchy-tools.toml, all of them version = "latest":
        # offline, each lookup waits out mise's HTTP timeout before falling
        # back, and the user finalizer measured 40.10 s that way (five tools at
        # 20 s) on a 65 s install. The tools are lazy, so reshim only needs the
        # declarations; the first real use of a tool installs it later, with a
        # network. MISE_OFFLINE blocks every HTTP request.
        "MISE_OFFLINE=1",
    ]
    if _install_debug_enabled():
        env_extras.append("OMARCHY_INSTALL_DEBUG=1")
        _debug_log(ctx, "running target setup command: " + " ".join(cmd))

    # A private mount namespace keeps this arch-chroot's /proc, /sys and /dev
    # mounts (and their teardown) away from another chroot running on the same
    # target at the same time (finalize_boot_and_user).
    chroot_cmd = ["unshare", "-m", "--propagation", "private", "arch-chroot"] if private_mounts else ["arch-chroot"]
    # snapper closes every fd up to RLIMIT_NOFILE in each of the four
    # processes it forks during create-config. In a traced install that took
    # 2.86 s; with the limit at 65536 the same command takes 0.04 s, at
    # 524288 0.18 s. Nothing the finalizers run needs more than 65536.
    chroot_cmd = ["prlimit", "--nofile=65536:65536", *chroot_cmd]
    if user:
        chroot_cmd += ["-u", user]
        env_extras.extend(_target_user_env(ctx, user))
    chroot_cmd += [str(ctx.target), "env", "--unset=XDG_RUNTIME_DIR", *env_extras, *cmd]

    try:
        _run_timing_scripts(chroot_cmd)
    finally:
        if log_bind_mounted:
            subprocess.run(["umount", str(target_log)], check=False, capture_output=True)
            try:
                shutil.copy2(ctx.log_path, target_log)
                target_log.chmod(0o644)
            except OSError:
                pass
        else:
            try:
                with ctx.log_path.open("a", encoding="utf-8") as live_log:
                    live_log.write("\n=== Target setup log ===\n")
                    live_log.write(target_log.read_text(errors="ignore"))
            except OSError:
                pass


def run_system_finalizer(ctx: InstallContext) -> None:
    if ctx.defer_provisioning:
        cmd = ["/usr/bin/omarchy-apply-system", "--defer-provisioning", "--first-install"]
    else:
        cmd = ["/usr/bin/omarchy-apply-system", "--install-user", ctx.username, "--first-install"]

    # On aarch64 the runtime runs pacman-key --init and --populate on the
    # target (omarchy's install/post-install/pacman.sh). Two pacman-keys on
    # one gnupg dir break each other's writes, so the keyring unit finishes
    # first; on x86_64 it keeps running alongside.
    if platform.machine() == "aarch64":
        _join_target_keyring_init(ctx)

    _mask_mkinitcpio_pacman_hooks(ctx, ctx.target, TARGET_DEFERRED_BOOT_HOOKS)
    try:
        _run_target_setup_command(ctx, cmd)
    finally:
        _unmask_mkinitcpio_pacman_hooks(ctx, ctx.target, TARGET_DEFERRED_BOOT_HOOKS)


# ─────────────────────────────────────────────────────────────────────────────
# stage_provisioning_state: produce the on-disk "provisioning state" the runtime's first-boot
# setup (omarchy-provision-owner) and factory reset (omarchy-system-factory-reset) consume.
#
# When the ISO bundles Node (a runtime from before Omarchy installed Node
# lazily), every install keeps it in /var/lib/omarchy/provisioning/packages:
# that runtime's first-boot setup and factory reset finalize a user offline
# from there, after /opt/packages is gone. Deferred-provisioning installs
# additionally arm the first-boot setup service and, on encrypted targets,
# stage the throwaway LUKS passphrase: the keyfile embedded in the initramfs
# auto-unlocks boot during the provisioning window, and first-boot setup
# re-keys the volume to the owner's password and removes it.
#
# Runs before finalize_limine_boot so the cryptkey cmdline drop-in and the
# keyfile land in the final UKI build.
# ─────────────────────────────────────────────────────────────────────────────

PROVISION_STATE_DIR = "var/lib/omarchy/provisioning"
PROVISION_KEYFILE = "etc/omarchy/provisioning.key"
PROVISION_KEY_DROPIN = "etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf"
NODE_PACKAGES_DIR = Path("/opt/packages")


def stage_provisioning_state(ctx: InstallContext) -> None:
    # World-readable: first-boot finalization reads the Node tarball as the
    # new user. The only secret inside (luks-key) is itself 0600 root.
    provisioning_dir = ctx.target / PROVISION_STATE_DIR
    provisioning_dir.mkdir(parents=True, exist_ok=True)
    provisioning_dir.chmod(0o755)

    _stage_node_tarball(provisioning_dir)

    if not ctx.defer_provisioning:
        return

    service_src = ctx.target / "usr/share/omarchy/install/provisioning/omarchy-provision-owner.service"
    setup_bin = ctx.target / "usr/bin/omarchy-provision-owner"
    if not service_src.exists() or not setup_bin.exists():
        raise RuntimeError(
            "deferred-provisioning install requested, but the installed Omarchy runtime does not ship "
            "first-boot setup (omarchy-provision-owner + install/provisioning/omarchy-provision-owner.service). "
            "Update the runtime package this ISO bundles before installing in deferred provisioning."
        )

    info("› arming first-boot setup")
    (provisioning_dir / "pending").touch()

    unit_dst = ctx.target / "etc/systemd/system/omarchy-provision-owner.service"
    unit_dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(service_src, unit_dst)
    wants_dir = ctx.target / "etc/systemd/system/multi-user.target.wants"
    wants_dir.mkdir(parents=True, exist_ok=True)
    link = wants_dir / "omarchy-provision-owner.service"
    link.unlink(missing_ok=True)
    link.symlink_to("/etc/systemd/system/omarchy-provision-owner.service")

    if _provision_install_encrypted(ctx):
        _stage_provisioning_luks_unlock(ctx, provisioning_dir)


# build-iso.sh bundles the build for the CPU the ISO runs on, and only for a
# runtime whose setup unpacks it; with none bundled there is nothing to keep.
def _stage_node_tarball(provisioning_dir) -> None:
    tarballs = sorted(NODE_PACKAGES_DIR.glob("node-v*.tar.gz"))
    if not tarballs:
        return

    packages_dir = provisioning_dir / "packages"
    packages_dir.mkdir(parents=True, exist_ok=True)
    target_tarball = packages_dir / tarballs[0].name
    if not target_tarball.exists():
        info("› stashing Node tarball for offline first-boot setup")
        shutil.copy2(tarballs[0], target_tarball)


def _provision_install_encrypted(ctx: InstallContext) -> bool:
    if _storage_intent(ctx).get("luks_uuid"):
        return True
    disk_encryption = (ctx.user_configuration.get("disk_config") or {}).get("disk_encryption")
    if disk_encryption and disk_encryption.get("encryption_type", "luks") != "no_encryption":
        return True
    return ctx.encrypt


def _provision_encryption_password(ctx: InstallContext) -> str | None:
    disk_encryption = (ctx.user_configuration.get("disk_config") or {}).get("disk_encryption") or {}
    return disk_encryption.get("encryption_password") or ctx.user_credentials.get("encryption_password")


def _stage_provisioning_luks_unlock(ctx: InstallContext, provisioning_dir) -> None:
    password = _provision_encryption_password(ctx)
    if not password:
        # Full-disk deferred-provisioning installs get a generated passphrase injected by
        # InstallContext; only a pre-mounted (rig-partitioned) LUKS target can
        # land here, and it must hand over the passphrase it formatted with.
        raise RuntimeError(
            "deferred-provisioning install on a pre-encrypted target requires the LUKS passphrase "
            "in user_credentials.json (encryption_password) so first boot can re-key"
        )

    info("› staging LUKS auto-unlock for the provisioning window")

    # Byte-for-byte the slot passphrase: no trailing newline anywhere.
    luks_key = provisioning_dir / "luks-key"
    luks_key.write_text(password)
    luks_key.chmod(0o600)

    keyfile = ctx.target / PROVISION_KEYFILE
    keyfile.parent.mkdir(parents=True, exist_ok=True)
    keyfile.write_text(password)
    keyfile.chmod(0o600)

    cmdline_dropin = ctx.target / "etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf"
    cmdline_dropin.parent.mkdir(parents=True, exist_ok=True)
    cmdline_dropin.write_text(
        'KERNEL_CMDLINE[default]+=" cryptkey=rootfs:/etc/omarchy/provisioning.key"\n'
    )

    files_dropin = ctx.target / PROVISION_KEY_DROPIN
    files_dropin.parent.mkdir(parents=True, exist_ok=True)
    files_dropin.write_text("FILES+=(/etc/omarchy/provisioning.key)\n")


def _initramfs_carries_provisioning_key(target: Path) -> bool:
    """Whether the initramfs has to carry the provisioning unlock key, which
    the pre-built UKI (FILES=(), sd-encrypt, which ignores cryptkey=) lacks."""
    return (target / PROVISION_KEY_DROPIN).is_file()


def _initramfs_module_lines(target: Path) -> set[str]:
    """The MODULES+= lines mkinitcpio will honour on this target."""
    lines = set()
    for conf in sorted((target / "etc" / "mkinitcpio.conf.d").glob("*.conf")):
        for line in conf.read_text(errors="ignore").splitlines():
            if re.match(r"\s*MODULES\s*\+?=", line):
                lines.add(" ".join(line.split()))
    return lines


def _prebuilt_module_lines(target: Path) -> set[str]:
    """The same lines as they were when the image's UKI was built
    (build-root-image.sh records them next to it)."""
    recorded = target / "var" / "lib" / "omarchy-iso" / "prebuilt-uki.modules"
    if not recorded.is_file():
        return set()
    return {line for line in recorded.read_text().splitlines() if line}


def _keymap_of(vconsole: Path) -> str:
    """KEYMAP= from a vconsole.conf, or "" when unset or unreadable."""
    if not vconsole.is_file():
        return ""
    for line in vconsole.read_text().splitlines():
        line = line.strip()
        if line.startswith("KEYMAP="):
            return line.partition("=")[2].strip().strip('"\'')
    return ""


def _prebuilt_uki_keymap_stale(target: Path) -> str:
    """The chosen console keymap when it differs from the one baked into the
    image's UKI, else "".

    mkinitcpio's `keymap` hook compiles the keymap named by /etc/vconsole.conf
    at build time and omarchy_hooks.conf bundles vconsole.conf for Plymouth, so
    the pre-built UKI is frozen to whatever the image had. configure_keyboard
    writes the user's choice to the target afterwards, which never reaches a
    UKI that is only copied. The LUKS passphrase prompt runs from that
    initramfs: leaving it stale is upstream omarchy#8196, where a passphrase
    enrolled under AZERTY cannot be typed at a QWERTY prompt and the owner is
    locked out of a fresh install with no recovery but reinstalling.

    An image that records nothing is assumed to have built in "us", and that
    covers two cases:

      * the file is absent: an image built before the keymap was recorded;
      * the file is present and empty: the normal case, because the image
        carries no /etc/vconsole.conf for mkinitcpio to read.

    Both mean the same thing: mkinitcpio fell back to us, which is what the
    pre-built UKIs contain (extracting .initrd from one gives us.map.gz and
    no vconsole.conf). Reading the empty file as a keymap of "" would make
    every ordinary us install differ from it and rebuild the UKI: correct,
    but about 4 s slower for no gain. Treating an unknown as a match would be
    faster still and would leave the lockout in place on every image without
    the record; being wrong that way costs the owner their disk, so unknown
    resolves to us, not to "skip the check".
    """
    recorded = target / "var" / "lib" / "omarchy-iso" / "prebuilt-uki.keymap"
    baked = (recorded.read_text().strip() if recorded.is_file() else "") or "us"
    chosen = _keymap_of(target / "etc" / "vconsole.conf")
    return chosen if chosen and chosen != baked else ""


def _is_apple_t2_hardware() -> bool:
    """Only Apple T2 Macs need the linux-t2 kernel. Everywhere else its
    mkinitcpio preset is dropped, so the boot step does not build and register
    an initramfs and a UKI for a second kernel."""
    try:
        result = subprocess.run(
            ["dmidecode", "-s", "system-manufacturer"],
            capture_output=True, text=True, check=True
        )
        return "apple" in result.stdout.strip().lower()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


INITRAMFS_MODULES_CONF = "zz-omarchy-kernel-modules.conf"


def _drop_initramfs_modules_the_kernel_lacks(ctx: InstallContext) -> None:
    """Keep mkinitcpio from failing on a module the installed kernel was built
    without.

    The Omarchy settings name modules for the kernels Omarchy ships, thunderbolt
    among them. mkinitcpio reports a name it cannot find as an error, and
    limine-mkinitcpio-hook then builds the unified kernel image but does not
    install it: Arch Linux ARM's linux-aarch64 has no thunderbolt module, and
    the machine was left with no kernel to boot. A drop-in that sorts last takes
    the names this kernel lacks back out of MODULES.
    """
    conf_dir = ctx.target / "etc" / "mkinitcpio.conf.d"
    drop_in = conf_dir / INITRAMFS_MODULES_CONF
    listed: list[str] = []
    for conf in sorted(conf_dir.glob("*.conf")) if conf_dir.is_dir() else []:
        if conf.name == INITRAMFS_MODULES_CONF:
            continue
        for match in re.finditer(r"^\s*MODULES\+?=\(([^)]*)\)", conf.read_text(), re.M):
            listed += [name.strip("\"'") for name in match.group(1).split()]

    missing: list[str] = []
    for directory, _ in _kernel_directories(ctx):
        for module in listed:
            if module in missing or not re.fullmatch(r"[A-Za-z0-9_-]+", module):
                continue
            found = subprocess.run(
                ["modinfo", "--basedir", str(ctx.target), "-k", directory.name, module],
                capture_output=True,
            )
            if found.returncode != 0:
                missing.append(module)

    if not missing:
        drop_in.unlink(missing_ok=True)
        return
    info(f"› leaving out of the initramfs, not in this kernel: {' '.join(missing)}")
    drop_in.write_text(
        "# Written by the Omarchy installer. The installed kernel has no such\n"
        "# modules, and mkinitcpio fails on a module it cannot find.\n"
        f"_omarchy_absent=({' '.join(missing)})\n"
        "_omarchy_kept=()\n"
        'for _omarchy_module in "${MODULES[@]}"; do\n'
        '  [[ " ${_omarchy_absent[*]} " == *" $_omarchy_module "* ]] || _omarchy_kept+=("$_omarchy_module")\n'
        "done\n"
        'MODULES=("${_omarchy_kept[@]}")\n'
        "unset _omarchy_absent _omarchy_kept _omarchy_module\n"
    )


def finalize_limine_boot(ctx: InstallContext) -> None:
    """Finalize Limine after target system setup has written all dynamic
    boot drop-ins (hibernation, hardware quirks, protected-mode ESP settings).
    """
    if not (ctx.target / "usr" / "bin" / "limine-update").exists():
        raise RuntimeError("/usr/bin/limine-update missing in target")

    # Skip the linux-t2 mkinitcpio work on machines that did not select it.
    selected_kernels = ctx.user_configuration.get("kernels") or []
    if "linux-t2" not in selected_kernels and not _is_apple_t2_hardware():
        for preset in ("linux-t2.preset",):
            path = ctx.target / "etc" / "mkinitcpio.d" / preset
            if path.exists():
                path.unlink()
                info(f"› not Apple T2 hardware: skipped {preset}")

    default_limine = ctx.target / "etc" / "default" / "limine"
    if not default_limine.exists():
        raise RuntimeError(f"{default_limine} missing")

    default_text = default_limine.read_text()
    if "@@CMDLINE@@" in default_text:
        raise RuntimeError(f"{default_limine} still contains @@CMDLINE@@")

    config_text = _limine_combined_config_text(ctx, default_text)
    cmdline = _limine_kernel_cmdline(config_text)
    if not cmdline.strip():
        raise RuntimeError(f"{default_limine} has no KERNEL_CMDLINE[default]+= line")
    if "root=" not in cmdline:
        raise RuntimeError(f"cmdline parsed from {default_limine} has no root=: {cmdline}")

    esp_path = _limine_setting(config_text, "ESP_PATH", "/boot") or "/boot"
    esp_root = ctx.target / esp_path.lstrip("/")
    if not esp_root.is_dir():
        raise RuntimeError(f"Limine ESP_PATH does not exist in target: {esp_root}")

    snapper_root = ctx.target / "etc" / "snapper" / "configs" / "root"
    if not snapper_root.exists():
        raise RuntimeError(f"{snapper_root} missing")

    limine_conf = esp_root / "limine.conf"
    if not limine_conf.exists():
        raise RuntimeError(f"{limine_conf} missing")

    _drop_initramfs_modules_the_kernel_lacks(ctx)

    # limine-update, run as its two steps so that each is timed.
    with _time_step("LIMINE.limine-install --no-efi-register"):
        subprocess.run(
            ["arch-chroot", str(ctx.target), "limine-install", "--no-efi-register"],
            check=True,
        )

    # With a pre-built UKI in the image, copy it to the ESP and skip the ~4 s
    # of limine-mkinitcpio. Without one, build it here as before.
    #
    # Encrypted installs take the pre-built path too. build-root-image.sh
    # builds the UKI with the systemd hook set plus sd-encrypt, and Limine
    # passes it the install's cmdline from its entry: rd.luks.name= names the
    # LUKS partition and root=/dev/mapper/root the filesystem, so sd-encrypt
    # unlocks it at a passphrase prompt. The same cmdline goes to
    # /etc/default/limine and /etc/kernel/cmdline, where cryptdevice= serves
    # the busybox initramfs the first kernel update's limine-mkinitcpio builds.
    prebuilt_uki = ctx.target / "var" / "lib" / "omarchy-iso" / "prebuilt-uki.efi"
    # Limine names a UKI after the kernel package it belongs to, and the image
    # records which one it was built with (stock linux on older images).
    prebuilt_kernel_file = ctx.target / "var" / "lib" / "omarchy-iso" / "prebuilt-uki.kernel"
    prebuilt_kernel = prebuilt_kernel_file.read_text().strip() if prebuilt_kernel_file.is_file() else "linux"
    uki_name = f"{_uki_prefix(ctx.target, config_text)}_{prebuilt_kernel}.efi"
    esp_uki = esp_root / "EFI" / "Linux" / uki_name
    used_prebuilt_uki = False

    # The pre-built UKI was made before any hardware script ran. nvidia.sh and
    # fix-t2.sh add early-loading modules (MODULES+= in mkinitcpio.conf.d), and
    # a UKI without them is not what omarchy configured: on an NVIDIA machine
    # it carries nouveau, no nvidia module and none of nvidia-utils' nouveau
    # blacklist. Such a machine gets its UKIs built here, the way upstream
    # builds them for everyone; the pre-built one stays the fast path for
    # every machine that adds nothing.
    added_modules = sorted(_initramfs_module_lines(ctx.target) - _prebuilt_module_lines(ctx.target))
    if prebuilt_uki.is_file() and added_modules:
        info(f"› hardware setup added initramfs modules ({'; '.join(added_modules)}); "
             "building the UKI on this machine instead of using the pre-built one")

    # Same reasoning for the console keymap: the pre-built initramfs has the
    # image's, and the LUKS prompt types with it.
    stale_keymap = _prebuilt_uki_keymap_stale(ctx.target)
    if prebuilt_uki.is_file() and stale_keymap:
        info(f"› keyboard layout {stale_keymap} differs from the pre-built UKI's; "
             "building the UKI on this machine so the LUKS prompt uses it")
    # And for an encrypted deferred install: its first boot unlocks with the
    # provisioning key, which only an initramfs built here carries.
    provisioning_key = _initramfs_carries_provisioning_key(ctx.target)
    if prebuilt_uki.is_file() and provisioning_key:
        info("› the first boot unlocks with the provisioning key; "
             "building the UKI on this machine so its initramfs carries it")
    skip_prebuilt = bool(added_modules) or bool(stale_keymap) or provisioning_key

    # A selected kernel other than the image's boots first, as in omarchy's own
    # kernel migration. Written before any UKI is built so the entries sort by it.
    selected = next((k for k in selected_kernels if k != prebuilt_kernel and k in _installed_kernels(ctx)), None)
    if selected:
        text = "\n".join(l for l in default_limine.read_text().splitlines() if not re.match(r"\s*BOOT_ORDER\s*=", l))
        default_limine.write_text(f'{text}\nBOOT_ORDER="{selected}, {selected}-*, *, *fallback, Snapshots"\n')
        info(f"› {selected} boots first; the pre-built UKI is for {prebuilt_kernel}")

    # A UKI is a UEFI executable. On BIOS firmware Limine boots a kernel and
    # initramfs pair, and limine-entry-tool --add-uki refuses ("Your system is
    # not using EFI mode"), so such a machine builds its boot files the normal
    # way below.
    if prebuilt_uki.is_file() and not skip_prebuilt and not arch.has_uefi():
        info("› BIOS firmware; the pre-built UKI is UEFI-only, building the boot files on this machine")

    # A board with a platform of its own boots by its hardware scripts' rules
    # (the N1x: the console on the panel in every entry, a fallback UKI as the
    # rescue entry; validate_boot checks them), which limine-mkinitcpio applies
    # and a UKI built in the image cannot know. Every other machine, a generic
    # aarch64 one included, takes the image's UKI.
    if prebuilt_uki.is_file() and not skip_prebuilt and arch.has_uefi() and not _arm_platform_boot():
        used_prebuilt_uki = True
        with _time_step("LIMINE.deploy_prebuilt_uki (copy from image)"):
            esp_uki.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(prebuilt_uki, esp_uki)
            info(f"› deployed pre-built UKI ({prebuilt_uki.stat().st_size >> 20} MiB)")
        # Before --add-uki: the Limine entry pins the UKI's BLAKE2B hash.
        with _time_step("LIMINE.embed_cmdline (pre-built UKI boots without a loader)"):
            from .uki_cmdline import embed_cmdline
            if embed_cmdline(esp_uki, cmdline):
                info("› UKI carries this install's cmdline; bootable from any loader")
            else:
                info("› WARNING: UKI cmdline not embedded; only the Limine entry can boot it")
        # Register the boot entry in limine.conf, which limine-mkinitcpio
        # would have done after building the UKI. Without it limine.conf has
        # no Omarchy entry and the firmware menu comes up instead. Mirrors
        # install_uki() in limine-mkinitcpio-install.
        with _time_step("LIMINE.limine-entry-tool --add-uki (register boot entry)"):
            subprocess.run(
                ["arch-chroot", str(ctx.target), "limine-entry-tool",
                 "--add-uki", prebuilt_kernel, f"{esp_path.rstrip('/')}/EFI/Linux/{uki_name}",
                 "--comment", "Pre-built UKI",
                 "--no-mutex", "--no-hooks"],
                check=True,
            )
        # The pre-built UKI covers one kernel, the one the image was built
        # with. A machine that selected another (linux-t2 on a T2 Mac; the base
        # delta installed it) has the package on disk and every T2 setting
        # written, but no UKI or boot entry for it: it would boot the image's
        # kernel, which has no driver for the T2's keyboard. Build those the
        # normal way; the selected kernel is put first, as omarchy's own
        # kernel migration does.
        extra_kernels = [k for k in _installed_kernels(ctx) if k != prebuilt_kernel]
        for kernel in extra_kernels:
            with _time_step(f"LIMINE.limine-mkinitcpio {kernel} (not covered by the pre-built UKI)"):
                subprocess.run(["arch-chroot", str(ctx.target), "limine-mkinitcpio", kernel], check=True)
    else:
        with _time_step("LIMINE.limine-mkinitcpio (built on this machine)"):
            subprocess.run(
                ["arch-chroot", str(ctx.target), "limine-mkinitcpio"],
                check=True,
            )

    subprocess.run(
        ["arch-chroot", str(ctx.target), "btrfs", "quota", "disable", "/"],
        check=False,
        capture_output=True,
    )
    if "Omarchy" not in limine_conf.read_text():
        raise RuntimeError(f"{limine_conf} has no Omarchy entry")
    # limine-mkinitcpio wrote the entry itself, so its cmdline is checked
    # here. A pre-built UKI's entry comes from limine-entry-tool, and
    # validate_boot checks the cmdline that install ends up with.
    if "cryptdevice=" in cmdline and not used_prebuilt_uki and "cryptdevice=" not in limine_conf.read_text():
        raise RuntimeError(f"encrypted install but {limine_conf} has no cryptdevice=")

    if not arch.has_uefi():
        _write_bios_grub_config(esp_root, cmdline)


def _write_bios_grub_config(esp_root: Path, cmdline: str) -> None:
    """On BIOS installs, also leave a grub.cfg on the ESP.

    Firmware that boots through a GRUB payload scans disks for a config
    (grub.cfg / syslinux / extlinux) and never chainloads the MBR. Omarchy
    installs Limine, whose limine.conf such firmware does not read, so the
    installed system does not start. A minimal grub.cfg booting the same kernel
    lets that firmware hand off to the system. Harmless elsewhere: ordinary
    BIOS boots the MBR Limine and never reads this file.
    """
    text = (esp_root / "limine.conf").read_text()
    kernel = _limine_entry_boot_path(text, "path")
    initramfs = _limine_entry_boot_path(text, "module_path")
    if not kernel or not initramfs:
        return

    ucode = next(
        (name for name in ("intel-ucode.img", "amd-ucode.img") if (esp_root / name).exists()),
        None,
    )
    initrd = " ".join(f"/{path}" for path in (ucode, initramfs) if path)

    grub_dir = esp_root / "grub"
    grub_dir.mkdir(parents=True, exist_ok=True)
    (grub_dir / "grub.cfg").write_text(
        "set timeout=3\n"
        'menuentry "Omarchy" {\n'
        f"  linux /{kernel} {cmdline}\n"
        f"  initrd {initrd}\n"
        "}\n"
    )
    info(f"› wrote {grub_dir / 'grub.cfg'} for GRUB-payload firmware")


def _limine_entry_boot_path(text: str, key: str) -> str | None:
    """Pull a `boot():` path out of a generated limine.conf entry.

    limine-entry-tool writes lines like
    `path: boot():/<machine-id>/linux-omarchy/vmlinuz#<hash>`; strip the
    boot(): prefix and any content hash so the result is an ESP-relative path.
    """
    pattern = re.compile(rf"^\s*{re.escape(key)}:\s*boot\(\):(\S+)", re.MULTILINE)
    match = pattern.search(text)
    return match.group(1).split("#", 1)[0].lstrip("/") if match else None


def _strip_shell_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
        return value[1:-1]
    return value


def _limine_combined_config_text(ctx: InstallContext, default_text: str) -> str:
    chunks: list[str] = []
    for path in sorted((ctx.target / "usr" / "share" / "limine-entry-tool.d").glob("*.conf")):
        chunks.append(path.read_text())

    legacy_conf = ctx.target / "etc" / "limine-entry-tool.conf"
    if legacy_conf.exists():
        chunks.append(legacy_conf.read_text())

    for path in sorted((ctx.target / "etc" / "limine-entry-tool.d").glob("*.conf")):
        chunks.append(path.read_text())

    # /etc/default/limine has highest priority in limine-entry-tool.
    chunks.append(default_text)
    return "\n".join(chunks)


def _limine_setting(config_text: str, name: str, fallback: str | None = None) -> str | None:
    pattern = re.compile(rf"^\s*{re.escape(name)}\s*=\s*(.*?)\s*$")
    value = fallback
    for line in config_text.splitlines():
        match = pattern.match(line)
        if match:
            # The file is sourced by Bash: read the value as it would, quotes
            # removed and a trailing "# comment" dropped.
            try:
                words = shlex.split(match.group(1), comments=True)
            except ValueError:
                words = [_strip_shell_quotes(match.group(1))]
            value = words[0] if words else ""
    return value


# limine-mkinitcpio names a UKI <prefix>_<kernel>.efi, the prefix being
# CUSTOM_UKI_NAME when it is lowercase letters and digits, and the machine id
# otherwise (resolve_uki_prefix in limine-mkinitcpio-install). Omarchy sets it
# to omarchy. The pre-built UKI is copied under the same name, and
# validate_boot looks for it there; _finish_root_image gave the target its id.
def _uki_prefix(target: Path, config_text: str) -> str:
    name = _limine_setting(config_text, "CUSTOM_UKI_NAME") or ""
    if re.fullmatch(r"[a-z0-9]+", name):
        return name
    return (target / "etc" / "machine-id").read_text().strip()


def _limine_kernel_cmdline(config_text: str) -> str:
    parts: list[str] = []
    pattern = re.compile(r'^\s*KERNEL_CMDLINE\[default\]\+=\s*(.*?)\s*$')
    for line in config_text.splitlines():
        match = pattern.match(line)
        if match:
            parts.append(_strip_shell_quotes(match.group(1)).strip())
    return " ".join(part for part in parts if part).strip()


def run_chroot_finalizer(ctx: InstallContext, *, private_mounts: bool = False) -> None:
    if ctx.defer_provisioning:
        info("› deferred-provisioning install: user finalization deferred to first boot")
        return

    _run_target_setup_command(
        ctx,
        ["/usr/bin/omarchy-provision-user", "--force", "--first-install"],
        user=ctx.username,
        private_mounts=private_mounts,
    )


def finalize_boot_and_user(ctx: InstallContext) -> None:
    """finalize_limine_boot and run_chroot_finalizer at the same time. The
    first writes the ESP and the boot entry (limine-install, the pre-built
    UKI copy, limine-entry-tool); the second runs as the user in the home
    directory (theme, mise, xdg defaults) and only reads the system. Measured
    on their own: 0.8 s and 1.9 s; together they take the longer of the two.
    The user finalizer's chroot runs in a private mount namespace so the two
    arch-chroots do not tear down each other's /proc, /sys and /dev."""
    if ctx.defer_provisioning or os.environ.get("OMARCHY_SERIAL_FINALIZE") == "1":
        finalize_limine_boot(ctx)
        run_chroot_finalizer(ctx)
        return

    from concurrent.futures import ThreadPoolExecutor

    with ThreadPoolExecutor(max_workers=2) as pool:
        boot = pool.submit(finalize_limine_boot, ctx)
        user = pool.submit(run_chroot_finalizer, ctx, private_mounts=True)
        errors: list[BaseException] = []
        for future in (boot, user):
            try:
                future.result()
            except BaseException as exc:  # noqa: BLE001 - re-raised below
                errors.append(exc)
    if errors:
        raise errors[0]


def configure_dns_resolver(ctx: InstallContext) -> None:
    """Put the installed system in systemd-resolved stub mode.

    Arch's systemd-resolved docs explicitly say not to create this symlink from
    inside arch-chroot because /etc/resolv.conf may be a bind mount from the
    live environment. Do it from the ISO against /mnt instead.
    """
    resolv_conf = ctx.target / "etc" / "resolv.conf"
    target = "../run/systemd/resolve/stub-resolv.conf"

    if resolv_conf.is_symlink() and os.readlink(resolv_conf) == target:
        return

    info("› configuring /etc/resolv.conf for systemd-resolved")
    resolv_conf.parent.mkdir(parents=True, exist_ok=True)
    resolv_conf.unlink(missing_ok=True)
    resolv_conf.symlink_to(target)


def _read_omarchy_mirror() -> str:
    p = Path("/root/omarchy_mirror")
    return p.read_text().strip() if p.exists() else "stable"


# ─────────────────────────────────────────────────────────────────────────────
# configure_login: seed SDDM's last user/session for the password-only Omarchy
# greeter. Encrypted installs autologin because the LUKS prompt is the auth
# boundary; unencrypted installs leave SDDM as the auth screen.
# ─────────────────────────────────────────────────────────────────────────────

def configure_login(ctx: InstallContext) -> None:
    sddm_dir = ctx.target / "etc" / "sddm.conf.d"
    sddm_dir.mkdir(parents=True, exist_ok=True)
    (sddm_dir / "99-omarchy-login.conf").write_text(
        "[Theme]\nCurrent=omarchy\n\n"
        "[Users]\nRememberLastUser=true\nRememberLastSession=true\n"
    )

    autologin_conf = sddm_dir / "autologin.conf"
    if ctx.encrypt and not ctx.defer_provisioning:
        autologin_conf.write_text(
            "[Autologin]\n"
            f"User={ctx.username}\n"
            "Session=omarchy.desktop\n"
        )
    else:
        # deferred-provisioning installs have no user yet; omarchy-provision-owner writes autologin
        # and SDDM state at first boot once the owner exists.
        autologin_conf.unlink(missing_ok=True)

    if not ctx.defer_provisioning:
        state_dir = ctx.target / "var" / "lib" / "sddm"
        state_dir.mkdir(parents=True, exist_ok=True)
        (state_dir / "state.conf").write_text(
            f"[Last]\nSession=omarchy.desktop\nUser={ctx.username}\n"
        )
        subprocess.run(
            ["arch-chroot", str(ctx.target), "chown", "sddm:sddm",
             "/var/lib/sddm", "/var/lib/sddm/state.conf"],
            check=False, capture_output=True,
        )

    autologin = ctx.target / "etc" / "systemd" / "system" / "getty@tty1.service.d" / "autologin.conf"
    autologin.unlink(missing_ok=True)

    subprocess.run(
        ["arch-chroot", str(ctx.target), "systemctl", "enable", "sddm.service"],
        check=False, capture_output=True,
    )


# ─────────────────────────────────────────────────────────────────────────────
# configure_ssh_access: make the installed machine reachable over SSH with the
# keys an autoinstall drive supplied. A stock Omarchy install ships openssh but
# leaves sshd disabled, and its firewall.sh opens only LocalSend and docker DNS,
# so all three pieces -- keys, service, firewall -- have to be done here.
# ─────────────────────────────────────────────────────────────────────────────

def configure_ssh_access(ctx: InstallContext) -> None:
    if ctx.authorized_keys_path is None:
        return

    keys = _authorized_keys(ctx.authorized_keys_path)

    if ctx.defer_provisioning:
        # No user to authorize yet. Stage the keys in provisioning state for
        # omarchy-provision-owner to install once first boot creates the owner, and
        # still open the door (sshd + ufw) below.
        info(f"› staging {len(keys)} SSH key(s) for the first-boot user")
        provisioning_dir = ctx.target / PROVISION_STATE_DIR
        provisioning_dir.mkdir(parents=True, exist_ok=True)
        staged = provisioning_dir / "authorized_keys"
        staged.write_text("".join(f"{key}\n" for key in keys))
        staged.chmod(0o600)
    else:
        info(f"› installing {len(keys)} SSH key(s) for {ctx.username}")

        ssh_dir = ctx.target / "home" / ctx.username / ".ssh"
        ssh_dir.mkdir(parents=True, exist_ok=True)
        ssh_dir.chmod(0o700)

        authorized_keys = ssh_dir / "authorized_keys"
        authorized_keys.write_text("".join(f"{key}\n" for key in keys))
        authorized_keys.chmod(0o600)

        # Ask the target for the uid rather than assuming the first user is 1000.
        # Uncaptured so a failure shows up in the install log, and checked because
        # a root-owned authorized_keys is one sshd refuses to read.
        subprocess.run(
            ["arch-chroot", str(ctx.target), "chown", "-R",
             f"{ctx.username}:{ctx.username}", f"/home/{ctx.username}/.ssh"],
            check=True,
        )

    info("› enabling sshd")
    subprocess.run(
        ["arch-chroot", str(ctx.target), "systemctl", "enable", "sshd.service"],
        check=True,
    )

    # Open port 22 in the target's ufw, which runs default-deny incoming, so an
    # enabled sshd is still unreachable -- connections time out rather than
    # being refused.
    #
    # ufw cannot reach netfilter from inside the chroot and exits non-zero
    # saying so, but it writes the rule to user.rules first, and that file is
    # what ufw.service loads on first boot. So the exit status is the wrong
    # thing to check here; the rule landing in the file is the thing that
    # matters.
    info("› allowing SSH through ufw")
    subprocess.run(["arch-chroot", str(ctx.target), "ufw", "allow", "ssh"], check=False)

    rules = ctx.target / "etc" / "ufw" / "user.rules"
    text = rules.read_text() if rules.exists() else ""
    if "--dport 22 -j ACCEPT" not in text:
        raise RuntimeError(f"ufw did not record an allow rule for port 22 in {rules}")


# DEV ONLY (N1x bring-up): only the N1x development ISO carries this script
# (builder/n1x-dev-ssh), and build_phases lists this phase only when it is
# there. It authorizes the development key for root on the installed system.
DEV_SSH_SCRIPT = Path("/usr/local/sbin/omarchy-n1x-dev-ssh")


def configure_dev_ssh(ctx: InstallContext) -> None:
    info("› DEV ONLY: authorizing the N1x development SSH key for root")
    subprocess.run([str(DEV_SSH_SCRIPT), "--target", str(ctx.target)], check=True)


def _authorized_keys(path: Path) -> list[str]:
    """Read the autoinstall authorized_keys: sshd's own format, one public key
    per line, with blank lines and # comments dropped.

    Raise rather than skip on anything unusable. An install that "succeeds"
    into a machine nobody can log into is worse than one that stops with the
    reason on screen.
    """
    try:
        lines = path.read_text().splitlines()
    except OSError as exc:
        raise RuntimeError(f"{path} is not readable: {exc}") from exc

    keys = [line.strip() for line in lines]
    keys = [key for key in keys if key and not key.startswith("#")]
    if not keys:
        raise RuntimeError(f"{path} contains no SSH keys")

    return keys


# ─────────────────────────────────────────────────────────────────────────────
# configure_tailscale: stage the tailnet join an autoinstall drive asked for.
# `tailscale up` needs a running tailscaled and there is no systemd in the
# chroot, so the install only stages: the key, the enabled services, and a
# oneshot first-boot unit that performs the join once the network is really
# there. The package itself was installed from the offline mirror during
# arch_install_system -- nothing is fetched at boot.
# ─────────────────────────────────────────────────────────────────────────────

TAILSCALE_AUTHKEY_TARGET = "/etc/tailscale/authkey"

# systemd expands $VAR in ExecStart, so the retry loop avoids `$` entirely.
# network-online.target can be reached before there is real connectivity, so
# retry inside the boot -- but NOT as a oneshot: target units implicitly gain
# After= for their Wants=, so a oneshot in multi-user.target holds the whole
# boot (SDDM included) hostage until it finishes. Type=simple counts as
# started the moment it forks, letting boot proceed while the join retries in
# the background for as long as the boot lasts. Cleanup lives inside the
# script because it must only run after a successful join: the key is removed
# and the unit disabled on success, while on a boot with no connectivity both
# survive -- so a machine installed offline joins on the first boot that can.
TAILSCALE_JOIN_UNIT = f"""\
[Unit]
Description=Join the tailnet with the auth key staged by autoinstall
Wants=network-online.target
After=network-online.target tailscaled.service
Requires=tailscaled.service
ConditionPathExists={TAILSCALE_AUTHKEY_TARGET}

[Service]
Type=simple
ExecStart=/usr/bin/sh -c 'until tailscale up --auth-key file:{TAILSCALE_AUTHKEY_TARGET}; do sleep 15; done; rm -f {TAILSCALE_AUTHKEY_TARGET}; systemctl disable omarchy-tailscale-join.service'

[Install]
WantedBy=multi-user.target
"""


def configure_tailscale(ctx: InstallContext) -> None:
    if ctx.tailscale_authkey_path is None:
        return

    key = _tailscale_authkey(ctx.tailscale_authkey_path)

    # An ISO built before tailscale was bundled installs nothing, and a staged
    # key with no binary would fail silently forever on first boot.
    if not (ctx.target / "usr" / "bin" / "tailscale").exists():
        raise RuntimeError("tailscale is not installed on the target; this ISO does not bundle it")

    info("› staging Tailscale auth key")
    ts_dir = ctx.target / "etc" / "tailscale"
    ts_dir.mkdir(parents=True, exist_ok=True)
    ts_dir.chmod(0o700)
    authkey = ts_dir / "authkey"
    authkey.write_text(f"{key}\n")
    authkey.chmod(0o600)

    info("› enabling tailscaled and the first-boot join")
    unit = ctx.target / "etc" / "systemd" / "system" / "omarchy-tailscale-join.service"
    unit.parent.mkdir(parents=True, exist_ok=True)
    unit.write_text(TAILSCALE_JOIN_UNIT)
    subprocess.run(
        ["arch-chroot", str(ctx.target), "systemctl", "enable",
         "tailscaled.service", "omarchy-tailscale-join.service"],
        check=True,
    )

    # Same dance as configure_ssh_access: ufw cannot reach netfilter from the
    # chroot and exits non-zero, but it records the rule in user.rules first,
    # and that file is what ufw.service loads on first boot. Without the rule
    # the node joins the tailnet and is then unreachable over it.
    info("› allowing tailnet traffic through ufw")
    subprocess.run(
        ["arch-chroot", str(ctx.target), "ufw", "allow", "in", "on", "tailscale0"],
        check=False,
    )

    rules = ctx.target / "etc" / "ufw" / "user.rules"
    text = rules.read_text() if rules.exists() else ""
    if "-i tailscale0 -j ACCEPT" not in text:
        raise RuntimeError(f"ufw did not record an allow rule for tailscale0 in {rules}")


def _tailscale_authkey(path: Path) -> str:
    """Read the autoinstall tailscale_authkey: exactly one key, with blank
    lines and # comments dropped. No format validation beyond that -- key
    formats are Tailscale's to change.

    Raise rather than skip on anything unusable, same reasoning as
    _authorized_keys: a machine that "succeeds" into never joining the
    tailnet is worse than one that stops with the reason on screen.
    """
    try:
        lines = path.read_text().splitlines()
    except OSError as exc:
        raise RuntimeError(f"{path} is not readable: {exc}") from exc

    keys = [line.strip() for line in lines]
    keys = [key for key in keys if key and not key.startswith("#")]
    if not keys:
        raise RuntimeError(f"{path} contains no auth key")
    if len(keys) > 1:
        raise RuntimeError(f"{path} contains {len(keys)} keys; expected exactly one")

    return keys[0]


# ─────────────────────────────────────────────────────────────────────────────
# validate_boot: hard checks before reboot. If the install ran but produced a
# boot config or UKI that can't actually boot, halt here rather than surprise
# the user.
# ─────────────────────────────────────────────────────────────────────────────

def validate_boot(ctx: InstallContext) -> None:
    _assert_boot_hooks_restored(ctx)
    _validate_kernel_headers(ctx)

    boot = _boot_intent(ctx)
    storage = _storage_intent(ctx)
    esp_mount = ctx.target / boot["esp_mount"].lstrip("/")

    limine_conf = esp_mount / "limine.conf"
    if not limine_conf.exists():
        raise RuntimeError(f"{limine_conf} missing")
    limine_conf_text = limine_conf.read_text()
    if "Omarchy" not in limine_conf_text:
        raise RuntimeError(f"{limine_conf} has no Omarchy entry")

    _validate_platform_boot_entries(limine_conf_text, _installed_arm_platform(ctx), iso_kernel())

    kernel_cmdline = ctx.target / "etc" / "kernel" / "cmdline"
    if not kernel_cmdline.exists():
        raise RuntimeError(f"{kernel_cmdline} missing — UKI would have no cmdline")

    # cryptdevice= has to reach the next limine-mkinitcpio rebuild: through
    # the entry in limine.conf, or through /etc/kernel/cmdline.
    if ctx.encrypt and "cryptdevice=" not in limine_conf_text and "cryptdevice=" not in kernel_cmdline.read_text():
        raise RuntimeError(f"Encrypted install but neither {limine_conf} nor {kernel_cmdline} has cryptdevice=")

    default_limine = ctx.target / "etc" / "default" / "limine"
    config_text = _limine_combined_config_text(ctx, default_limine.read_text())
    uki_prefix = _uki_prefix(ctx.target, config_text)
    kernel = storage.get("kernel") or (ctx.user_configuration.get("kernels") or ["linux-omarchy"])[0]

    if arch.has_uefi():
        limine_binary = esp_mount / boot.get("esp_path", "/EFI/limine").lstrip("/") / boot.get("efi_binary", _default_limine_efi_binary())
        if not limine_binary.exists() or limine_binary.stat().st_size == 0:
            raise RuntimeError(f"{limine_binary} missing or empty")

        if _limine_setting(config_text, "ENABLE_UKI", "yes") == "no":
            _validate_linux_boot_entry(esp_mount, limine_conf_text, ctx.encrypt)
        else:
            # Hardware packages (omarchy-hw-intel-ptl, …) can swap the configured
            # kernel out mid-install, so trust what's on disk over what we asked
            # for. But while the configured kernel is installed, require its own
            # UKI: the image always carries the prebuilt stock UKI, which must not
            # hide a failed linux-t2 build (the rule of omacom/omarchy-iso#145).
            uki_dir = esp_mount / "EFI" / "Linux"
            installed_kernels = _installed_kernels(ctx)
            candidates = [kernel] if kernel in installed_kernels else installed_kernels or [kernel]
            ukis = [uki_dir / f"{uki_prefix}_{name}.efi" for name in candidates]
            if not any(uki.exists() and uki.stat().st_size for uki in ukis):
                raise RuntimeError(f"{' / '.join(str(uki) for uki in ukis)} missing or empty")

        # A full-disk install formatted this ESP, so whatever is on its
        # removable path is this install's. A protected target's ESP may be
        # another OS's too, and its removable loader that OS's, unless this
        # install claimed the path (enable_fallback, see _boot_intent).
        _validate_uefi_boot_routes(
            esp_mount,
            loader=_limine_efi_loader(
                boot.get("esp_path", "/EFI/limine"), boot.get("efi_binary", _default_limine_efi_binary())
            ),
            fallback_is_ours=not ctx.is_protected or bool(boot.get("enable_fallback")),
        )

    if ctx.is_protected:
        _validate_pre_mounted_filesystems(ctx)

    if ctx.defer_provisioning:
        _validate_provisioning_state(ctx)

    _validate_package_signing(ctx)


OFFLINE_MIRROR = Path("/var/cache/omarchy/mirror/offline")


def _validate_package_signing(ctx: InstallContext, mirror: Path = OFFLINE_MIRROR) -> None:
    """The installed keyring must trust the packages its repositories ship.

    The install itself never checks a signature (SigLevel = Never), so a target
    keyring missing a distribution key only shows up at the first online pacman
    run. On aarch64 every Arch Linux ARM package carries its build key's
    signature, and the offline mirror keeps them. Verify one against the target
    keyring and require the full or ultimate validity pacman requires."""
    if platform.machine() != "aarch64":
        return

    # The keyring is populated by a unit that runs on through the install;
    # read it finished. create_factory_snapshot's join is then a no-op.
    _join_target_keyring_init(ctx)

    signatures = sorted(mirror.glob("archlinuxarm-keyring-*.pkg.tar.*.sig"))
    if not signatures:
        raise RuntimeError(f"no archlinuxarm-keyring signature in {mirror} to check the target keyring against")
    signature = signatures[-1]
    package = signature.with_suffix("")

    gnupg = ctx.target / "etc/pacman.d/gnupg"
    try:
        result = subprocess.run(
            ["gpg", "--homedir", str(gnupg), "--batch", "--no-permission-warning",
             "--status-fd", "1", "--verify", str(signature), str(package)],
            capture_output=True, text=True,
        )
    finally:
        # Nothing should be left holding the target mount when it is unmounted.
        subprocess.run(["gpgconf", "--homedir", str(gnupg), "--kill", "all"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    statuses = [line.split()[1] for line in result.stdout.splitlines() if line.startswith("[GNUPG:] ")]
    if result.returncode != 0 or "VALIDSIG" not in statuses or not {"TRUST_FULLY", "TRUST_ULTIMATE"} & set(statuses):
        raise RuntimeError(
            f"the installed pacman keyring does not trust the Arch Linux ARM signature on {package.name}; "
            "every online package install would fail with 'unknown trust'"
        )


# The N1x firmware publishes an ACPI SPCR serial console the kernel adopts
# unless told otherwise, and Limine hands each entry's cmdline to the UKI as
# load options that replace the embedded one. So the contract has to hold in
# the generated limine.conf itself: every entry keeps the console on the panel,
# and the rescue entry boots to a text login. Both failures look like a black
# screen, which is how the first N1x installs went.
N1X_REQUIRED_CMDLINE = ("console=tty0", "acpi=nospcr")


def _limine_entries(limine_conf_text: str) -> list[tuple[str, dict[str, str]]]:
    entries: list[tuple[str, dict[str, str]]] = []
    for line in limine_conf_text.splitlines():
        stripped = line.strip()
        if stripped.startswith("/"):
            entries.append((stripped, {}))
        elif entries and ":" in stripped:
            key, value = stripped.split(":", 1)
            entries[-1][1][key.strip().lower()] = value.strip()
    return entries


def _base_package_file(share: Path = Path("/usr/share/omarchy-iso")) -> Path:
    """The default set for the platform this machine is, where the image
    carries one; the plain list for every other machine."""
    detected = hw_platform()
    platform_list = share / f"omarchy-base.{detected}.packages"
    if detected and platform_list.is_file():
        return platform_list
    return share / "omarchy-base.packages"


def _platform_delta_packages(target: Path, share: Path = Path("/usr/share/omarchy-iso")) -> list[str]:
    """What this machine's platform default set adds to the image, which is
    built from the plain set: nothing on a machine without one."""
    base_pkgs_file = _base_package_file(share)
    if base_pkgs_file.name == "omarchy-base.packages":
        return []
    pkgs: list[str] = []
    for raw in base_pkgs_file.read_text().splitlines():
        s = raw.strip()
        if not s or s.startswith("#") or s in pkgs:
            continue
        if not arch.target_has_package(target, s):
            pkgs.append(s)
    return pkgs


def _arm_platform_boot() -> bool:
    """Whether this is an aarch64 board with a platform of its own, whose
    boot entries its hardware scripts set up (hw_platform says "aarch64" on a
    generic one)."""
    return platform.machine() == "aarch64" and hw_platform() not in ("", "aarch64")


def _installed_arm_platform(ctx: InstallContext) -> str:
    """"n1x" when the machine being installed is one, as the target's own
    detector says.

    The platform's boot contract comes from its hardware script, which only runs
    on that hardware; any other machine gets its own setup and is validated as
    such."""
    if platform.machine() != "aarch64":
        return ""
    detected = subprocess.run(
        ["arch-chroot", str(ctx.target), "omarchy-hw-n1x"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return "n1x" if detected.returncode == 0 else ""


def _validate_platform_boot_entries(limine_conf_text: str, arm_platform: str, kernel: str = "") -> None:
    if arm_platform != "n1x":
        return

    # Kernel entries only: the EFI fallback entry chainloads a loader and has
    # no cmdline of its own.
    kernels = [
        (name, options) for name, options in _limine_entries(limine_conf_text)
        if "cmdline" in options or "/EFI/Linux/" in options.get("path", "")
    ]
    if not kernels:
        raise RuntimeError("limine.conf has no kernel entries")

    for name, options in kernels:
        cmdline = options.get("cmdline", "").split()
        missing = [param for param in N1X_REQUIRED_CMDLINE if param not in cmdline]
        if missing:
            raise RuntimeError(
                f"limine.conf entry {name} lacks {' '.join(missing)}; its console would go to the SPCR serial port"
            )

    # The rescue entry is the kernel's fallback UKI, booted with its own cmdline.
    rescue_name = f"{kernel}-fallback"
    rescue = [options for _, options in kernels if f"_{rescue_name}.efi" in options.get("path", "")]
    if not rescue:
        raise RuntimeError(f"limine.conf has no {rescue_name} rescue entry")
    for options in rescue:
        cmdline = options.get("cmdline", "").split()
        if "systemd.unit=multi-user.target" not in cmdline or "plymouth.enable=0" not in cmdline:
            raise RuntimeError(f"{rescue_name} entry does not boot to a text login; its own cmdline was overridden")


def _validate_linux_boot_entry(esp_mount: Path, config_text: str, encrypted: bool) -> None:
    """Check the kernel and initramfs that limine-entry-tool copied to the ESP."""
    # limine-entry-tool writes an indented //<kernel> entry per kernel under
    # /+Omarchy; deeper entries belong to snapshots.
    entries: list[list[str]] = []
    in_omarchy = False
    current: list[str] | None = None
    for line in config_text.splitlines():
        header = re.match(r"\s*(/+)\+?(.*)$", line)
        if header:
            depth = len(header.group(1))
            if depth == 1:
                in_omarchy = header.group(2).startswith("Omarchy")
            current = [] if in_omarchy and depth == 2 else None
            if current is not None:
                entries.append(current)
        elif current is not None:
            current.append(line)

    for entry in map("\n".join, entries):
        if not re.search(r"(?m)^\s*protocol:\s*linux\s*$", entry):
            continue
        cmdline = re.search(r"(?m)^\s*cmdline:\s*(.*)$", entry)
        if not cmdline or not re.search(r"(?:^|\s)root=\S+", cmdline.group(1)):
            continue
        if encrypted and not re.search(r"(?:^|\s)cryptdevice=\S+", cmdline.group(1)):
            continue
        kernel = re.findall(r"(?m)^\s*path:\s*(\S+)\s*$", entry)
        modules = re.findall(r"(?m)^\s*module_path:\s*(\S+)\s*$", entry)
        if not kernel or not modules:
            continue
        # limine-entry-tool writes boot():/<path>#<hash>; resources elsewhere
        # don't resolve on the ESP and so fail the check.
        files = [esp_mount / r.removeprefix("boot():").split("#", 1)[0].lstrip("/") for r in kernel + modules]
        if all(path.is_file() and path.stat().st_size for path in files):
            return
    raise RuntimeError(f"{esp_mount / 'limine.conf'} has no bootable Omarchy Linux entry with a kernel and initramfs")


def _validate_uefi_boot_routes(esp_mount: Path, *, loader: str, fallback_is_ours: bool) -> None:
    """Check the two ways firmware can reach this install, and insist on one.

    The named "Limine" boot variable is the route we prefer and the one
    _register_limine_efi_entry created and read back. The removable path
    EFI/BOOT/BOOTX64.EFI (BOOTAA64.EFI on aarch64) is the one every UEFI
    implementation tries when nothing in NVRAM matches, and limine-install
    deploys it from ENABLE_LIMINE_FALLBACK during finalize_limine_boot.

    Either alone boots the machine, so neither is fatal by itself. Losing
    both is: that install reboots into whatever else is on the disk with no
    way back. Firmware that takes the variable at registration and discards
    it before the install ends is the case worth naming, because nothing
    else in the install notices.

    The removable path counts only when `fallback_is_ours`: on an ESP this
    install shares and did not claim the path on, the file there is another
    OS's loader and starts that OS. The entry counts only when firmware will
    use it (active) and it starts `loader` on this ESP: a switched-off entry,
    or one for a backup loader on the same ESP, starts nothing of this one.
    """
    fallback_binary = esp_mount / "EFI" / "BOOT" / f"BOOT{_efi_arch_suffix()}.EFI"
    fallback_present = fallback_binary.exists() and fallback_binary.stat().st_size > 0
    has_fallback = fallback_is_ours and fallback_present
    # Next to another Omarchy, its "Limine" entry says nothing about whether
    # ours survived. If the ESP's GUID cannot be read, an active "Limine"
    # entry that names this loader, or names no path at all, has to do.
    esp = _mounted_partition_guid(esp_mount)
    state = _read_efibootmgr()
    entries = state["entries"]

    def starts_this_install(num: str) -> bool:
        if num in state.get("inactive", ()):
            return False
        if esp:
            return _is_limine_entry_for(entries[num], esp, loader)
        label, _, path = entries[num].lower().partition("\t")
        return label.strip() == "limine" and (not path or loader.lower() in path)

    has_entry = any(starts_this_install(num) for num in entries)

    no_entry = (
        f"the EFI variable store cannot be read ({state['unreadable']})"
        if state.get("unreadable") else "efibootmgr has no 'Limine' entry"
    )
    if not has_entry and not has_fallback:
        fallback_state = "is not written by this install" if fallback_present else "is missing or empty"
        raise RuntimeError(
            f"no bootable route to this install: {no_entry} "
            f"and {fallback_binary} {fallback_state}"
        )

    if not has_entry and state.get("unreadable"):
        error(
            f"Warning: {no_entry}, so this install has no 'Limine' UEFI boot entry. "
            f"Omarchy boots from {fallback_binary.name} on its own EFI partition, "
            "which firmware takes when nothing in NVRAM matches."
        )
        return

    if not has_entry:
        error(
            "Warning: this firmware discarded the 'Limine' UEFI boot entry during "
            f"the install. Omarchy still boots from {fallback_binary.name} on its "
            "own EFI partition. If the machine starts another OS instead, pick the "
            "Omarchy disk from the firmware boot menu (F11, F12 or Esc on most "
            "boards), then move it to the top of the firmware's own boot priority "
            "list. Some AMI/MSI boards ignore the UEFI BootOrder and honour only "
            "that list."
        )
        return

    if not has_fallback and fallback_present:
        error(
            f"Warning: {fallback_binary} belongs to another system on this shared EFI "
            "partition and was left alone, so this install depends on the 'Limine' "
            "UEFI boot entry alone. It boots now. If firmware later clears NVRAM, "
            "re-add the entry with efibootmgr from a live session."
        )
    elif not has_fallback:
        error(
            f"Warning: {fallback_binary} was not deployed, so this install depends "
            "on the 'Limine' UEFI boot entry alone. It boots now. If firmware "
            "later clears NVRAM, reinstall the loader from a live session with "
            "'limine-install --fallback'."
        )


def _validate_provisioning_state(ctx: InstallContext) -> None:
    """An deferred-provisioning install that boots without a working first-boot setup is a
    user-less brick; insist the armed state is complete before reboot."""
    provisioning_dir = ctx.target / PROVISION_STATE_DIR
    if not (provisioning_dir / "pending").exists():
        raise RuntimeError(f"deferred-provisioning install but {provisioning_dir / 'pending'} is missing")

    link = ctx.target / "etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"
    if not link.is_symlink():
        raise RuntimeError("deferred-provisioning install but omarchy-provision-owner.service is not enabled")

    if _provision_install_encrypted(ctx):
        for required in (provisioning_dir / "luks-key", ctx.target / PROVISION_KEYFILE):
            if not required.exists():
                raise RuntimeError(f"encrypted deferred-provisioning install but {required} is missing")
        limine_conf_text = (
            ctx.target / _boot_intent(ctx)["esp_mount"].lstrip("/") / "limine.conf"
        ).read_text()
        if "cryptkey=rootfs:" not in limine_conf_text:
            raise RuntimeError("encrypted deferred-provisioning install but limine.conf has no cryptkey= for auto-unlock")


def _assert_boot_hooks_restored(ctx: InstallContext) -> None:
    """Never hand over a system whose UKI rebuild hook is still masked.

    run_system_finalizer defers 90-mkinitcpio-install.hook inside the target and
    restores it in a finally, but a mask that survived would be invisible until
    the first kernel update shipped a UKI-less boot. Repair, then insist.
    """
    cleanup_target_hook_masks(ctx)

    hooks_dir = ctx.target / "etc/pacman.d/hooks"
    for name in TARGET_DEFERRED_BOOT_HOOKS:
        path = hooks_dir / name
        if _is_devnull_symlink(path):
            raise RuntimeError(f"{path} is still masked to /dev/null")
        backup = hooks_dir / f"{name}.omarchy-backup"
        if backup.exists() or backup.is_symlink():
            raise RuntimeError(f"{backup} left behind by the install-time hook mask")
        # limine-mkinitcpio-hook is a hard dependency of the Omarchy runtime
        # package, so the real hook is on disk before the mask ever goes up and
        # must be on disk again now.
        if not path.is_file():
            raise RuntimeError(f"{path} is missing — future kernel updates would ship no UKI")


# Arch's kernel packages leave their pkgbase next to their modules, which is
# also the name limine-mkinitcpio-hook builds the UKI under. Arch Linux ARM's
# linux-aarch64 leaves none, so a kernel's module directory without one is
# named by the kernel this image was built to install. modules.builtin marks
# a kernel's own directory: a leftover of out-of-tree modules has none.
def _kernel_directories(ctx: InstallContext) -> list[tuple[Path, str]]:
    found = []
    modules = ctx.target / "usr" / "lib" / "modules"
    for directory in sorted(modules.iterdir()) if modules.is_dir() else []:
        pkgbase = directory / "pkgbase"
        if pkgbase.is_file():
            name = pkgbase.read_text().strip()
        elif (directory / "modules.builtin").is_file():
            name = iso_kernel()
        else:
            continue
        if name:
            found.append((directory, name))
    return found


def _validate_kernel_headers(ctx: InstallContext) -> None:
    kernels = _kernel_directories(ctx)
    if not kernels:
        raise RuntimeError("no installed kernel found in target")
    for directory, name in kernels:
        release = directory.name
        header_release = directory / "build/include/config/kernel.release"
        if not header_release.is_file():
            raise RuntimeError(f"{name} ({release}) has no kernel headers")
        if header_release.read_text().strip() != release:
            raise RuntimeError(f"{name} headers do not match kernel {release}")


def _installed_kernels(ctx: InstallContext) -> list[str]:
    names = []
    for _, name in _kernel_directories(ctx):
        if name not in names:
            names.append(name)
    return names


def _validate_pre_mounted_filesystems(ctx: InstallContext) -> None:
    storage = _storage_intent(ctx)
    fstab = ctx.target / "etc" / "fstab"
    if not fstab.exists():
        raise RuntimeError(f"{fstab} missing")
    fstab_text = fstab.read_text()
    btrfs_uuid = _blkid_uuid(_btrfs_root_device(ctx))
    esp_uuid = _blkid_uuid(_esp_device(ctx))
    if btrfs_uuid not in fstab_text:
        raise RuntimeError(f"{fstab} missing btrfs UUID {btrfs_uuid}")
    if esp_uuid not in fstab_text:
        raise RuntimeError(f"{fstab} missing ESP UUID {esp_uuid}")

    if storage.get("luks_uuid"):
        crypttab = ctx.target / "etc" / "crypttab.initramfs"
        if not crypttab.exists():
            raise RuntimeError(f"{crypttab} missing")
        if storage["luks_uuid"] not in crypttab.read_text():
            raise RuntimeError(f"{crypttab} missing LUKS UUID {storage['luks_uuid']}")


# ─────────────────────────────────────────────────────────────────────────────
# create_factory_snapshot: read-only snapshot of @ kept at the btrfs top level
# as @factory — outside snapper's .snapshots, so cleanup timers and the Limine
# snapshot menu never touch it. Zero bytes at creation; grows only with drift.
# Taken at the end of every install, it is what makes omarchy-system-factory-reset a
# true factory reset.
# ─────────────────────────────────────────────────────────────────────────────

def _mark_updates_applied(ctx: InstallContext) -> None:
    """Disarm ConditionNeedsUpdate= for the first boot.

    Arch's 35-systemd-update pacman hook touches /usr after every
    transaction, which arms ldconfig.service, systemd-hwdb-update,
    systemd-journal-catalog-update and systemd-sysusers for the next boot.
    pacman has already done all four at transaction time (it runs ldconfig
    itself, and the 20-/25-systemd-* hooks run sysusers, hwdb and the
    catalog), so on the first boot they only repeat the work: on a
    hardware install "Rebuild Dynamic Linker Cache" alone was 1.32 s of a
    4.54 s userspace. systemd-update-done records /usr's timestamp in
    /etc/.updated and /var/.updated, which is exactly what those units'
    condition compares against. It has to run after the last transaction
    (the per-machine packages re-arm it) and before the factory snapshot,
    so a factory reset boots as fast as the install did."""
    done = ctx.target / "usr" / "lib" / "systemd" / "systemd-update-done"
    if not done.is_file():
        return
    with _time_step("FINAL.systemd-update-done (disarm first-boot update units)"):
        result = subprocess.run(
            ["arch-chroot", str(ctx.target), "/usr/lib/systemd/systemd-update-done"],
            check=False, capture_output=True, text=True,
        )
    if result.returncode != 0:
        # Cosmetic for the install: the first boot just runs the units.
        info(f"› systemd-update-done failed ({result.returncode}); first boot will run the update units")


def create_factory_snapshot(ctx: InstallContext) -> None:
    # The keyring unit writes into @; the snapshot must not catch it midway.
    _join_target_keyring_init(ctx)
    _mark_updates_applied(ctx)

    fstype = _findmnt_value(ctx.target, "FSTYPE")
    if fstype != "btrfs":
        info(f"› target root is {fstype or 'unknown'}, not btrfs; skipping factory snapshot")
        return

    options = (_findmnt_value(ctx.target, "OPTIONS") or "").split(",")
    if not any(opt in ("subvol=/@", "subvol=@") for opt in options):
        info("› target root is not the @ subvolume; skipping factory snapshot")
        return

    device = require_text(
        (_findmnt_value(ctx.target, "SOURCE") or "").split("[")[0],
        f"the btrfs device backing {ctx.target}",
    )
    if not device:
        raise RuntimeError(f"could not determine the btrfs device backing {ctx.target}")

    top = ctx.state_dir / "factory-top"
    top.mkdir(parents=True, exist_ok=True)
    subprocess.run(["mount", "-o", "subvolid=5", device, str(top)], check=True)
    try:
        root_subvol = top / "@"
        if not root_subvol.is_dir():
            raise RuntimeError(f"no @ subvolume at the top level of {device}")

        factory = top / "@factory"
        if factory.exists():
            subprocess.run(
                ["btrfs", "subvolume", "delete", str(factory)],
                check=True, capture_output=True,
            )

        info("› snapshotting @ as @factory (read-only)")
        subprocess.run(
            ["btrfs", "subvolume", "snapshot", str(root_subvol), str(factory)],
            check=True,
        )
        _scrub_factory_snapshot(factory)
        subprocess.run(
            ["btrfs", "property", "set", "-ts", str(factory), "ro", "true"],
            check=True,
        )
    finally:
        subprocess.run(["umount", str(top)], check=False, capture_output=True)


# Provisioning credentials staged for THIS deployment's first boot must not
# survive into the factory image: a reset years later would otherwise hand the
# next owner the original deployment's SSH keys or rejoin its tailnet, and a
# stale LUKS key (dead after the first re-key) has no business lingering.
# The mkinitcpio/cmdline drop-ins go with the keyfile — a reset rebuild would
# otherwise fail on FILES pointing at a scrubbed path.
FACTORY_SCRUB_PATHS = (
    "var/lib/omarchy/provisioning/authorized_keys",
    "var/lib/omarchy/provisioning/luks-key",
    "etc/omarchy/provisioning.key",
    "etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf",
    "etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf",
    "etc/tailscale/authkey",
    "etc/systemd/system/omarchy-tailscale-join.service",
    "etc/systemd/system/multi-user.target.wants/omarchy-tailscale-join.service",
)


def _scrub_factory_snapshot(factory: Path) -> None:
    for rel in FACTORY_SCRUB_PATHS:
        (factory / rel).unlink(missing_ok=True)


def _findmnt_value(path: Path, column: str) -> str | None:
    res = capture(["findmnt", "-no", column, str(path)])
    value = res.stdout.strip()
    return value if res.returncode == 0 and value else None


CPU_SYSFS = Path("/sys/devices/system/cpu")


def boost_cpu_governor() -> dict[Path, str]:
    """Run the live CPUs flat out for the install.

    Package extraction and the UKI build are both CPU-bound, and archiso boots
    on whatever governor the kernel defaults to. Writing an unsupported
    governor just fails, so nothing needs probing first, and hosts without
    cpufreq (most VMs) have no paths at all. Returns the prior governors.
    """
    saved: dict[Path, str] = {}
    for path in sorted(CPU_SYSFS.glob("cpu*/cpufreq/scaling_governor")):
        try:
            saved[path] = path.read_text().strip()
            path.write_text("performance\n")
        except OSError:
            saved.pop(path, None)

    if saved:
        info(f"› CPU governor set to performance ({len(saved)} CPUs)")
    return saved


def restore_cpu_governors(saved: dict[Path, str]) -> None:
    """Only matters when an install fails and the user keeps using the live
    environment — a successful one reboots out of it."""
    for path, governor in saved.items():
        try:
            path.write_text(f"{governor}\n")
        except OSError:
            continue


# ─────────────────────────────────────────────────────────────────────────────
# cleanup_bind_mounts: invoked from main()'s finally so bind mounts get
# unwound on success, failure, or interrupt. Idempotent.
# ─────────────────────────────────────────────────────────────────────────────

def cleanup_bind_mounts(ctx: InstallContext) -> None:
    for mount_point in ctx.state.get("bind_mounts", []):
        subprocess.run(["umount", mount_point], check=False, capture_output=True)
    ctx.state["bind_mounts"] = []


def cleanup_target_hook_masks(ctx: InstallContext) -> None:
    """Restore the target's deferred boot hooks. Idempotent, and a no-op when
    nothing was masked, so main()'s finally can call it on any exit path: an
    interrupt must never leave the installed system with its UKI rebuild hook
    pointing at /dev/null."""
    _unmask_mkinitcpio_pacman_hooks(ctx, ctx.target, TARGET_DEFERRED_BOOT_HOOKS)


def cleanup_protected_state(ctx: InstallContext) -> None:
    """Tear down protected-mode mounts and LUKS mapper after a failed install.

    Idempotent and safe to call multiple times. Successful protected installs
    intentionally keep the target mounted until reboot.
    """
    if not ctx.is_protected:
        return

    # Swapoff, umount -R, and close of the mappers the mounts were backed by;
    # shared with the dashboard's pre-reboot release. omarchy_root is named
    # explicitly because a failure between luksOpen and mount leaves it open
    # with nothing in the mount table for the release to see. On failure the
    # script names the holders on stderr; surface that in the install log.
    result = subprocess.run(
        ["omarchy-release-install-target", str(ctx.target), "omarchy_root"],
        check=False,
        capture_output=True,
        text=True,
    )
    for line in (result.stderr or "").splitlines():
        info(f"release: {line}")
