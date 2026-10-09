# Integration with archinstall (https://github.com/archlinux/archinstall,
# GPL-3.0-only, by the archinstall contributors): this module subclasses its
# Installer, patches private methods of it, and follows its guided installer
# (archinstall/scripts/guided.py). Attribution as omacom/omarchy-iso#202 asks.
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
        sanity_check(inst)
        inst.generate_key_files()                     # encrypted only
        inst.set_mirrors(handler, mirror_config, on_target=False)
        inst.minimal_installation(...)                # base + linux pacstrap
                                                      # (we unpack the root image
                                                      # and run install_base_delta
                                                      # instead; see below)
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
import os
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
from archinstall.lib.pacman.config import PacmanConfig
from archinstall.lib.models.users import User

from .ui import info

# The archinstall this adapter is written and tested against. luks_tuning and
# _filesystem_step_tweaks replace archinstall internals (Luks2's methods, the
# device handler's), and install_base_delta calls private Installer methods;
# none of that is a stable API. The ISO pins archinstall in its offline
# mirror, so another version means the ISO build picked up a new release:
# stop at startup and say so, before a replaced internal misbehaves in the
# middle of an install. OMARCHY_ARCHINSTALL_UNTESTED=1 runs anyway, which is
# how a new release gets tried.
TESTED_ARCHINSTALL = "4.4"


def check_archinstall_version(version: str | None = None) -> None:
    if version is None:
        from importlib.metadata import PackageNotFoundError, version as package_version
        try:
            version = package_version("archinstall")
        except PackageNotFoundError:
            version = "unknown"
    if version.split(".")[:2] == TESTED_ARCHINSTALL.split(".")[:2]:
        return
    message = (
        f"archinstall {version} is installed, but this installer is tested against "
        f"archinstall {TESTED_ARCHINSTALL}: it replaces archinstall internals that "
        f"change between releases (orchestrator/archinstall_adapter.py)"
    )
    if os.environ.get("OMARCHY_ARCHINSTALL_UNTESTED") == "1":
        info(f"› {message}; running anyway (OMARCHY_ARCHINSTALL_UNTESTED=1)")
        return
    raise RuntimeError(f"{message}. Set OMARCHY_ARCHINSTALL_UNTESTED=1 to try it anyway.")


check_archinstall_version()

from . import luks_tuning  # noqa: E402 - patches archinstall only after the check
luks_tuning.apply()


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


