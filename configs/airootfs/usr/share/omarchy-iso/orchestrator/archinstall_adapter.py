"""Thin compatibility wall around the archinstall Python library.

ONLY this module imports from archinstall. Everything else uses these helpers.
If archinstall's API churns, the blast radius is contained here.

Tested against archinstall 4.4 (Python 3.14).

The canonical call sequence (mirrored from archinstall.scripts.guided.py) is:

    FilesystemHandler(disk_config).perform_filesystem_operations()
    with Installer(mountpoint, disk_config, kernels=, silent=) as inst:
        # guided.py:84-85 SKIPS this for DiskLayoutType.Pre_mount — pre-mounted
        # configs do their own mounting before the Installer context opens.
        if disk_config.config_type != DiskLayoutType.Pre_mount:
            inst.mount_ordered_layout()
        inst.sanity_check(offline=, skip_ntp=, skip_wkd=)
        inst.generate_key_files()                     # encrypted only
        inst.set_mirrors(handler, mirror_config, on_target=False)
        inst.minimal_installation(...)                # base + linux pacstrap
        inst.set_mirrors(handler, mirror_config, on_target=True)
        inst.setup_swap(algo=...)
        inst.create_users(users)
        inst.add_additional_packages(packages)
        inst.set_timezone(tz)
        inst.activate_time_synchronization()
        inst.set_user_password(root_user)
        inst.enable_service(services)
        inst.genfstab()

Our orchestrator installs Omarchy's Limine files directly instead of invoking
archinstall's bootloader helper, so EFI paths and efibootmgr labels are ours
from the start.
"""

from __future__ import annotations

import importlib
import subprocess
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

# Imports are top-level so a missing/incompatible archinstall surfaces at
# orchestrator startup, not deep inside a phase.
from archinstall.lib.args import ArchConfig, ArchConfigHandler
from archinstall.lib.authentication.authentication_handler import AuthenticationHandler
from archinstall.lib.disk.filesystem import FilesystemHandler
from archinstall.lib.disk.utils import get_parent_device_path, get_unique_path_for_device, udev_sync
from archinstall.lib.hardware import SysInfo
from archinstall.lib.installer import Installer
from archinstall.lib.mirror.mirror_handler import MirrorListHandler
from archinstall.lib.models import Bootloader
from archinstall.lib.models.device import DiskLayoutType, EncryptionType
from archinstall.lib.models.users import User

from .ui import info


def load_arch_config(config_path: Path, creds_path: Path) -> ArchConfigHandler:
    """Build an ArchConfigHandler from on-disk JSON.

    archinstall's ArchConfigHandler reads --config / --creds from sys.argv
    via argparse at construction time (lib/args.py:_parse_args). It does
    NOT consult env vars for these paths. We can't pass them on our real
    argv because the wrapper strips them before exec'ing Python (so other
    archinstall arg-parsing code doesn't choke on our flags), so we hand
    archinstall a synthetic argv just for this call.
    """
    import sys
    saved_argv = sys.argv
    sys.argv = [
        saved_argv[0] if saved_argv else "omarchy-iso-install",
        "--config", str(config_path),
        "--creds", str(creds_path),
    ]
    try:
        return ArchConfigHandler()
    finally:
        sys.argv = saved_argv


def make_mirror_handler(offline: bool = True) -> MirrorListHandler:
    return MirrorListHandler(offline=offline, verbose=False)


