"""Concrete phase implementations.

Phase ordering (full-disk and protected/pre-mounted):

    prepare_live           → disk cleanup when wiping, load configurator
                             handlers (archinstall patch happens in the
                             wrapper before Python imports it)
    prepare_install_target → everything that can fail before the disk is
                             touched: the pre-mounted target/ESP when the JSON
                             uses pre_mounted_config, the root image stream
                             and its checksum, and a disk layout the image can
                             land on
    arch_install_system    → one archinstall flow for partition/mount-or-use,
                             root filesystem restore, per-machine
                             package delta, Limine setup, useradd, fstab; the
                             per-machine pacman keyring starts as a transient
                             systemd unit after the last pacstrap
    configure_hibernation  → root-owned swap/resume drop-ins
    run_system_finalizer   → arch-chroot root omarchy-apply-system, including Snapper
    stage_provisioning_state
                           → stage deferred-provisioning state and any cryptkey
                             material needed by the final UKI build
    finalize_boot_and_user_setup
                           → final Limine/UKI build in parallel with the
                             ordered user → login → SSH → Tailscale → DNS branch
    validate_boot          → assert UKI / limine.conf / kernel cmdline are sane
    create_factory_snapshot→ joins the keyring unit, then snapshots @ as @factory
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import textwrap
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from dataclasses import replace
from pathlib import Path

from . import archinstall_adapter as arch
from .command import capture, capture_identifier, require_text
from .context import InstallContext
from .keyboard import configure_keyboard
from .phases import write_state
from .ui import error, info


def _private_arch_chroot_command(
    ctx: InstallContext, *args: str, user: str | None = None,
) -> list[str]:
    """Build an arch-chroot command isolated from sibling chroot mounts.

    arch-chroot mounts /proc, /dev and /sys below the target and tears them
    down on exit. Concurrent invocations therefore need private mount
    namespaces or one can unmount the other branch's API filesystems.
    """
    command = (
        ["unshare", "--mount", "--propagation", "private", "--", "arch-chroot"]
        if shutil.which("unshare") is not None
        else ["arch-chroot"]
    )
    if user:
        command += ["-u", user]
    command += [str(ctx.target), *args]
    return command


@contextmanager
def _timed_substep(ctx: InstallContext, name: str):
    """Measure a phase substep on the monotonic clock and expose it twice:
    immediately in the install log (and therefore on the recorded screen),
    and structurally in the final timing JSON for machine comparisons."""
    started = time.monotonic()
    try:
        yield
    finally:
        elapsed = time.monotonic() - started
        ctx.state.setdefault("phase_substeps", []).append({
            "name": name,
            "elapsed": elapsed,
        })
        info(f"› timing: {name}: {elapsed:.3f}s")


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


# The root image is a compact qcow2 wrapping a complete Btrfs filesystem. It
# contains the invariant target system in one read-only subvolume and restores
# its allocated clusters in parallel, instead of replaying roughly 100,000
# individual Btrfs send commands. The result is still a normal, independent
# Btrfs filesystem: every install rewrites its UUID before mounting it, grows
# it to the target partition, and creates the requested writable subvolumes.
# build-iso.sh puts it on the ISO beside its sha256sum output, read straight
# off the boot medium.
ROOT_IMAGE_STREAM = Path("/run/archiso/bootmnt/arch/x86_64/omarchy-root.btrfs.qcow2")
ROOT_IMAGE_SUBVOLUME = "omarchy-root"
# The live ISO starts omarchy-root-image-verify.service at boot: `sha256sum -c`
# of the stream, running while the user is in the configurator. It is the only
# verifier. Both this phase and the free-space configurator gate collect its
# verdict through this helper, which logs the boot medium and its I/O scheduler,
# waits for the unit if it is still hashing, and starts it if it never ran.
ROOT_IMAGE_VERIFY_HELPER = "/usr/local/bin/omarchy-wait-root-image-verify"
ROOT_IMAGE_VERIFY_UNIT = "omarchy-root-image-verify.service"


BOOT_MEDIUM_MOUNT = Path("/run/archiso/bootmnt")


def _root_image_stream() -> Path:
    if not ROOT_IMAGE_STREAM.is_file():
        # The archiso hook unmounts the boot medium after copying the airootfs
        # to RAM (copytoram). The boot entries pin copytoram=n, so this only
        # happens when someone edits the kernel command line.
        if not BOOT_MEDIUM_MOUNT.is_dir():
            raise RuntimeError(
                f"boot medium is not mounted at {BOOT_MEDIUM_MOUNT}: the live system was "
                "copied to RAM (copytoram) and the medium released; boot with copytoram=n"
            )
        raise RuntimeError(f"root image stream missing: {ROOT_IMAGE_STREAM}")
    return ROOT_IMAGE_STREAM

# Packages the image must carry for the rest of the install to work: Limine
# setup reads the settings package's limine config, useradd copies the skel the
# settings and nvim packages populate, and the target-side setup commands come
# from the runtime package. Checked right after unpacking so a mismatched
# image fails here with a clear message instead of three phases later.
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

def prepare_live(ctx: InstallContext) -> None:
    if ctx.is_protected:
        info("› protected mode: skipping whole-disk cleanup")
    else:
        disk = _install_disk(ctx)
        if disk:
            info(f"› cleaning up holders on install disk: {disk}")
            subprocess.run(["omarchy-iso-cleanup-disk", disk], check=True)

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
    so the stream, its checksum and a layout the image can land on are all
    checked here, where failing costs nothing."""
    if ctx.is_protected:
        verify_protected_mounts(ctx)
        # The protected layout exists already; check the real mounts.
        _root_image_target_mounts(ctx.target)
    else:
        verify_root_image_layout(ctx.user_configuration.get("disk_config") or {})
    verify_root_image_stream(ctx)


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
            for subvol in part.get("btrfs") or []:
                if subvol.get("mountpoint") == "/" and subvol.get("name") in ("@", "/@"):
                    return
    raise RuntimeError(
        "root image install needs the target root on a btrfs @ subvolume; "
        "disk_config mounts / from no such subvolume"
    )