@contextmanager
def _filesystem_step_tweaks(throwaway_root_fs: bool) -> Iterator[None]:
    """Time the pieces of archinstall's filesystem step, and keep mkfs.btrfs
    from discarding the whole device when the filesystem it makes is thrown
    away.

    The step is one number in the log (2.0 s in a VM, 4.4 s on an XPS 16,
    22.2 s on a ThinkPad E14), which cannot say which piece cost what, so
    every piece logs its own [step] line.

    mkfs.btrfs TRIMs the entire device before it formats (mkfs.btrfs(8), -K
    to skip). On a virtual disk that is instant; on a 1 TB laptop SSD behind
    dm-crypt it takes seconds, and much longer on a DRAM-less drive. When a
    root image is about to be written over that filesystem the TRIM only
    delays the install: the image lands two seconds later, the installed
    system keeps fstrim.timer enabled, and btrfs discards freed space on its
    own. Nothing else about the step changes.

    Everything here is best effort. If archinstall moves one of these names
    the step runs exactly as before, untimed and with the TRIM."""
    try:
        import archinstall.lib.disk.device_handler as dh_module
        import archinstall.lib.disk.filesystem as fs_module
        from archinstall.lib.disk.luks import Luks2
        from archinstall.lib.models.device import FilesystemType
        from .phases_impl import _time_step
        device_handler = dh_module.device_handler
    except Exception as exc:  # pragma: no cover - depends on the archinstall release
        info(f"› filesystem step runs untimed ({exc})")
        yield
        return

    instance_patches: list[str] = []
    luks_originals: dict[str, object] = {}
    settle = {"calls": 0, "seconds": 0.0}
    settle_originals: dict[object, object] = {}

    def timed(original, label):
        def wrapper(*args, **kwargs):
            with _time_step(label):
                return original(*args, **kwargs)
        return wrapper

    def format_wrapper(original):
        takes_options = _method_accepts(original, "additional_parted_options")

        def wrapper(fs_type, path, additional_parted_options=None, *args, **kwargs):
            options = list(additional_parted_options or [])
            if throwaway_root_fs and takes_options and fs_type == FilesystemType.BTRFS and "-K" not in options:
                options.append("-K")
            label = f"FS.mkfs.{getattr(fs_type, 'value', fs_type)}" + (" -K (no whole-device TRIM)" if "-K" in options else "")
            with _time_step(label):
                if takes_options:
                    return original(fs_type, path, options, *args, **kwargs)
                return original(fs_type, path, *args, **kwargs)
        return wrapper

    def luks_wrapper(function, label):
        def wrapper(self, *args, **kwargs):
            with _time_step(label):
                return function(self, *args, **kwargs)
        return wrapper

    def settle_wrapper(original):
        def wrapper(*args, **kwargs):
            started = time.monotonic()
            try:
                return original(*args, **kwargs)
            finally:
                settle["calls"] += 1
                settle["seconds"] += time.monotonic() - started
        return wrapper

    try:
        for name, label in (("partition", "FS.partition"), ("create_btrfs_volumes", "FS.create_btrfs_subvolumes")):
            original = getattr(device_handler, name, None)
            if callable(original):
                setattr(device_handler, name, timed(original, label))  # instance attribute shadows the method
                instance_patches.append(name)
        original_format = getattr(device_handler, "format", None)
        if callable(original_format):
            device_handler.format = format_wrapper(original_format)
            instance_patches.append("format")
        for name, label in (("encrypt", "FS.luksFormat"), ("unlock", "FS.luks_open")):
            function = Luks2.__dict__.get(name)
            if callable(function):
                luks_originals[name] = function
                setattr(Luks2, name, luks_wrapper(function, label))
        for module in (dh_module, fs_module):
            if callable(getattr(module, "udev_sync", None)):
                settle_originals[module] = module.udev_sync
                module.udev_sync = settle_wrapper(module.udev_sync)
        yield
    finally:
        for name in instance_patches:
            try:
                delattr(device_handler, name)
            except AttributeError:
                pass
        for name, function in luks_originals.items():
            setattr(Luks2, name, function)
        for module, function in settle_originals.items():
            module.udev_sync = function
        if settle["seconds"] >= 0.05:
            info(f"[step] FS.udevadm settle ({settle['calls']} calls): {settle['seconds']:.6f}s")


def _write_locale_conf_for_prebuilt(installer, locale_config) -> None:
    """Write /etc/locale.conf when archinstall's set_locale declined to.

    set_locale finds the chosen locale by matching a *commented* line in
    /etc/locale.gen (`re.compile(rf'#{lang}(\\.{encoding})?{modifier} {encoding}')`),
    uncomments it, runs locale-gen, and only then writes locale.conf. The
    root image ships en_US.UTF-8 already uncommented and already compiled
    (build-root-image.sh does that to save 0.77 s of locale-gen at install), so
    the match fails, set_locale logs "Invalid locale" and returns False, and
    locale.conf is never written. The installed system then falls back to
    systemd's LANG=C.UTF-8 instead of the locale it just generated.

    So: if the locale is present and *enabled* in locale.gen, the image already
    did set_locale's work and only the last line is missing. Anything else is a
    genuine failure and is left alone for the caller's error to stand.
    """
    target = Path(installer.target)
    locale_gen = target / "etc" / "locale.gen"
    if not locale_gen.is_file():
        return
    lang, encoding = locale_config.sys_lang, locale_config.sys_enc
    # sys_lang may or may not already carry the encoding ("en_US" vs
    # "en_US.UTF-8"); accept the entry either way, as set_locale's regex does.
    wanted = {f"{lang} {encoding}", f"{lang}.{encoding} {encoding}"}
    enabled = next(
        (line.split()[0] for line in locale_gen.read_text().splitlines()
         if not line.startswith("#") and line.strip() in wanted),
        None,
    )
    if not enabled:
        return
    (target / "etc" / "locale.conf").write_text(f"LANG={enabled}\n")
    info(f"› locale {enabled} is already compiled into the image; wrote locale.conf directly")