def perform_filesystem_operations(arch_config: ArchConfig) -> None:
    """Partition, format, encrypt. archinstall's FilesystemHandler is its own
    object (separate from Installer) so we run it before opening the
    Installer context manager.

    Two of archinstall's failure modes surface here and both are handled:

    1. The partition-table commit races udev (the disk wipe and the first BLKPG
       partition registration trigger probes that briefly hold the disk open, and
       the kernel then refuses to register the remaining partitions). The table
       is written correctly when that happens — only the kernel's view is stale
       — so settle udev and redo the operations.

    2. Closing the freshly-created LUKS mapping races a lingering reference and
       fails with "Device or resource busy" / "Device root is still in use"
       (issue #130). It is intermittent and self-clears once udev settles, so
       force-close strays and retry. The wipe/partition/format sequence is
       idempotent, so retrying is safe.
    """
    if not arch_config.disk_config:
        raise RuntimeError("disk_config missing from arch config")

    handler = FilesystemHandler(arch_config.disk_config)

    # archinstall's perform_filesystem_operations defaults to a ~4.5s
    # "5...4...3...2...1" countdown (FilesystemHandler._final_warning) before it
    # wipes the disk. That warning is meant for its interactive TUI; in our
    # orchestrated install it renders nowhere and just sleeps. Suppress it when
    # the running archinstall still takes the flag — newer releases dropped both
    # the countdown and the parameter, so only pass it when it's accepted.
    fs_kwargs = (
        {"show_countdown": False}
        if _method_accepts(handler.perform_filesystem_operations, "show_countdown")
        else {}
    )

    # issue #115: archinstall's device re-scan (DeviceHandler.get_btrfs_info)
    # tries to mount the raw LUKS partition as btrfs, which fails with
    # "wrong fs type, bad superblock". Guard that scan for the duration of the
    # partitioning so crypto_LUKS partitions are never mounted as btrfs.
    _restore_get_btrfs_info = _guard_get_btrfs_info()

    attempts = 3
    try:
        for attempt in range(1, attempts + 1):
            udev_sync()
            try:
                handler.perform_filesystem_operations(**fs_kwargs)
                return
            except Exception as exc:
                exc_str = str(exc)
                if attempt == attempts:
                    raise
                if "unable to inform the kernel" in exc_str:
                    info(f"› partition commit lost a udev race (attempt {attempt}/{attempts}); retrying")
                elif _is_luks_close_race(exc_str):
                    _close_stray_crypt_mappings()
                    info(f"› LUKS close lost a device race (attempt {attempt}/{attempts}); retrying")
                else:
                    raise
    finally:
        if _restore_get_btrfs_info is not None:
            _restore_get_btrfs_info()


def _is_luks_close_race(message: str) -> bool:
    """Distinguish a transient LUKS-close race (issue #130) from other errors.

    The failure archinstall surfaces is a `cryptsetup close` SysCallError whose
    text mentions a busy device + a LUKS mapping name. We must not retry on
    arbitrary errors (idempotent or not, retrying a genuine failure just loops);
    scope the retry to the specific "still in use / Device or resource busy"
    message that accompanies the intermittent close race.
    """
    return any(
        token in message
        for token in ("Device or resource busy", "Device root is still in use")
    )


def _close_stray_crypt_mappings() -> None:
    """Force-close any left-over LUKS mapping still referencing the new layout.

    The racy close in issue #130 leaves a mapping with "Open count: 0" that still
    refuses to close once but closes on the second attempt after udev settles.
    Iterate every live crypt device and close it. This is deliberately a local
    loop rather than the full cleanup script: we are mid-install after
    re-partitioning, and only strays from the previous attempt should be dropped.
    """
    lsblk = subprocess.run(
        ["lsblk", "-rnpo", "PATH,TYPE"], check=False, capture_output=True, text=True
    )
    for line in lsblk.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == "crypt" and parts[0].startswith("/dev/"):
            subprocess.run(
                ["cryptsetup", "close", parts[0]],
                check=False, capture_output=True,
            )
    udev_sync()
    time.sleep(2)


def _guard_get_btrfs_info():
    """Temporarily patch archinstall's btrfs-info scan to skip crypto_LUKS.

    issue #115: after we format the LUKS mapper as btrfs, archinstall's
    DeviceHandler re-scans devices and its get_btrfs_info() tries to mount the
    *raw* LUKS partition as btrfs, dying on "wrong fs type, bad superblock".
    The scan has no business opening a LUKS container, so we wrap the class
    method to return an empty info dict for crypto_LUKS devices and defer to the
    original otherwise.

    archinstall's internals move between versions, so this is a best-effort,
    scoped patch: if the class/method cannot be located we leave archinstall
    alone (None disables the patch and restores nothing) rather than crash the
    install on a symbol rename.
    """
    try:
        from archinstall.lib.disk.device_handler import DeviceHandler
    except Exception:
        return None

    original = getattr(DeviceHandler, "get_btrfs_info", None)
    if not callable(original):
        return None

    def _wrapped(self, device, *args, **kwargs):
        if _device_is_luks(device):
            return {}
        return original(self, device, *args, **kwargs)

    setattr(DeviceHandler, "get_btrfs_info", _wrapped)

    def _restore():
        setattr(DeviceHandler, "get_btrfs_info", original)

    return _restore