def verify_root_image_stream(ctx: InstallContext) -> None:
    """The image is present, hashes to what the build recorded, and has valid
    qcow2 metadata. A truncated or corrupt copy (a badly flashed USB is the
    common case) must fail before the disk is formatted.

    ROOT_IMAGE_VERIFY_HELPER is the single source of truth: it collects the
    boot-time hasher's verdict, waiting for the unit if it is still running
    and starting it if it never did, and logs the boot medium and its I/O
    scheduler. The free-space configurator gate runs the same helper before it
    partitions, so both disk-touching paths clear the same check; whoever gets
    there first pays the wait. The hasher's read also leaves as much of the
    stream as fits in the page cache for the unpack that follows."""
    _publish_verify_progress(ctx)
    try:
        result = subprocess.run(
            [ROOT_IMAGE_VERIFY_HELPER],
            capture_output=True, text=True, check=False,
        )
    except OSError as exc:
        raise RuntimeError(f"could not run {ROOT_IMAGE_VERIFY_HELPER}: {exc}") from exc

    for line in result.stdout.splitlines():
        if line.strip():
            info(f"› {line.strip()}")

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip()
            or f"{ROOT_IMAGE_VERIFY_HELPER} failed with status {result.returncode}"
        )

    stream = _root_image_stream()
    image_check = subprocess.run(
        ["qemu-img", "check", "-q", "-f", "qcow2", str(stream)],
        capture_output=True, text=True, check=False,
    )
    if image_check.returncode != 0:
        detail = (image_check.stderr or image_check.stdout or "invalid qcow2 metadata").strip()
        raise RuntimeError(f"install medium root image is invalid: {detail}")


def _publish_verify_progress(ctx: InstallContext) -> None:
    """While the boot-time hasher is still reading the stream, mirror its read
    position into phase_progress so the dashboard bar tracks the actual hash
    instead of the phase's time-driven band. Best effort throughout: the
    helper is the authority on the verdict, and any hiccup here (unit already
    done, hasher between opens, /proc gone) just skips a sample."""
    try:
        total = ROOT_IMAGE_STREAM.stat().st_size
    except OSError:
        return
    while total and _verify_unit_property("ActiveState") == "activating":
        pos = _hasher_read_pos()
        if pos is not None:
            _write_phase_progress(ctx, pos / total)
        time.sleep(0.5)


def _verify_unit_property(prop: str) -> str:
    res = subprocess.run(
        ["systemctl", "show", ROOT_IMAGE_VERIFY_UNIT, "-p", prop, "--value"],
        capture_output=True, text=True, check=False,
    )
    return res.stdout.strip()