def perform_filesystem_operations(arch_config: ArchConfig, throwaway_root_fs: bool = False) -> None:
    """Partition, format, encrypt. archinstall's FilesystemHandler is its own
    object (separate from Installer) so we run it before opening the
    Installer context manager.

    parted's partition-table commit races udev: the disk wipe and the first
    BLKPG partition registration trigger probes that briefly hold the disk
    open, and the kernel then refuses to register the remaining partitions
    (_ped.IOException: "Partition(s) ... have been written, but we have been
    unable to inform the kernel"). The table is written correctly when that
    happens — only the kernel's view is stale — so settle udev and redo the
    operations. The wipe/partition/format sequence is idempotent."""
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

    attempts = 3
    with _filesystem_step_tweaks(throwaway_root_fs):
        for attempt in range(1, attempts + 1):
            udev_sync()
            try:
                handler.perform_filesystem_operations(**fs_kwargs)
                return
            except Exception as exc:
                if attempt == attempts or "unable to inform the kernel" not in str(exc):
                    raise
                info(f"› partition commit lost a udev race (attempt {attempt}/{attempts}); retrying")


class OmarchyInstaller(Installer):
    """archinstall's Installer, without its request to report our failures.

    Installer.__exit__ answers any exception inside `with Installer(...)` with
    "Please submit this issue (and file) to
    https://github.com/archlinux/archinstall/issues". Most of what runs in that
    block here is Omarchy's own install (the root image, Limine, efibootmgr),
    so Omarchy's failures would be filed with archinstall
    (archlinux/archinstall#4773: an efibootmgr refusal in phases_impl). The
    phase runner reports a failure itself, with its own log; on the way out
    this keeps only archinstall's copy of its log to the install medium."""

    def __exit__(self, exc_type, exc_value, traceback):
        if exc_type is None:
            return super().__exit__(exc_type, exc_value, traceback)
        sync_log = getattr(self, "sync_log_to_install_medium", None)
        if sync_log is not None:
            sync_log()
        return None


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
    with OmarchyInstaller(
        mountpoint,
        arch_config.disk_config,
        kernels=arch_config.kernels,
        silent=silent,
    ) as installer:
        yield installer


def target_has_package(target: Path, name: str) -> bool:
    """Whether pacman's local db in the target records `name` as installed."""
    local_db = target / "var" / "lib" / "pacman" / "local"
    for entry in local_db.glob(f"{name}-*"):
        desc = entry / "desc"
        if not desc.is_file():
            continue
        lines = desc.read_text(errors="ignore").splitlines()
        try:
            if lines[lines.index("%NAME%") + 1] == name:
                return True
        except (ValueError, IndexError):
            continue
    return False