def _device_is_luks(device) -> bool:
    """True if `device` (a path or a device-like object) is a LUKS container."""
    path = device if isinstance(device, str) else None
    if path is None:
        # archinstall passes devices around as objects (BlockDevice / _Device);
        # accept anything carrying a path/device_name attribute.
        path = getattr(device, "path", None) or getattr(device, "device_name", None)
    if not path:
        return False
    proc = subprocess.run(
        ["lsblk", "-ndo", "TYPE", str(path)],
        check=False, capture_output=True, text=True,
    )
    return "crypto_LUKS" in proc.stdout or "crypt" in proc.stdout


@contextmanager
def open_installer(
    arch_config: ArchConfig,
    mountpoint: Path,
    silent: bool = True,
) -> Iterator[Installer]:
    """Yield an open Installer; ensures __exit__ runs even on exception so
    /mnt is left clean for a retry."""
    if not arch_config.disk_config:
        raise RuntimeError("disk_config missing from arch config")
    with Installer(
        mountpoint,
        arch_config.disk_config,
        kernels=arch_config.kernels,
        silent=silent,
    ) as installer:
        yield installer


def is_encrypted(arch_config: ArchConfig) -> bool:
    disk = arch_config.disk_config
    if not disk or not disk.disk_encryption:
        return False
    return disk.disk_encryption.encryption_type != EncryptionType.NO_ENCRYPTION


def is_pre_mount(arch_config: ArchConfig) -> bool:
    return bool(
        arch_config.disk_config
        and arch_config.disk_config.config_type == DiskLayoutType.Pre_mount
    )


def bootloader_enabled(arch_config: ArchConfig) -> bool:
    bl = arch_config.bootloader_config
    return bool(bl and bl.bootloader != Bootloader.NO_BOOTLOADER)


def is_limine(arch_config: ArchConfig) -> bool:
    bl = arch_config.bootloader_config
    return bool(bl and bl.bootloader == Bootloader.Limine)


def has_uefi() -> bool:
    return SysInfo.has_uefi()


def parent_device_path(dev_path: Path) -> Path:
    return get_parent_device_path(dev_path)


def unique_device_path(dev_path: Path) -> Path | None:
    return get_unique_path_for_device(dev_path)


def _application_handler():
    """Return archinstall's application handler across archinstall versions."""
    module = importlib.import_module("archinstall.lib.applications.application_handler")
    handler = getattr(module, "application_handler", None)
    if handler is not None and callable(getattr(handler, "install_applications", None)):
        return handler

    handler_class = getattr(module, "ApplicationHandler", None)
    if handler_class is None:
        raise RuntimeError("archinstall application handler is unavailable")
    try:
        handler = handler_class()
    except TypeError as exc:
        raise RuntimeError("archinstall ApplicationHandler cannot be constructed") from exc
    if not callable(getattr(handler, "install_applications", None)):
        raise RuntimeError("archinstall ApplicationHandler has no install_applications method")
    return handler


def _method_accepts(method, name: str) -> bool:
    """Return whether a bound archinstall method accepts a named argument.

    Do not use inspect.signature here: Python 3.14 may evaluate archinstall's
    lazy annotations, and some archinstall releases annotate with names that are
    only imported under TYPE_CHECKING.
    """
    fn = getattr(method, "__func__", method)
    code = getattr(fn, "__code__", None)
    if code is None:
        return True

    positional = code.co_varnames[:code.co_argcount]
    kwonly = code.co_varnames[code.co_argcount:code.co_argcount + code.co_kwonlyargcount]
    return name in (*positional, *kwonly)


def _method_accepts_users(method) -> bool:
    return _method_accepts(method, "users")


def install_applications(installer: Installer, arch_config: ArchConfig) -> None:
    """Install archinstall application selections such as PipeWire audio.

    The configurator still writes archinstall's audio_config. We own phase
    ordering now, but should not silently drop archinstall's hardware-aware
    application installers (SOF/ALSA firmware detection, PipeWire packages,
    Bluetooth selections, etc.).
    """
    app_config = arch_config.app_config
    if not app_config:
        return

    users = arch_config.auth_config.users if arch_config.auth_config else None
    handler = _application_handler()
    install_applications_method = handler.install_applications
    if _method_accepts_users(install_applications_method):
        install_applications_method(installer, app_config, users)
    else:
        install_applications_method(installer, app_config)


def root_user(arch_config: ArchConfig) -> User | None:
    auth = arch_config.auth_config
    if not auth or not auth.root_enc_password:
        return None
    return User("root", auth.root_enc_password, False)