def _hasher_read_pos() -> int | None:
    """Byte offset of the hasher's open fd on the stream: the unit's MainPID
    is sha256sum while it runs, and fdinfo's pos is how far it has read."""
    pid = _verify_unit_property("MainPID")
    if not pid.isdigit() or pid == "0":
        return None
    fd_dir = Path("/proc") / pid / "fd"
    try:
        for fd in fd_dir.iterdir():
            try:
                if fd.resolve() != ROOT_IMAGE_STREAM:
                    continue
                fdinfo = (fd_dir.parent / "fdinfo" / fd.name).read_text()
            except OSError:
                continue
            for line in fdinfo.splitlines():
                if line.startswith("pos:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


def _remove_baked_stock_kernel_for_t2(ctx: InstallContext, config) -> None:
    """Remove the image's stock kernel when the target selected linux-t2."""
    selected = list(config.kernels or [])
    if "linux-t2" not in selected or "linux" in selected:
        return

    if not arch.target_has_package(ctx.target, "linux-t2"):
        raise RuntimeError("selected T2 kernel linux-t2 is not installed")
    if not arch.target_has_package(ctx.target, "linux"):
        return

    info("› removing baked stock kernel from T2 target")
    result = subprocess.run(
        ["arch-chroot", str(ctx.target), "pacman", "-Rdd", "--noconfirm", "linux"],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "unknown pacman error").strip()
        raise RuntimeError(f"could not remove stock linux kernel from T2 target: {detail}")
    if arch.target_has_package(ctx.target, "linux"):
        raise RuntimeError("stock linux kernel remains installed on T2 target")


def arch_install_system(ctx: InstallContext) -> None:
    """Install the target system: archinstall partitions and mounts per the
    configurator JSON, the root image is unpacked onto the mounted layout, and
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
        with _timed_substep(ctx, "partition, format, and encrypt"):
            arch.perform_filesystem_operations(config)

    info("› opening installer context")
    with arch.open_installer(config, ctx.target, silent=True) as installer:
        with _timed_substep(ctx, "mount and validate target"):
            if not pre_mounted:
                installer.mount_ordered_layout()

            installer.sanity_check(
                offline=True,
                skip_ntp=True,
                skip_wkd=True,
            )

        # Before anything writes into the target: the image replaces the
        # (empty) root subvolume archinstall created, and everything written
        # there first would go with it.
        with _timed_substep(ctx, "unpack root image"):
            _install_root_image(ctx)

        if not pre_mounted and arch.is_encrypted(config):
            installer.generate_key_files()

        if config.mirror_config:
            installer.set_mirrors(mirror_handler, config.mirror_config, on_target=False)

        _mount_offline_package_cache(ctx)
        _mask_mkinitcpio_pacman_hooks(ctx)
        try:
            info("› installing per-machine packages (mkinitcpio deferred to final Limine UKI build)")
            # An empty kb_layout makes archinstall's set_keyboard_language skip
            # booting the target in a container just to run localectl; the
            # keymap is configured offline right after instead.
            kb_layout = config.locale_config.kb_layout if config.locale_config else ""
            with _timed_substep(ctx, "per-machine package delta"):
                arch.install_base_delta(
                    installer,
                    config,
                    hostname=config.hostname,
                    locale_config=(
                        replace(config.locale_config, kb_layout="")
                        if config.locale_config else None
                    ),
                )
                _remove_baked_stock_kernel_for_t2(ctx, config)

            if not configure_keyboard(installer.target, kb_layout):
                error(f"Invalid keyboard language specified: {kb_layout}")

            if config.mirror_config:
                installer.set_mirrors(mirror_handler, config.mirror_config, on_target=True)

            if config.swap and config.swap.enabled:
                arch.setup_zram_swap(installer)
                _drop_archinstall_zram_conf(ctx)

            with _timed_substep(ctx, "configure Limine"):
                _configure_limine_boot(ctx, installer, config)

            info("› creating user (with /etc/skel populated)")
            with _timed_substep(ctx, "create user"):
                if config.auth_config and config.auth_config.users:
                    installer.create_users(config.auth_config.users)

            if config.app_config:
                # The image carries the PipeWire packages; this adds the audio
                # firmware archinstall's hardware detection asks for and wires
                # the per-user PipeWire units.
                info("› applying archinstall application selections")
                arch.install_applications(installer, config)

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
        with _timed_substep(ctx, "write target metadata"):
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
# Root image: restore the build-time Btrfs filesystem onto the target device
# and make its immutable image subvolume the writable @ subvolume.
#
# archinstall (or the configurator, for protected installs) has created and
# mounted the subvolume layout by the time this runs: @ at the target, with
# @home, @log, @pkg and the ESP mounted inside it. Capture that layout, unmount
# it, restore the image directly to the same Btrfs block device, give the clone
# a unique UUID, grow it, create the requested empty subvolumes, and replay the
# original mount table. Asking archinstall to mount again would also unlock
# LUKS a second time; the mapper stays open throughout.
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


def _remount_option_string(options: str) -> str:
    # subvolid refers to the subvolume replaced here; subvol= names it.
    return ",".join(opt for opt in options.split(",") if not opt.startswith("subvolid="))


def _root_image_target_mounts(target: Path) -> tuple[list[dict], str]:
    """The mount table under target, checked for what the image swap needs:
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


def _install_root_image(ctx: InstallContext) -> None:
    target = ctx.target
    stream = _root_image_stream()
    mounts, device = _root_image_target_mounts(target)

    virtual_size = _root_image_virtual_size(stream)
    device_size = int(capture_identifier(
        ["blockdev", "--getsize64", device],
        f"the size of Btrfs target {device}",
    ))
    if virtual_size > device_size:
        raise RuntimeError(
            f"root image needs {virtual_size} bytes but {device} has only {device_size}"
        )

    top = ctx.state_dir / "image-top"
    top.mkdir(parents=True, exist_ok=True)
    layout_released = False
    top_mounted = False
    root_ready = False
    image_swap_succeeded = False
    try:
        info(
            f"› restoring root filesystem ({stream.stat().st_size >> 20} MiB qcow2, "
            f"{virtual_size >> 20} MiB virtual)"
        )
        _umount_tree(target)
        layout_released = True

        _restore_root_image(stream, device)
        # A byte-for-byte filesystem clone must never keep the image's FSID:
        # two installed disks can be connected to the same machine, and Btrfs
        # identifies filesystems by this value. -u rewrites the full UUID (not
        # the lighter metadata_uuid compatibility mode) and -f is the command's
        # non-interactive acknowledgement.
        subprocess.run(["btrfstune", "-f", "-u", device], check=True)

        subprocess.run(["mount", "-o", "subvolid=5", device, str(top)], check=True)
        top_mounted = True
        subprocess.run(["btrfs", "filesystem", "resize", "max", str(top)], check=True,
                       capture_output=True)

        received = top / ROOT_IMAGE_SUBVOLUME
        if not received.is_dir():
            raise RuntimeError(f"restored root image has no {ROOT_IMAGE_SUBVOLUME} subvolume")

        installed_root = top / "@"
        if installed_root.exists():
            raise RuntimeError("restored root image unexpectedly contains an @ subvolume")

        # Unlike a send stream, a complete filesystem image retains nested
        # subvolumes created by systemd (currently var/lib/{machines,portables}).
        # Deleting the image parent would therefore fail, while snapshotting it
        # would silently turn those children into empty directory stubs. Make
        # the image root writable in place and rename it atomically instead.
        subprocess.run(
            ["btrfs", "property", "set", "-ts", str(received), "ro", "false"],
            check=True, capture_output=True,
        )
        info("› making the image the root subvolume")
        received.rename(installed_root)
        root_ready = True

        # The qcow2 deliberately contains only the invariant root. Recreate
        # the machine/user-specific subvolumes archinstall requested before
        # replaying its mounts, keeping the standard Omarchy disk layout.
        for name in _layout_subvolumes(mounts, device):
            path = top / name
            if not path.exists():
                subprocess.run(["btrfs", "subvolume", "create", str(path)], check=True,
                               capture_output=True)

        # The image's pacman.log ends up under the @log mount; carry it over so
        # the installed system's log starts with the packages it was built from.
        image_log = installed_root / "var" / "log" / "pacman.log"
        log_subvol = top / "@log"
        if image_log.is_file() and log_subvol.is_dir():
            shutil.copy2(image_log, log_subvol / "pacman.log")

        image_swap_succeeded = True

    finally:
        if top_mounted:
            subprocess.run(["umount", str(top)], check=False, capture_output=True)
        if layout_released and top_mounted and root_ready:
            for mount in mounts:
                mountpoint = Path(mount["target"])
                mountpoint.mkdir(parents=True, exist_ok=True)
                source = (mount["source"] or "").split("[")[0]
                result = subprocess.run(
                    ["mount", "-t", mount["fstype"], "-o", _remount_option_string(mount["options"] or ""),
                     source, str(mountpoint)],
                    check=image_swap_succeeded,
                    capture_output=not image_swap_succeeded,
                    text=not image_swap_succeeded,
                )
                if not image_swap_succeeded and result.returncode != 0:
                    info(
                        f"› recovery remount failed for {mountpoint}: "
                        f"{(result.stderr or '').strip() or f'exit {result.returncode}'}"
                    )

    missing = [pkg for pkg in _root_image_required_packages() if not arch.target_has_package(target, pkg)]
    if missing:
        raise RuntimeError(f"root image lacks required packages: {', '.join(missing)}")

    # Per-machine identity the image deliberately ships without.
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
    and joined by create_factory_snapshot: nothing in between reads the
    keyring (the offline repo is SigLevel = Never) or writes it, and the
    snapshot must not capture it half-written. A unit rather than a plain
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
        f"pacman-key --gpgdir {gpgdir} --populate-from {keyrings} --populate archlinux omarchy"
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


def _root_image_virtual_size(image: Path) -> int:
    result = subprocess.run(
        ["qemu-img", "info", "--output=json", "-f", "qcow2", str(image)],
        check=True, capture_output=True, text=True,
    )
    try:
        metadata = json.loads(result.stdout)
        size = int(metadata["virtual-size"])
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"qemu-img returned invalid metadata for {image}") from exc
    if size <= 0:
        raise RuntimeError(f"root image has invalid virtual size {size}: {image}")
    return size