def install_base_delta(
    installer: Installer,
    arch_config: ArchConfig,
    *,
    hostname: str | None,
    locale_config,
) -> None:
    """Installer.minimal_installation for a target that already holds the root
    image: everything it does around its base pacstrap, with the pacstrap
    reduced to the base packages the image does not carry (the kernel and the
    CPU microcode).

    Mirrors archinstall 4.4's minimal_installation step for step so the target
    ends up as that call would leave it: filesystem/encryption preparation
    (which also decides the mkinitcpio hooks), microcode detection, pacman.conf
    handling, vconsole, hostname, locale, and the helper flags later Installer
    methods look at. LVM layouts are not supported by the image path."""
    disk_config = installer._disk_config
    if disk_config.lvm_config:
        raise RuntimeError("root image install does not support LVM layouts")

    # Each framework call below has its own [step] timer: the function takes
    # 0.8 s with no package to install, and the timers show where.
    from .phases_impl import _time_step

    with _time_step("DELTA.prepare_fs_and_encrypt"):
        for mod in disk_config.device_modifications:
            for part in mod.partitions:
                if part.fs_type is None:
                    continue
                installer._prepare_fs_type(part.fs_type, part.mountpoint)
                if part in installer._disk_encryption.partitions:
                    installer._prepare_encrypt()

    with _time_step("DELTA.microcode"):
        if ucode := installer._get_microcode():
            (installer.target / "boot" / ucode).unlink(missing_ok=True)
            installer._base_packages.append(ucode.stem)

    with _time_step("DELTA.pacman_conf"):
        mirror_config = arch_config.mirror_config
        pacman_conf = PacmanConfig(installer.target)
        pacman_conf.enable(mirror_config.optional_repositories if mirror_config else [])
        pacman_conf.apply()

    with _time_step("DELTA.vconsole"):
        if locale_config:
            installer.set_vconsole(locale_config)

    with _time_step("DELTA.package_delta"):
        delta = [pkg for pkg in installer._base_packages if not target_has_package(installer.target, pkg)]
        if delta:
            installer.pacman.strap(delta)
        installer._helper_flags["base-strapped"] = True

    with _time_step("DELTA.pacman_conf_persist"):
        pacman_conf.persist()
        if arch_config.pacman_config:
            pacman_conf.configure(arch_config.pacman_config)

    with _time_step("DELTA.fstrim"):
        if not installer._disable_fstrim:
            installer.enable_periodic_trim()

    with _time_step("DELTA.hostname"):
        if hostname:
            installer.set_hostname(hostname)

    with _time_step("DELTA.locale_and_keyboard"):
        if locale_config:
            if not installer.set_locale(locale_config):
                _write_locale_conf_for_prebuilt(installer, locale_config)
            installer.set_keyboard_language(locale_config.kb_layout)

    installer._helper_flags["base"] = True

    with _time_step("DELTA.post_base_install"):
        for function in installer.post_base_install:
            function(installer)


def setup_zram_swap(installer: Installer) -> None:
    """Installer.setup_swap without its pacman.strap('zram-generator'): the
    root image carries the package. Enables the zram unit and records that
    zram is on, as archinstall 4.4 does. Its /etc zram-generator.conf is not
    reproduced: omarchy-settings ships the tuning as a vendor drop-in and the
    orchestrator removed archinstall's copy anyway."""
    if not target_has_package(installer.target, "zram-generator"):
        installer.pacman.strap("zram-generator")
    installer.enable_service("systemd-zram-setup@zram0.service")
    installer._zram_enabled = True


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


def sanity_check(installer) -> None:
    """Archinstall 4.5 removed offline; retain it for older releases."""
    options = {"skip_ntp": True, "skip_wkd": True}
    if _method_accepts(installer.sanity_check, "offline"):
        options["offline"] = True
    installer.sanity_check(**options)


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

    # The application installers strap their package sets unconditionally.
    # The root image already carries those (PipeWire and friends) and the
    # offline mirror no longer does, and pacstrap --needed still has to
    # resolve every target before it can skip it. Strap only what the target
    # lacks (the hardware-detected firmware), through the installer instance
    # the handlers call into.
    original_strap = installer.add_additional_packages

    def strap_missing(packages: str | list[str]) -> None:
        if isinstance(packages, str):
            packages = [packages]
        missing = [pkg for pkg in packages if not target_has_package(installer.target, pkg)]
        if missing:
            original_strap(missing)

    installer.add_additional_packages = strap_missing  # type: ignore[method-assign]
    try:
        if _method_accepts_users(install_applications_method):
            install_applications_method(installer, app_config, users)
        else:
            install_applications_method(installer, app_config)
    finally:
        del installer.add_additional_packages


def root_user(arch_config: ArchConfig) -> User | None:
    auth = arch_config.auth_config
    if not auth or not auth.root_enc_password:
        return None
    return User("root", auth.root_enc_password, False)