def _restore_root_image(image: Path, device: str) -> None:
    """Restore allocated qcow2 clusters to an existing target block device.

    -n is essential: qemu-img must write the device, never try to create or
    truncate it. -W lets those coroutines issue independent output writes out
    of order; the filesystem is not used until the completed image is checked,
    resized, and mounted.
    """
    # These are I/O coroutines rather than dedicated CPU-bound workers. The
    # compressed-input/encrypted-output path keeps roughly two per visible CPU
    # busy, while qemu-img rejects values above 16. Never pass zero on odd
    # container/cgroup setups where cpu_count() cannot determine a value.
    workers = min(max(1, os.cpu_count() or 1) * 2, 16)
    result = subprocess.run(
        ["qemu-img", "convert", "-q", "-f", "qcow2", "-O", "raw", "-W", "-n",
         "-m", str(workers), str(image), device],
        check=False, capture_output=True, text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "unknown qemu-img error").strip()
        raise RuntimeError(f"root filesystem restore failed: {detail}")


def _layout_subvolumes(mounts: list[dict], device: str) -> list[str]:
    """Btrfs subvolume names from the captured layout, excluding root (@)."""
    names: list[str] = []
    for mount in mounts:
        source = (mount.get("source") or "").split("[")[0]
        if mount.get("fstype") != "btrfs" or source != device:
            continue
        option = next(
            (part.split("=", 1)[1] for part in (mount.get("options") or "").split(",")
             if part.startswith("subvol=")),
            "",
        )
        name = option.lstrip("/")
        if name and name != "@" and name not in names:
            names.append(name)
    return names


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
        efi_binary=boot.get("efi_binary", "limine_x64.efi"),
        pre_state=pre_state,
    )

    post_state = _read_efibootmgr()
    windows_after = _find_label_entries(post_state["entries"], "Windows")
    if windows_before and not windows_after:
        raise RuntimeError("Windows boot entry disappeared during Limine install — aborting")


def _install_limine_efi(
    ctx: InstallContext,
    *,
    esp_mount: str,
    disk: Path,
    part: int,
    removable: bool = False,
    esp_path: str = "/EFI/limine",
    efi_binary: str = "limine_x64.efi",
    pre_state: dict | None = None,
) -> None:
    if removable:
        esp_path = "/EFI/BOOT"
        efi_binary = "BOOTX64.EFI"

    limine_path = ctx.target / "usr" / "share" / "limine"
    source_name = "BOOTX64.EFI"
    target_dir = Path(esp_mount) / esp_path.lstrip("/")
    target_path = target_dir / efi_binary
    _copy_required(limine_path / source_name, ctx.target / target_path.relative_to("/"))

    hook_command = f"/usr/bin/cp /usr/share/limine/{source_name} {target_path}"
    _write_limine_pacman_hook(ctx.target, hook_command)

    loader = "\\" + str(Path(esp_path) / efi_binary).strip("/").replace("/", "\\")
    _register_limine_efi_entry(disk, part, loader, pre_state=pre_state)


def _register_limine_efi_entry(
    disk: Path,
    part: int,
    loader: str,
    *,
    pre_state: dict | None = None,
) -> None:
    pre_state = pre_state or _read_efibootmgr()
    stale_limine = _find_label_entries(pre_state["entries"], "Limine")
    for num in stale_limine:
        subprocess.run(
            ["efibootmgr", "--bootnum", num, "--delete-bootnum"],
            check=False, capture_output=True,
        )

    subprocess.run(
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
        check=True,
    )

    post_state = _read_efibootmgr()
    new_limine = _find_label_entries(post_state["entries"], "Limine")
    if not new_limine:
        raise RuntimeError("efibootmgr --create reported success but no Limine entry found")
    limine_num = new_limine[0]

    keep = [
        num
        for num in pre_state["order"]
        if num not in stale_limine
        and num != limine_num
        and num in pre_state["entries"]
    ]
    subprocess.run(
        ["efibootmgr", "--bootorder", ",".join([limine_num, *keep])],
        check=True, capture_output=True,
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

    cmdline = " ".join(installer._get_kernel_params(root))
    _write_limine_defaults(ctx, cmdline, esp_mount=_installer_esp_mount(installer))


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


# ─────────────────────────────────────────────────────────────────────────────
# Install intent helpers: normalize the Omarchy-specific part of the
# configurator JSON so full-disk and pre-mounted installs feed the same boot
# and target setup code.
# ─────────────────────────────────────────────────────────────────────────────

def _boot_intent(ctx: InstallContext) -> dict:
    boot = dict(ctx.omarchy_install.get("boot") or {})
    boot.setdefault("esp_mount", "/boot")
    boot.setdefault("esp_path", "/EFI/limine")
    boot.setdefault("efi_binary", "limine_x64.efi")
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

    info(f"› protected target verified: kernel={storage.get('kernel', 'linux')} esp={boot['esp_mount']}")


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
    crypttab.write_text(f"omarchy_root  UUID={luks_uuid}  none  luks,discard\n")


def _build_pre_mounted_cmdline(ctx: InstallContext, btrfs_uuid: str) -> str:
    storage = _storage_intent(ctx)
    if storage.get("luks_uuid"):
        root_mapper = storage.get("root_mapper") or "/dev/mapper/omarchy_root"
        return (
            f"cryptdevice=UUID={storage['luks_uuid']}:omarchy_root "
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

_BOOT_ENTRY_RE = re.compile(r"^Boot([0-9A-Fa-f]{4})\*?\s+(.*)$")
_BOOT_ORDER_RE = re.compile(r"^BootOrder:\s*(.*)$")


def _read_efibootmgr() -> dict:
    res = capture(["efibootmgr"], check=True)
    entries: dict[str, str] = {}
    order: list[str] = []
    for line in res.stdout.splitlines():
        m = _BOOT_ENTRY_RE.match(line)
        if m:
            entries[m.group(1).upper()] = m.group(2).strip()
            continue
        m = _BOOT_ORDER_RE.match(line)
        if m:
            order = [n.strip().upper() for n in m.group(1).split(",") if n.strip()]
    return {"entries": entries, "order": order, "raw": res.stdout}


def _find_label_entries(entries: dict[str, str], needle: str) -> list[str]:
    return [num for num, label in entries.items() if needle.lower() in label.lower()]


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
    _configure_initramfs_encryption_hooks(ctx)

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
    _configure_quiet_resume_hook(ctx)


UNENCRYPTED_HOOKS_DROPIN = Path("etc/mkinitcpio.conf.d/zz-omarchy-unencrypted-root.conf")
QUIET_RESUME_INSTALL_HOOK = Path("etc/initcpio/install/omarchy-resume")
QUIET_RESUME_RUNTIME_HOOK = Path("etc/initcpio/hooks/omarchy-resume")
QUIET_RESUME_DROPIN = Path("etc/mkinitcpio.conf.d/zz-omarchy-resume.conf")


def _root_is_encrypted(ctx: InstallContext) -> bool:
    """Use both the install intent and disk description. The marker is the
    normal full-disk source; protected installs describe an existing LUKS root
    through omarchy_install.storage instead."""
    if ctx.encrypt or _storage_intent(ctx).get("luks_uuid"):
        return True

    encryption = (ctx.user_configuration.get("disk_config") or {}).get("disk_encryption")
    if not encryption:
        return False
    kind = str(encryption.get("encryption_type") or "").lower()
    return kind not in {"", "no_encryption", "no encryption", "none"}


def _configure_initramfs_encryption_hooks(ctx: InstallContext) -> None:
    """The runtime's common mkinitcpio preset includes the encrypt hook so an
    encrypted install can prompt before mounting root. On an unencrypted root,
    that hook guesses root= is the crypto device and prints a false LUKS error
    on every boot. A later drop-in removes only unlock hooks for that case."""
    dropin = ctx.target / UNENCRYPTED_HOOKS_DROPIN
    if _root_is_encrypted(ctx):
        dropin.unlink(missing_ok=True)
        return

    dropin.parent.mkdir(parents=True, exist_ok=True)
    dropin.write_text(textwrap.dedent("""\
        # Generated by the Omarchy installer: this root is not encrypted.
        _omarchy_unencrypted_hooks=()
        for _omarchy_hook in "${HOOKS[@]}"; do
          case $_omarchy_hook in
            encrypt | sd-encrypt) ;;
            *) _omarchy_unencrypted_hooks+=("$_omarchy_hook") ;;
          esac
        done
        HOOKS=("${_omarchy_unencrypted_hooks[@]}")
        unset _omarchy_unencrypted_hooks _omarchy_hook
        """))


def _configure_quiet_resume_hook(ctx: InstallContext) -> None:
    """Keep hibernation enabled without printing a failure on every ordinary
    boot. systemd-hibernate-resume warns when the configured swap contains no
    image, which is the expected state except immediately after hibernating.
    This install-local hook runs the same helper at error log level; genuine
    errors still surface and a valid image resumes normally."""
    resume_config = ctx.target / "etc/mkinitcpio.conf.d/omarchy_resume.conf"
    if not resume_config.is_file():
        return

    install_hook = ctx.target / QUIET_RESUME_INSTALL_HOOK
    runtime_hook = ctx.target / QUIET_RESUME_RUNTIME_HOOK
    hook_dropin = ctx.target / QUIET_RESUME_DROPIN
    for path in (install_hook, runtime_hook, hook_dropin):
        path.parent.mkdir(parents=True, exist_ok=True)

    install_hook.write_text(textwrap.dedent("""\
        #!/bin/bash

        build() {
          add_binary /usr/lib/systemd/systemd-hibernate-resume
          add_runscript
        }

        help() {
          cat <<'EOF'
        Resume from Omarchy's Btrfs swapfile without warning when no image exists.
        EOF
        }
        """))
    runtime_hook.write_text(textwrap.dedent("""\
        #!/usr/bin/ash

        run_hook() {
          [ -n "$(getarg noresume)" ] && return 0
          SYSTEMD_LOG_LEVEL=err /usr/lib/systemd/systemd-hibernate-resume
          return 0
        }
        """))
    hook_dropin.write_text(textwrap.dedent("""\
        # Generated by the Omarchy installer: replace the noisy stock resume hook.
        _omarchy_resume_hooks=()
        for _omarchy_hook in "${HOOKS[@]}"; do
          if [[ $_omarchy_hook == resume ]]; then
            _omarchy_resume_hooks+=(omarchy-resume)
          else
            _omarchy_resume_hooks+=("$_omarchy_hook")
          fi
        done
        HOOKS=("${_omarchy_resume_hooks[@]}")
        unset _omarchy_resume_hooks _omarchy_hook
        """))
    install_hook.chmod(0o755)
    runtime_hook.chmod(0o755)


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
#  2. bind-mount the offline mirror + /opt/packages into /mnt for target pacman
#     and bundled language runtimes
#  3. arch-chroot as root → omarchy-apply-system --first-install
#  4. arch-chroot as user → omarchy-provision-user --first-install
# ─────────────────────────────────────────────────────────────────────────────

def _prepare_target_setup(ctx: InstallContext) -> None:
    if ctx.state.get("target_setup_prepared"):
        return

    shutil.copy("/etc/pacman.conf", str(ctx.target / "etc" / "pacman.conf"))

    bind_mounts = [
        ("/var/cache/omarchy/mirror/offline", "/var/cache/omarchy/mirror/offline"),
        ("/opt/packages", "/opt/packages"),
    ]
    ctx.state.setdefault("bind_mounts", [])
    mounted = set(ctx.state["bind_mounts"])
    for src, dst in bind_mounts:
        target_dst = ctx.target / dst.lstrip("/")
        target_dst.mkdir(parents=True, exist_ok=True)
        if str(target_dst) not in mounted:
            subprocess.run(["mount", "--bind", src, str(target_dst)], check=True)
            ctx.state["bind_mounts"].append(str(target_dst))
            mounted.add(str(target_dst))

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


def _run_target_setup_command(ctx: InstallContext, cmd: list[str], *, user: str | None = None) -> None:
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
        f"OMARCHY_USER_NAME={ctx.full_name}",
        f"OMARCHY_USER_EMAIL={ctx.email}",
        f"OMARCHY_MIRROR={mirror_channel}",
        f"OMARCHY_ISO_REF={_iso_ref()}",
        f"OMARCHY_RUNTIME_PACKAGE={_omarchy_runtime_package()}",
        f"OMARCHY_SETTINGS_PACKAGE={_omarchy_settings_package()}",
        f"OMARCHY_NVIM_PACKAGE={_omarchy_nvim_package()}",
        "OMARCHY_INSTALL_LOG_FILE=/var/log/omarchy-install.log",
        "OMARCHY_LOG_TO_STDOUT=1",
    ]
    if _install_debug_enabled():
        env_extras.append("OMARCHY_INSTALL_DEBUG=1")
        _debug_log(ctx, "running target setup command: " + " ".join(cmd))

    chroot_cmd = _private_arch_chroot_command(ctx, user=user)
    if user:
        env_extras.extend(_target_user_env(ctx, user))
    chroot_cmd += ["env", "--unset=XDG_RUNTIME_DIR", *env_extras, *cmd]

    try:
        subprocess.run(chroot_cmd, check=True)
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

    _mask_mkinitcpio_pacman_hooks(ctx, ctx.target, TARGET_DEFERRED_BOOT_HOOKS)
    try:
        _run_target_setup_command(ctx, cmd)
    finally:
        _unmask_mkinitcpio_pacman_hooks(ctx, ctx.target, TARGET_DEFERRED_BOOT_HOOKS)


# ─────────────────────────────────────────────────────────────────────────────
# stage_provisioning_state: produce the on-disk "provisioning state" the runtime's first-boot
# setup (omarchy-provision-owner) and factory reset (omarchy-system-factory-reset) consume.
#
# Every install stashes the bundled Node tarball in /var/lib/omarchy/provisioning/
# so a later factory reset can finalize the new owner's user offline. deferred-provisioning
# installs additionally arm the first-boot setup service and, on encrypted
# targets, stage the throwaway LUKS passphrase: the keyfile embedded in the
# initramfs auto-unlocks boot during the provisioning window, and first-boot setup
# re-keys the volume to the owner's password and removes it.
#
# Runs before finalize_limine_boot so the cryptkey cmdline drop-in and the
# keyfile land in the final UKI build.
# ─────────────────────────────────────────────────────────────────────────────

PROVISION_STATE_DIR = "var/lib/omarchy/provisioning"
PROVISION_KEYFILE = "etc/omarchy/provisioning.key"
NODE_PACKAGES_DIR = Path("/opt/packages")


def stage_provisioning_state(ctx: InstallContext) -> None:
    # World-readable: first-boot finalization reads the Node tarball as the
    # new user. The only secret inside (luks-key) is itself 0600 root.
    provisioning_dir = ctx.target / PROVISION_STATE_DIR
    provisioning_dir.mkdir(parents=True, exist_ok=True)
    provisioning_dir.chmod(0o755)

    _stage_node_tarball(ctx, provisioning_dir)

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


def _stage_node_tarball(ctx: InstallContext, provisioning_dir) -> None:
    tarballs = sorted(NODE_PACKAGES_DIR.glob("node-v*-linux-x64.tar.gz"))
    if not tarballs:
        # Hard error on every install, not just deferred-provisioning installs: the stash is what lets a
        # later factory reset finalize the next owner offline, and an ISO
        # build always bundles the tarball — its absence means a broken build.
        raise RuntimeError(
            f"no bundled Node tarball in {NODE_PACKAGES_DIR} — first-boot setup "
            "and factory reset could not finalize a user offline"
        )

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

    files_dropin = ctx.target / "etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf"
    files_dropin.parent.mkdir(parents=True, exist_ok=True)
    files_dropin.write_text("FILES+=(/etc/omarchy/provisioning.key)\n")


def finalize_limine_boot(ctx: InstallContext) -> None:
    """Finalize Limine after target system setup has written all dynamic
    boot drop-ins (hibernation, hardware quirks, protected-mode ESP settings).
    """
    if not (ctx.target / "usr" / "bin" / "limine-update").exists():
        raise RuntimeError("/usr/bin/limine-update missing in target")

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

    subprocess.run(_private_arch_chroot_command(ctx, "limine-update"), check=True)

    subprocess.run(
        _private_arch_chroot_command(ctx, "btrfs", "quota", "disable", "/"),
        check=False,
        capture_output=True,
    )
    if "Omarchy" not in limine_conf.read_text():
        raise RuntimeError(f"{limine_conf} has no Omarchy entry")
    if "cryptdevice=" in cmdline and "cryptdevice=" not in limine_conf.read_text():
        raise RuntimeError(f"encrypted install but {limine_conf} has no cryptdevice=")


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
            value = _strip_shell_quotes(match.group(1))
    return value


def _limine_kernel_cmdline(config_text: str) -> str:
    parts: list[str] = []
    pattern = re.compile(r'^\s*KERNEL_CMDLINE\[default\]\+=\s*(.*?)\s*$')
    for line in config_text.splitlines():
        match = pattern.match(line)
        if match:
            parts.append(_strip_shell_quotes(match.group(1)).strip())
    return " ".join(part for part in parts if part).strip()


def run_chroot_finalizer(ctx: InstallContext) -> None:
    if ctx.defer_provisioning:
        info("› deferred-provisioning install: user finalization deferred to first boot")
        return

    _run_target_setup_command(
        ctx,
        ["/usr/bin/omarchy-provision-user", "--force", "--first-install"],
        user=ctx.username,
    )


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
            _private_arch_chroot_command(
                ctx, "chown", "sddm:sddm", "/var/lib/sddm", "/var/lib/sddm/state.conf",
            ),
            check=False, capture_output=True,
        )

    autologin = ctx.target / "etc" / "systemd" / "system" / "getty@tty1.service.d" / "autologin.conf"
    autologin.unlink(missing_ok=True)

    subprocess.run(
        _private_arch_chroot_command(ctx, "systemctl", "enable", "sddm.service"),
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
            _private_arch_chroot_command(
                ctx, "chown", "-R", f"{ctx.username}:{ctx.username}",
                f"/home/{ctx.username}/.ssh",
            ),
            check=True,
        )

    info("› enabling sshd")
    subprocess.run(
        _private_arch_chroot_command(ctx, "systemctl", "enable", "sshd.service"),
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
    subprocess.run(
        _private_arch_chroot_command(ctx, "ufw", "allow", "ssh"), check=False,
    )

    rules = ctx.target / "etc" / "ufw" / "user.rules"
    text = rules.read_text() if rules.exists() else ""
    if "--dport 22 -j ACCEPT" not in text:
        raise RuntimeError(f"ufw did not record an allow rule for port 22 in {rules}")


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
        _private_arch_chroot_command(
            ctx, "systemctl", "enable", "tailscaled.service",
            "omarchy-tailscale-join.service",
        ),
        check=True,
    )

    # Same dance as configure_ssh_access: ufw cannot reach netfilter from the
    # chroot and exits non-zero, but it records the rule in user.rules first,
    # and that file is what ufw.service loads on first boot. Without the rule
    # the node joins the tailnet and is then unreachable over it.
    info("› allowing tailnet traffic through ufw")
    subprocess.run(
        _private_arch_chroot_command(
            ctx, "ufw", "allow", "in", "on", "tailscale0",
        ),
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


FinalizationStep = tuple[str, Callable[[InstallContext], None]]


def _run_finalization_branch(
    ctx: InstallContext, branch: str, steps: tuple[FinalizationStep, ...],
) -> tuple[list[dict], tuple[str, Exception] | None]:
    """Run one ordered side of the finalization fan and retain its timings."""
    records: list[dict] = []
    for name, fn in steps:
        info(f"› {name} [{branch} branch]")
        started = time.monotonic()
        try:
            fn(ctx)
        except Exception as exc:  # noqa: BLE001
            elapsed = time.monotonic() - started
            records.append({
                "name": name,
                "branch": branch,
                "status": "failed",
                "elapsed": elapsed,
                "error": str(exc),
            })
            return records, (name, exc)

        elapsed = time.monotonic() - started
        records.append({
            "name": name,
            "branch": branch,
            "status": "ok",
            "elapsed": elapsed,
        })
        info(f"› timing: {name} [{branch} branch]: {elapsed:.3f}s")

    return records, None


def finalize_boot_and_user_setup(ctx: InstallContext) -> None:
    """Run the two independent post-provisioning branches concurrently.

    Limine's UKI build only reads system/provisioning state already finalized
    before this phase. User provisioning and its login/network tail are ordered
    with respect to each other, but do not feed that UKI. Both branches join
    before validate_boot and the factory snapshot.

    Invariant: the user branch must not install, remove, or upgrade packages,
    call a package-manager helper, or otherwise trigger mkinitcpio. Doing so
    could start a second UKI build against the files Limine is writing in the
    boot branch. Keep any such work in a serial phase before this fan-out.
    """
    branches: tuple[tuple[str, tuple[FinalizationStep, ...]], ...] = (
        ("boot", (("Finalizing Limine boot", finalize_limine_boot),)),
        ("user", (
            ("Finalizing user", run_chroot_finalizer),
            ("Configuring login", configure_login),
            ("Configuring SSH access", configure_ssh_access),
            ("Configuring Tailscale", configure_tailscale),
            ("Configuring DNS resolver", configure_dns_resolver),
        )),
    )

    if shutil.which("unshare") is None:
        info("› unshare unavailable; finalizing branches serially")
        outcomes = [
            _run_finalization_branch(ctx, branch, steps)
            for branch, steps in branches
        ]
    else:
        with ThreadPoolExecutor(max_workers=2, thread_name_prefix="omarchy-finalize") as pool:
            futures = [
                pool.submit(_run_finalization_branch, ctx, branch, steps)
                for branch, steps in branches
            ]
            outcomes = [future.result() for future in futures]

    ctx.state["phase_substeps"] = [
        record for records, _failure in outcomes for record in records
    ]
    failures = [failure for _records, failure in outcomes if failure is not None]
    if failures:
        _name, exc = failures[0]
        detail = "; ".join(f"{failed_name}: {error}" for failed_name, error in failures)
        raise RuntimeError(f"parallel finalization failed ({detail})") from exc


# ─────────────────────────────────────────────────────────────────────────────
# validate_boot: hard checks before reboot. If the install ran but produced a
# boot config or UKI that can't actually boot, halt here rather than surprise
# the user.
# ─────────────────────────────────────────────────────────────────────────────

def validate_boot(ctx: InstallContext) -> None:
    _assert_boot_hooks_restored(ctx)

    boot = _boot_intent(ctx)
    storage = _storage_intent(ctx)
    esp_mount = ctx.target / boot["esp_mount"].lstrip("/")

    limine_conf = esp_mount / "limine.conf"
    if not limine_conf.exists():
        raise RuntimeError(f"{limine_conf} missing")
    limine_conf_text = limine_conf.read_text()
    if "Omarchy" not in limine_conf_text:
        raise RuntimeError(f"{limine_conf} has no Omarchy entry")

    kernel_cmdline = ctx.target / "etc" / "kernel" / "cmdline"
    if not kernel_cmdline.exists():
        raise RuntimeError(f"{kernel_cmdline} missing — UKI would have no cmdline")

    default_limine = ctx.target / "etc" / "default" / "limine"
    config_text = _limine_combined_config_text(ctx, default_limine.read_text())
    configured_cmdline = _limine_kernel_cmdline(config_text)
    unlock_markers = (
        "cryptdevice=", "cryptkey=", "crypto=", "rd.luks.name=", "rd.luks.uuid=", "dm-mod.create=",
    )
    has_unlock = any(marker in configured_cmdline or marker in limine_conf_text for marker in unlock_markers)
    if _root_is_encrypted(ctx) and not has_unlock:
        raise RuntimeError(f"Encrypted install but {limine_conf} has no root unlock parameter")
    if not _root_is_encrypted(ctx) and has_unlock:
        raise RuntimeError(f"Unencrypted install but {limine_conf} contains a root unlock parameter")
    if not _root_is_encrypted(ctx) and not (ctx.target / UNENCRYPTED_HOOKS_DROPIN).is_file():
        raise RuntimeError("Unencrypted install has no mkinitcpio drop-in disabling encryption hooks")
    resume_config = ctx.target / "etc/mkinitcpio.conf.d/omarchy_resume.conf"
    if resume_config.is_file():
        for required in (QUIET_RESUME_INSTALL_HOOK, QUIET_RESUME_RUNTIME_HOOK, QUIET_RESUME_DROPIN):
            if not (ctx.target / required).is_file():
                raise RuntimeError(f"Hibernation is configured but {ctx.target / required} is missing")

    uki_prefix = _limine_setting(config_text, "CUSTOM_UKI_NAME", "omarchy") or "omarchy"
    kernel = storage.get("kernel") or (ctx.user_configuration.get("kernels") or ["linux"])[0]

    if arch.has_uefi():
        limine_binary = esp_mount / boot.get("esp_path", "/EFI/limine").lstrip("/") / boot.get("efi_binary", "limine_x64.efi")
        if not limine_binary.exists() or limine_binary.stat().st_size == 0:
            raise RuntimeError(f"{limine_binary} missing or empty")

        # Hardware packages (omarchy-hw-intel-ptl, …) can swap the configured
        # kernel out mid-install. When it remains installed, require its own
        # UKI: an unusable stock UKI must not hide a failed linux-t2 build.
        uki_dir = esp_mount / "EFI" / "Linux"
        installed_kernels = _installed_kernels(ctx)
        candidates = (
            [kernel]
            if kernel in installed_kernels
            else installed_kernels or [kernel]
        )
        ukis = [uki_dir / f"{uki_prefix}_{name}.efi" for name in candidates]
        if not any(uki.exists() and uki.stat().st_size for uki in ukis):
            raise RuntimeError(f"{' / '.join(str(uki) for uki in ukis)} missing or empty")

        post = _read_efibootmgr()
        if not _find_label_entries(post["entries"], "Limine"):
            raise RuntimeError("no 'Limine' entry registered in efibootmgr")

    if ctx.is_protected:
        _validate_pre_mounted_filesystems(ctx)

    if ctx.defer_provisioning:
        _validate_provisioning_state(ctx)


def _validate_provisioning_state(ctx: InstallContext) -> None:
    """An deferred-provisioning install that boots without a working first-boot setup is a
    user-less brick; insist the armed state is complete before reboot."""
    provisioning_dir = ctx.target / PROVISION_STATE_DIR
    if not (provisioning_dir / "pending").exists():
        raise RuntimeError(f"deferred-provisioning install but {provisioning_dir / 'pending'} is missing")

    link = ctx.target / "etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"
    if not link.is_symlink():
        raise RuntimeError("deferred-provisioning install but omarchy-provision-owner.service is not enabled")

    if not list((provisioning_dir / "packages").glob("node-v*.tar.gz")):
        raise RuntimeError(f"deferred-provisioning install but no Node tarball staged in {provisioning_dir / 'packages'}")

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


# Every kernel package leaves its pkgbase next to its modules, which is also
# the name limine-mkinitcpio-hook builds the UKI under.
def _installed_kernels(ctx: InstallContext) -> list[str]:
    names = []
    for pkgbase in sorted((ctx.target / "usr" / "lib" / "modules").glob("*/pkgbase")):
        name = pkgbase.read_text().strip()
        if name and name not in names:
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

def create_factory_snapshot(ctx: InstallContext) -> None:
    # The keyring unit writes into @; the snapshot must not catch it midway.
    _join_target_keyring_init(ctx)

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
