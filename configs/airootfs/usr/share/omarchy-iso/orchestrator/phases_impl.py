"""Concrete phase implementations.

Phase ordering (full-disk and protected/pre-mounted):

    prepare_live           → disk cleanup when wiping, load configurator
                             handlers (archinstall patch happens in the
                             wrapper before Python imports it)
    prepare_install_target → verify pre-mounted target/ESP when the JSON uses
                             pre_mounted_config; no-op for full-disk installs
    arch_install_system    → one archinstall flow for partition/mount-or-use,
                             system payload (prebuilt rootfs image restore, or
                             legacy pacstrap from the full mirror), Limine
                             setup, useradd, fstab
    configure_hibernation  → root-owned swap/resume drop-ins
    run_system_finalizer   → arch-chroot root omarchy-apply-system, including Snapper
    finalize_limine_boot   → final Limine config/UKI build after hardware drop-ins
    run_chroot_finalizer   → arch-chroot -u user omarchy-provision-user
    configure_login        → sddm state + encrypted-install autologin
    configure_ssh_access   → authorized_keys for autoinstall; no-op otherwise
    configure_tailscale    → tailnet join staged for first boot; no-op otherwise
    validate_boot          → assert UKI / limine.conf / kernel cmdline are sane
"""

from __future__ import annotations

import hashlib
import os
import re
import shlex
import shutil
import signal
import subprocess
import textwrap
import time
from dataclasses import replace
from pathlib import Path

from . import archinstall_adapter as arch
from .context import InstallContext
from .keyboard import configure_keyboard
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


# Packages installed BEFORE useradd. The selected omarchy-settings package and
# omarchy-nvim populate /etc/skel so the user's home gets seeded correctly, and
# omarchy-settings also ships the limine/snapper configs. Target-side setup
# commands are installed later by the selected Omarchy runtime package and
# executed in chroot.
EARLY_BOOTSTRAP_BASE_PACKAGES = [
    "base-devel",
    "git",
    "limine",
    "efibootmgr",
    "omarchy-keyring",
]

# Install LuaRocks before omarchy-nvim pulls in lua51-lpeg. Arch's lua-luarocks
# post_install script tries to rebuild manifests for existing rocks trees before
# the unversioned luarocks-admin command exists if both arrive in the wrong
# transaction order. Splitting this transaction avoids the harmless but noisy
# "luarocks-admin: command not found" line during ISO installs.
EARLY_LUAROCKS_PACKAGES = [
    "lua51",
    "luarocks",
]


def _early_bootstrap_packages() -> list[str]:
    return [*EARLY_BOOTSTRAP_BASE_PACKAGES, _omarchy_settings_package()]


def _early_user_seed_packages() -> list[str]:
    return [_omarchy_nvim_package()]


def _early_packages() -> list[str]:
    return [
        *_early_bootstrap_packages(),
        *EARLY_LUAROCKS_PACKAGES,
        *_early_user_seed_packages(),
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
# One shipped artifact decides how the system lands on disk:
#
#   _install_via_rootfs_image  the ISO carries a prebuilt rootfs squashfs
#                              (build_rootfs_image in builder/build-iso.sh):
#                              restore it with multithreaded unsquashfs, then
#                              reconcile the install-time conditionals (kernel,
#                              tailscale) against the pruned offline mirror.
#   _install_via_pacstrap      legacy flow (ISO built with
#                              OMARCHY_ROOTFS_IMAGE=0): reorders guided.py's
#                              perform_installation() so early Omarchy packages
#                              install before user creation and before our
#                              Omarchy-owned Limine setup copies files from the
#                              target's limine package. Kept for at least one
#                              release as the fallback.
# ─────────────────────────────────────────────────────────────────────────────

ROOTFS_IMAGE_PATH = Path("/var/cache/omarchy/rootfs/omarchy-rootfs.sfs")
ROOTFS_IMAGE_BUILD_MARKER = Path("/usr/share/omarchy-iso/rootfs-image-build")
# linux is baked into the image; linux-t2 is the only other kernel the pruned
# shipped mirror guarantees (build-iso.sh conditional_targets). Anything else
# would fail mid-install in _reconcile_target_kernel, so the config assert
# rejects it before the disk is touched.
ROOTFS_IMAGE_SUPPORTED_KERNELS = {"linux", "linux-t2"}
# What minimal_installation adds on the legacy path when the live session runs
# a screen reader (archinstall's own list is private). build-iso.sh's
# conditional_targets must carry the same names so the pruned mirror can serve
# them at install time.
ACCESSIBILITY_PACKAGES = ["brltty", "espeakup", "alsa-utils"]
# Filesystems whose userspace archinstall's legacy minimal_installation would
# have pacstrapped for the config (FilesystemType.installation_pkg: xfsprogs,
# f2fs-tools) but that neither the baked image nor the pruned mirror carries
# (btrfs-progs alone is baked, via snapper). Such a config would format fine
# and boot without fsck/repair tools, so the config assert rejects it before
# the disk is touched — same contract as ROOTFS_IMAGE_SUPPORTED_KERNELS.
ROOTFS_IMAGE_UNSUPPORTED_FS_TYPES = {"xfs", "f2fs"}
RESTORE_PROGRESS_PATH = Path("/run/omarchy-install/restore-progress")


def _configured_kernels(config) -> list[str]:
    """The configured kernel set with archinstall's default. The contract pair
    _assert_rootfs_image_supported_config / _reconcile_target_kernel must
    parse config.kernels identically — the assert's pre-format guarantee
    holds only as long as both go through here."""
    return list(getattr(config, "kernels", None) or ["linux"])


def _is_rootfs_image_install() -> bool:
    """Build-time variant decision, not runtime file presence: an image ISO
    whose image file is missing must abort (see _assert_rootfs_image_available),
    never quietly fall back to pacstrapping against the pruned mirror."""
    return ROOTFS_IMAGE_BUILD_MARKER.exists()


def _assert_rootfs_image_available() -> None:
    if not ROOTFS_IMAGE_PATH.exists():
        raise RuntimeError(
            f"this ISO was built around a rootfs image but {ROOTFS_IMAGE_PATH} "
            "is missing; refusing to touch the disk (the pruned mirror cannot "
            "feed a pacstrap fallback)"
        )


def prepare_install_target(ctx: InstallContext) -> None:
    if ctx.is_protected:
        verify_protected_mounts(ctx)


def arch_install_system(ctx: InstallContext) -> None:
    """Install the target system from the archinstall JSON.

    The phase sequence is the same for full-disk and protected installs. The
    JSON decides whether archinstall should create/mount a disk layout or use
    a pre-mounted target, and Omarchy derives boot/fstab details from that same
    input. The prologue and the finishers are shared; only the way packages
    land on disk differs between the image-restore and pacstrap paths.
    """
    handler = ctx.state["arch_config_handler"]
    mirror_handler = ctx.state["mirror_handler"]
    config = handler.config
    pre_mounted = arch.is_pre_mount(config)

    # Both checks must precede any disk write: a broken or unsupported image
    # install has no pacstrap fallback to save it after formatting.
    use_rootfs_image = _is_rootfs_image_install()
    if use_rootfs_image:
        _assert_rootfs_image_available()
        _assert_rootfs_image_supported_config(config)

    if not pre_mounted:
        info("› partitioning + formatting + encrypting")
        arch.perform_filesystem_operations(config)

    info("› opening installer context")
    with arch.open_installer(config, ctx.target, silent=True) as installer:
        if not pre_mounted:
            installer.mount_ordered_layout()

        installer.sanity_check(
            offline=True,
            skip_ntp=True,
            skip_wkd=True,
        )

        if config.mirror_config:
            installer.set_mirrors(mirror_handler, config.mirror_config, on_target=False)

        if use_rootfs_image:
            _install_via_rootfs_image(ctx, installer, config, mirror_handler)
        else:
            _install_via_pacstrap(ctx, installer, config, mirror_handler)

        # Standard arch finishers.
        if config.timezone:
            installer.set_timezone(config.timezone)
        if config.ntp:
            installer.activate_time_synchronization()
        # guided.py enables this post-install, not minimal_installation, so
        # BOTH paths need it here (packages: baked set via minimal_installation
        # on legacy, pruned-mirror install in _rootfs_image_configure on image).
        if arch.accessibility_tools_in_use():
            installer.enable_espeakup()
        if root := arch.root_user(config):
            installer.set_user_password(root)

        if pre_mounted:
            _write_pre_mounted_fstab(ctx)
        else:
            installer.genfstab()


def _generate_key_files_if_needed(installer, config) -> None:
    """Key files (and the crypttab entries referencing them) are only wanted
    when this install created the encrypted layout itself; each install path
    calls this at its own deliberately different point (see the ordering
    comment in _install_via_rootfs_image)."""
    if not arch.is_pre_mount(config) and arch.is_encrypted(config):
        installer.generate_key_files()


def _install_via_pacstrap(ctx: InstallContext, installer, config, mirror_handler) -> None:
    """Legacy package-by-package install from the full offline mirror."""
    _generate_key_files_if_needed(installer, config)
    _mount_offline_package_cache(ctx)
    _mask_mkinitcpio_pacman_hooks(ctx)
    try:
        info("› installing base system (mkinitcpio deferred to final Limine UKI build)")
        # An empty kb_layout makes archinstall's set_keyboard_language skip
        # booting the target in a container just to run localectl; the
        # keymap is configured offline right after instead.
        kb_layout = config.locale_config.kb_layout if config.locale_config else ""
        installer.minimal_installation(
            optional_repositories=(
                config.mirror_config.optional_repositories
                if config.mirror_config else []
            ),
            mkinitcpio=False,
            hostname=config.hostname,
            locale_config=(
                replace(config.locale_config, kb_layout="")
                if config.locale_config else None
            ),
            pacman_config=config.pacman_config,
        )

        if not configure_keyboard(installer.target, kb_layout):
            error(f"Invalid keyboard language specified: {kb_layout}")

        if config.mirror_config:
            installer.set_mirrors(mirror_handler, config.mirror_config, on_target=True)

        if config.swap and config.swap.enabled:
            installer.setup_swap(algo=config.swap.algorithm)
            _drop_archinstall_zram_conf(ctx)

        _install_early_packages(installer)
        _configure_limine_boot(ctx, installer, config)

        info("› creating user (with /etc/skel populated)")
        if config.auth_config and config.auth_config.users:
            installer.create_users(config.auth_config.users)

        if config.app_config:
            info("› installing archinstall application selections")
            arch.install_applications(installer, config)

        info("› installing Omarchy runtime + omarchy-base.packages")
        installer.add_additional_packages(_runtime_package_list(ctx))

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


def _install_via_rootfs_image(ctx: InstallContext, installer, config, mirror_handler) -> None:
    """Restore the prebuilt rootfs image, then reconcile install-time
    conditionals.

    The image is the legacy flow's package end state (built by
    build_rootfs_image with the same DEFERRED_BOOT_HOOKS masked, locale baked,
    machine identity scrubbed), so every phase after this one is unchanged.

    Ordering constraints:
      - restore BEFORE _mount_offline_package_cache: unsquashfs -f would write
        the image's empty var/cache/pacman/pkg through the bind onto the
        mirror.
      - kernel reconcile BEFORE _configure_limine_boot so the boot config and
        every later phase see the final kernel set.

    Residual package work goes through installer.add_additional_packages
    (pacstrap semantics: LIVE pacman.conf + --root). The restored target's own
    /etc/pacman.conf is the stock pacman default with no [offline] repo, and
    the mirror path does not exist inside the chroot, so `arch-chroot pacman
    -S` cannot resolve anything here — only _prepare_target_setup later gives
    the chroot that view (and it resyncs the target db then, see
    ctx.state["target_db_synced"]).
    """
    _restore_rootfs_image(ctx)

    # After the restore, never before: generate_key_files appends non-root
    # volumes to the target's /etc/crypttab, which the filesystem package owns,
    # so unsquashfs -f would overwrite it (pacstrap preserves it as a backup=
    # file, hence the legacy path has no such constraint).
    _generate_key_files_if_needed(installer, config)

    info("› writing per-machine identity")
    subprocess.run(["systemd-machine-id-setup", f"--root={ctx.target}"], check=True)
    # Backgrounded: SigLevel = Never means nothing READS the keyring during
    # the install, and the init is chroot-free, so there is no mount teardown
    # to race the chroots below. pacstrap -K WRITES the same gnupg dir though
    # (it runs its own pacman-key --init), so _install_target_packages joins
    # the init before any pacstrap-semantics install. Killed and joined on
    # every exit path so a failure cannot leak the process, and the original
    # error always wins over a keyring one — "every exit path" includes a
    # dashboard stop because main() turns SIGTERM into an exception (the
    # detached init sits outside the process group the dashboard kills).
    try:
        _start_target_keyring_init(ctx)
        _rootfs_image_configure(ctx, installer, config, mirror_handler)
        _await_target_keyring_init(ctx, raise_on_error=True)
    except BaseException:
        _kill_target_keyring_init(ctx)
        _await_target_keyring_init(ctx, raise_on_error=False)
        raise


def _rootfs_image_configure(ctx: InstallContext, installer, config, mirror_handler) -> None:
    # Config side-effects minimal_installation used to perform. Locale is
    # baked (en_US.UTF-8 in locale.gen + locale.conf at build time);
    # hostname is ours to write. archinstall's application handler
    # (PipeWire) is intentionally NOT invoked: its package set is baked
    # via builder/rootfs-extra.packages, and every other application
    # selection is rejected up front by _assert_rootfs_image_supported_config
    # — if a future archinstall handler grows per-user side effects, they
    # belong in omarchy-provision-user, not here.
    _write_target_hostname(ctx, config)
    _ensure_target_locale(ctx, config)

    # Same contract as the legacy path: an empty kb_layout skips
    # archinstall's localectl-in-container dance; the keymap is configured
    # offline right after.
    kb_layout = config.locale_config.kb_layout if config.locale_config else ""
    if not configure_keyboard(installer.target, kb_layout):
        error(f"Invalid keyboard language specified: {kb_layout}")

    if config.mirror_config:
        installer.set_mirrors(mirror_handler, config.mirror_config, on_target=True)

    # No setup_swap: zram-generator is baked and omarchy-settings ships the
    # vendor drop-in (see _drop_archinstall_zram_conf for why an /etc copy
    # decides nothing). Deliberate behavior change vs the legacy path: a
    # config with swap.enabled=false still gets zram.
    #
    # config.pacman_config is likewise deliberately ignored: it only tuned
    # ParallelDownloads/repo toggles in the target's pacman.conf, which is
    # meaningless offline and overwritten by _prepare_target_setup (and later
    # by omarchy-apply-system) on every install anyway.

    # archinstall gates some Installer methods on flags its own
    # minimal_installation sets; the image restore IS our minimal
    # installation. Precedent: the ["bootloader"] poke in
    # _install_limine_omarchy. Both spellings are set because the key
    # changed names across archinstall releases.
    installer._helper_flags["base"] = True
    installer._helper_flags["base-strapped"] = True

    _mount_offline_package_cache(ctx)
    _mask_mkinitcpio_pacman_hooks(ctx)
    try:
        _reconcile_target_kernel(ctx, installer, config)
        _configure_limine_boot(ctx, installer, config)

        info("› creating user (with /etc/skel populated)")
        if config.auth_config and config.auth_config.users:
            installer.create_users(config.auth_config.users)
            _enable_pipewire_pulse_for_users(ctx, config)

        # Conditional packages are bundled in the pruned mirror and must be
        # installed here, while it is still bind-mounted — tailscale not in
        # the phase that configures the join. One batched call: each install
        # is a full pacstrap run with its own -Sy rewrite of the target db.
        packages = []
        if ctx.tailscale_authkey_path is not None:
            info("› installing tailscale (auth key staged for first boot)")
            packages.append("tailscale")
        packages += _accessibility_packages()
        if packages:
            _install_target_packages(ctx, installer, packages)
    finally:
        _unmask_mkinitcpio_pacman_hooks(ctx)
        _unmount_offline_package_cache(ctx)


def _accessibility_packages() -> list[str]:
    """The legacy path gets these from minimal_installation, which extends its
    base set when the live session runs a screen reader (the accessibility=on
    boot entry). The image bakes none of them, so they ride the conditional
    package install from the pruned mirror; the shared finishers in
    arch_install_system enable espeakup on both paths."""
    if not arch.accessibility_tools_in_use():
        return []
    info(f"› installing accessibility stack ({' '.join(ACCESSIBILITY_PACKAGES)})")
    return list(ACCESSIBILITY_PACKAGES)


def _install_target_packages(ctx: InstallContext, installer, packages: list[str]) -> None:
    """Pacstrap-semantics install from the pruned mirror (LIVE pacman.conf +
    --root, see the _install_via_rootfs_image docstring). Owns the two
    obligations every such install carries: joining the background keyring
    init first (pacstrap -K writes the target's gnupg dir) and recording that
    pacstrap's implicit -Sy already rewrote the target's sync db."""
    _await_target_keyring_init(ctx)
    installer.add_additional_packages(packages)
    ctx.state["target_db_synced"] = True


def _assert_rootfs_image_supported_config(config) -> None:
    """Refuse loudly what the image path would otherwise silently ignore.

    The legacy path feeds app_config through archinstall's application
    handler and optional_repositories through minimal_installation. The image
    bakes PipeWire and nothing else, and the pruned mirror cannot supply
    packages for other selections afterward — an autoinstall author must find
    out here, not weeks later on the installed machine. Such configs still
    work on an ISO built with OMARCHY_ROOTFS_IMAGE=0.
    """
    app_config = getattr(config, "app_config", None)

    audio = getattr(app_config, "audio_config", None) if app_config else None
    audio_kind = str(getattr(audio, "audio", "") or "").lower()
    if audio_kind and "pipewire" not in audio_kind and "no_audio" not in audio_kind:
        raise RuntimeError(
            f"rootfs-image install bakes PipeWire; audio selection {audio_kind!r} "
            "is not supported (build with OMARCHY_ROOTFS_IMAGE=0 for raw "
            "archinstall behavior)"
        )

    bluetooth = getattr(app_config, "bluetooth_config", None) if app_config else None
    if bluetooth is not None and bool(getattr(bluetooth, "enabled", True)):
        raise RuntimeError(
            "rootfs-image install does not support archinstall bluetooth_config "
            "(Omarchy configures bluetooth via omarchy-apply-system; build with "
            "OMARCHY_ROOTFS_IMAGE=0 for raw archinstall behavior)"
        )

    mirror_config = getattr(config, "mirror_config", None)
    optional = list(getattr(mirror_config, "optional_repositories", None) or [])
    if optional:
        raise RuntimeError(
            f"rootfs-image install cannot enable optional_repositories {optional!r}: "
            "minimal_installation does not write the target's pacman.conf on this "
            "path (build with OMARCHY_ROOTFS_IMAGE=0)"
        )

    disk_config = getattr(config, "disk_config", None)
    if getattr(disk_config, "lvm_config", None):
        raise RuntimeError(
            "rootfs-image install does not support lvm_config: the image bakes "
            "neither lvm2 nor its mkinitcpio hook, which minimal_installation "
            "would have added (build with OMARCHY_ROOTFS_IMAGE=0)"
        )

    fs_types = {
        part.fs_type.value.lower()
        for mod in (getattr(disk_config, "device_modifications", None) or [])
        for part in mod.partitions
        if part.fs_type is not None
    }
    unsupported_fs = sorted(fs_types & ROOTFS_IMAGE_UNSUPPORTED_FS_TYPES)
    if unsupported_fs:
        raise RuntimeError(
            f"rootfs-image install cannot provide filesystem tools for "
            f"{unsupported_fs!r}: minimal_installation would have installed "
            "them, but the image bakes only the btrfs userspace and the pruned "
            "mirror cannot supply the rest (build with OMARCHY_ROOTFS_IMAGE=0)"
        )

    unsupported = sorted(set(_configured_kernels(config)) - ROOTFS_IMAGE_SUPPORTED_KERNELS)
    if unsupported:
        raise RuntimeError(
            f"rootfs-image install cannot provide kernels {unsupported!r}: the "
            f"pruned mirror only carries {sorted(ROOTFS_IMAGE_SUPPORTED_KERNELS)} "
            "(build with OMARCHY_ROOTFS_IMAGE=0)"
        )


def _restore_rootfs_image(ctx: InstallContext) -> None:
    """unsquashfs the image over the mounted target layout.

    Runs as root, so ownership, modes, xattrs/capabilities and hardlinks are
    restored by default. POSIX ACLs are not: mksquashfs drops the
    system.posix_acl_* xattrs at build. Harmless today — the only ACL carriers
    on an installed system are tmpfiles.d a+ lines reapplied at boot — but a
    package that ships an ACL directly would lose it.
    -f because the mounted subvolume layout already
    created the top-level directories; writes pass through the mounted
    @home/@log/@pkg subvolumes, and the ESP mountpoint is untouched (the
    image's /boot is empty — boot hooks were masked at build).

    The exit code is checked hard: a partial restore must abort the install,
    not continue into user creation on a half-written root.
    """
    info("› restoring prebuilt system image (unsquashfs)")

    # A retried install in the same live session must not start from the
    # previous attempt's terminal "100".
    RESTORE_PROGRESS_PATH.unlink(missing_ok=True)
    _write_restore_progress("0")

    cmd = [
        "unsquashfs",
        "-f",
        "-p",
        str(_unsquashfs_processors()),
        "-d",
        str(ctx.target),
    ]
    if _unsquashfs_supports_percentage():
        proc = subprocess.Popen(
            [*cmd, "-percentage", str(ROOTFS_IMAGE_PATH)],
            stdout=subprocess.PIPE,
            text=True,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            value = line.strip()
            if value.isdigit():
                _write_restore_progress(value)
        returncode = proc.wait()
    else:
        returncode = subprocess.run(
            [*cmd, "-no-progress", str(ROOTFS_IMAGE_PATH)],
        ).returncode

    if returncode != 0:
        raise RuntimeError(
            f"unsquashfs failed with exit code {returncode}; refusing to "
            "continue on a partially restored target"
        )
    _write_restore_progress("100")


def _unsquashfs_processors() -> int:
    count = getattr(os, "process_cpu_count", os.cpu_count)()
    return count or 1


def _unsquashfs_supports_percentage() -> bool:
    """-percentage shipped with squashfs-tools 4.6 (2023); probe rather than
    assume so an older live environment degrades to the dashboard's time
    curve instead of failing the restore."""
    res = subprocess.run(
        ["unsquashfs", "-help"],
        capture_output=True,
        text=True,
        check=False,
    )
    return "-percentage" in f"{res.stdout}{res.stderr}"


def _write_restore_progress(value: str) -> None:
    """Latest restore percentage for the dashboard. Same atomic-replace dance
    as the phase state file so the twice-a-second reader never sees a torn
    write. Best effort — progress display must never fail an install."""
    try:
        RESTORE_PROGRESS_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = RESTORE_PROGRESS_PATH.with_name(f".{RESTORE_PROGRESS_PATH.name}.tmp")
        tmp.write_text(f"{value}\n")
        tmp.replace(RESTORE_PROGRESS_PATH)
    except OSError:
        pass


def _target_gpgdir(ctx: InstallContext) -> Path:
    return ctx.target / "etc" / "pacman.d" / "gnupg"


def _start_target_keyring_init(ctx: InstallContext) -> None:
    """Recreate the per-machine pacman keyring a legacy pacstrap left behind.

    The image ships no /etc/pacman.d/gnupg (a shared keyring key must never be
    distributed). Nothing during the install READS the keyring — the offline
    repo is SigLevel = Never — but the installed system does, and pacstrap -K
    WRITES it (see _await_target_keyring_init).

    Chroot-free on purpose: pacman-key --gpgdir writes the target's keyring
    directory directly, reading the live environment's
    /usr/share/pacman/keyrings (same package snapshot as the target's). With
    no chroot there are no API mounts to hold or tear down, which is what
    makes running this in the background safe — an arch-chroot's exit-time
    teardown unmounts by path and can pop a concurrent chroot's mounts.
    """
    info("› initializing per-machine pacman keyring (background)")
    gpgdir = shlex.quote(str(_target_gpgdir(ctx)))
    script = (
        f"pacman-key --gpgdir {gpgdir} --init && "
        f"pacman-key --gpgdir {gpgdir} --populate archlinux omarchy"
    )
    # start_new_session makes the shell a process-group leader, so
    # _kill_target_keyring_init reaches pacman-key and its gpg children —
    # killing just the sh wrapper would leave them mutating the target keyring.
    ctx.state["target_keyring_proc"] = subprocess.Popen(
        ["sh", "-c", script],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        start_new_session=True,
    )


def _kill_target_keyring_init(ctx: InstallContext) -> None:
    proc = ctx.state.get("target_keyring_proc")
    if proc is None:
        return
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _await_target_keyring_init(ctx: InstallContext, *, raise_on_error: bool = True) -> None:
    """Join the background keyring init if it is still pending; no-op after.

    Every pacstrap-semantics install must run behind this join — enforced by
    routing them through _install_target_packages: pacstrap -K
    unconditionally runs its own pacman-key --init on the target's gnupg dir
    — the very directory the background init is writing — and two concurrent
    inits on one gpg homedir can generate competing master keys or trip over
    gpg's keybox/trustdb locks. SigLevel = Never only skips keyring reads,
    not pacstrap's writes. Installs that never pacstrap (default kernel, no
    tailscale key, no screen reader) keep the full overlap and join at the
    end of _install_via_rootfs_image."""
    proc = ctx.state.get("target_keyring_proc")
    if proc is None:
        return
    try:
        _finish_target_keyring_init(ctx, proc, raise_on_error=raise_on_error)
    except RuntimeError:
        # The join completed and the init failed: nothing is left running, so
        # drop the proc before the error unwinds into the kill path.
        ctx.state.pop("target_keyring_proc", None)
        raise
    # Popped only after a completed join: an interrupting SIGTERM/SIGINT mid
    # communicate() must leave the proc in state so the exception path in
    # _install_via_rootfs_image can still kill and re-join it (a joined proc
    # must never be joined twice — communicate() raises on closed pipes).
    ctx.state.pop("target_keyring_proc", None)


def _finish_target_keyring_init(
    ctx: InstallContext,
    proc: subprocess.Popen,
    *,
    raise_on_error: bool,
) -> None:
    """Join the keyring init and always kill its gpg daemons: gpg-agent and
    dirmngr hold sockets under the target's gnupg dir and would keep the
    target busy at umount time — pacstrap kills them for the same reason.
    raise_on_error=False is the exception path, where the original error must
    not be masked by a keyring failure."""
    out, _ = proc.communicate()
    subprocess.run(
        ["gpgconf", "--homedir", str(_target_gpgdir(ctx)), "--kill", "all"],
        check=False,
        capture_output=True,
    )
    if raise_on_error and proc.returncode != 0:
        raise RuntimeError(
            "per-machine pacman keyring init failed "
            f"(exit {proc.returncode}):\n{(out or '').strip()}"
        )


def _write_target_hostname(ctx: InstallContext, config) -> None:
    # Same default archinstall's minimal_installation(hostname=...) applies
    # when the JSON carries none.
    hostname = getattr(config, "hostname", None) or "archinstall"
    hostname_path = ctx.target / "etc" / "hostname"
    hostname_path.parent.mkdir(parents=True, exist_ok=True)
    hostname_path.write_text(f"{hostname}\n")


def _ensure_target_locale(ctx: InstallContext, config) -> None:
    """en_US.UTF-8 is baked into the image (locale.gen entry, generated data,
    locale.conf). Both configurator JSONs hardcode it; this escape hatch only
    exists for a hand-written cidata config that asks for something else."""
    locale_config = getattr(config, "locale_config", None)
    if locale_config is None:
        return

    lang = (getattr(locale_config, "sys_lang", "") or "").strip()
    if not lang or lang.split(".")[0] == "en_US":
        return

    encoding = (getattr(locale_config, "sys_enc", "") or "UTF-8").strip()
    info(f"› generating non-default locale {lang}")
    locale_gen = ctx.target / "etc" / "locale.gen"
    entry = f"{lang} {encoding}\n"
    existing = locale_gen.read_text() if locale_gen.exists() else ""
    if entry not in existing:
        with locale_gen.open("a", encoding="utf-8") as f:
            f.write(entry)
    subprocess.run(["arch-chroot", str(ctx.target), "locale-gen"], check=True)
    (ctx.target / "etc" / "locale.conf").write_text(f"LANG={lang}\n")


def _enable_pipewire_pulse_for_users(ctx: InstallContext, config) -> None:
    """Replicate the one per-user side effect of archinstall's audio handler.

    AudioApp._enable_pipewire (archinstall 4.4, applications/audio.py) links
    pipewire-pulse.service/.socket into each user's default.target.wants.
    That is the only audio state the legacy handler creates that baking the
    package set cannot: no preset or package enables pipewire-pulse for the
    user (the fresh-install manifests carry exactly these two symlinks and
    nothing else), so without them PulseAudio-API clients on an image install
    would find no socket. The handler's hardware conditionals (sof-firmware,
    alsa-firmware) are already baked via archinstall.packages.
    """
    audio = getattr(getattr(config, "app_config", None), "audio_config", None)
    if "pipewire" not in str(getattr(audio, "audio", "") or "").lower():
        return

    for user in config.auth_config.users:
        username = getattr(user, "username", None)
        if not username:
            continue
        info(f"› enabling pipewire-pulse for {username}")
        wants_dir = (
            ctx.target / "home" / username / ".config" / "systemd" / "user"
            / "default.target.wants"
        )
        wants_dir.mkdir(parents=True, exist_ok=True)
        for unit in ("pipewire-pulse.service", "pipewire-pulse.socket"):
            link = wants_dir / unit
            link.unlink(missing_ok=True)
            link.symlink_to(f"/usr/lib/systemd/user/{unit}")
        # The dirs above were made as root; hand the subtree to the user the
        # way the archinstall handler's chown does.
        subprocess.run(
            ["arch-chroot", str(ctx.target), "chown", "-R",
             f"{username}:{username}", f"/home/{username}/.config"],
            check=True,
        )


def _reconcile_target_kernel(ctx: InstallContext, installer, config) -> None:
    """The image bakes exactly one kernel: linux. Bring the target to the
    configured kernel set (T2 Macs install with kernels=["linux-t2"], the only
    non-default kernel the pruned mirror is guaranteed to carry — any other
    name was rejected pre-format via ROOTFS_IMAGE_SUPPORTED_KERNELS).

    The install goes through pacstrap semantics, whose implicit -Sy also
    rewrites the target's sync db — baked from the FULL build-time mirror —
    against the pruned shipped repo, so later resolution matches what the ISO
    actually carries.

    The target's own boot hooks are live in the image (limine-entry-tool ships
    90-mkinitcpio-install.hook) and neither /etc/default/limine nor
    /etc/kernel/cmdline exists yet, so mask the install hook inside the target
    for the duration — the live-root masks around this phase do nothing for
    hooks pacman reads out of the target root (see _mask_mkinitcpio_pacman_hooks).
    The kernel-removal hooks stay live, same rationale as
    TARGET_DEFERRED_BOOT_HOOKS: pruning Limine entries is exactly what
    removing the stock kernel needs, and with no limine.conf yet they no-op.
    """
    kernels = _configured_kernels(config)
    missing = [k for k in kernels if k != "linux"]
    drop_linux = "linux" not in kernels
    if not missing and not drop_linux:
        return

    info(f"› reconciling kernels: baked [linux] → configured {kernels}")
    _mask_mkinitcpio_pacman_hooks(ctx, ctx.target, TARGET_DEFERRED_BOOT_HOOKS)
    try:
        if missing:
            _install_target_packages(ctx, installer, missing)
        if drop_linux:
            subprocess.run(
                ["arch-chroot", str(ctx.target), "pacman", "-Rdd", "--noconfirm", "linux"],
                check=True,
            )
    finally:
        _unmask_mkinitcpio_pacman_hooks(ctx, ctx.target, TARGET_DEFERRED_BOOT_HOOKS)


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


def _install_early_packages(installer) -> None:
    bootstrap_packages = _early_bootstrap_packages()
    user_seed_packages = _early_user_seed_packages()

    info(f"› installing early Omarchy packages: {', '.join(bootstrap_packages)}")
    installer.add_additional_packages(bootstrap_packages)

    info(f"› installing LuaRocks prerequisites: {', '.join(EARLY_LUAROCKS_PACKAGES)}")
    installer.add_additional_packages(EARLY_LUAROCKS_PACKAGES)

    info(f"› installing user seed packages: {', '.join(user_seed_packages)}")
    installer.add_additional_packages(user_seed_packages)


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


def _runtime_package_list(ctx: InstallContext) -> list[str]:
    """Selected Omarchy runtime package + every package in the ISO-bundled
    base package list that isn't already installed early."""
    base_pkgs_file = Path("/usr/share/omarchy-iso/omarchy-base.packages")
    pkgs = [_omarchy_runtime_package()]
    already_installed = set(_early_packages()) | {
        _omarchy_runtime_package(),
        _omarchy_settings_package(),
        _omarchy_nvim_package(),
        "omarchy",
        "omarchy-settings",
        "omarchy-nvim",
    }
    for raw in base_pkgs_file.read_text().splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        if s not in already_installed and s not in pkgs:
            pkgs.append(s)
    return pkgs


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
    res = subprocess.run(
        ["findmnt", "-rn", str(path)],
        capture_output=True,
        text=True,
    )
    return res.returncode == 0 and bool(res.stdout.strip())


# ── pre-mounted fstab / crypttab / cmdline ───────────────────────────────────

def _btrfs_root_device(ctx: InstallContext) -> str:
    storage = _storage_intent(ctx)
    if storage.get("luks_uuid"):
        return storage.get("root_mapper") or "/dev/mapper/omarchy_root"
    return storage["root_device"]


def _blkid_uuid(device: str) -> str:
    res = subprocess.run(
        ["blkid", "-s", "UUID", "-o", "value", device],
        capture_output=True, text=True, check=True,
    )
    uuid = res.stdout.strip()
    if not uuid:
        raise RuntimeError(f"blkid returned no UUID for {device}")
    return uuid


def _esp_device(ctx: InstallContext) -> str:
    storage = _storage_intent(ctx)
    if esp_device := storage.get("esp_device"):
        return esp_device

    boot = _boot_intent(ctx)
    esp_mp = ctx.target / boot["esp_mount"].lstrip("/")
    res = subprocess.run(
        ["findmnt", "-n", "-o", "SOURCE", str(esp_mp)],
        capture_output=True, text=True, check=True,
    )
    dev = res.stdout.strip()
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
    res = subprocess.run(
        ["efibootmgr"],
        capture_output=True, text=True, check=True,
    )
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
    parent = subprocess.run(
        ["lsblk", "-ndo", "PKNAME", part_dev],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    if not parent:
        raise RuntimeError(f"could not find parent disk for {part_dev}")
    part_num = subprocess.run(
        ["lsblk", "-ndo", "PARTN", part_dev],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
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
    proc = subprocess.run(cmd, check=False, text=True, capture_output=True)
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

    # Rootfs-image installs: the image's sync db was populated from the FULL
    # build-time mirror. If no residual install has resynced it yet (their
    # pacstrap semantics rewrite it in passing), refresh it against the pruned
    # shipped repo — the conf copy and bind mounts above are exactly what a
    # chroot pacman needs for that — so apply-system's hardware installs
    # resolve against what the ISO actually carries.
    if _is_rootfs_image_install() and not ctx.state.get("target_db_synced"):
        subprocess.run(["arch-chroot", str(ctx.target), "pacman", "-Sy"], check=True)
        ctx.state["target_db_synced"] = True

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

    chroot_cmd = ["arch-chroot"]
    if user:
        chroot_cmd += ["-u", user]
        env_extras.extend(_target_user_env(ctx, user))
    chroot_cmd += [str(ctx.target), "env", "--unset=XDG_RUNTIME_DIR", *env_extras, *cmd]

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

    subprocess.run(["arch-chroot", str(ctx.target), "limine-update"], check=True)

    subprocess.run(
        ["arch-chroot", str(ctx.target), "btrfs", "quota", "disable", "/"],
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

    boot = _boot_intent(ctx)
    storage = _storage_intent(ctx)
    esp_mount = ctx.target / boot["esp_mount"].lstrip("/")

    limine_conf = esp_mount / "limine.conf"
    if not limine_conf.exists():
        raise RuntimeError(f"{limine_conf} missing")
    limine_conf_text = limine_conf.read_text()
    if "Omarchy" not in limine_conf_text:
        raise RuntimeError(f"{limine_conf} has no Omarchy entry")

    if ctx.encrypt and "cryptdevice=" not in limine_conf_text:
        raise RuntimeError(f"Encrypted install but {limine_conf} has no cryptdevice=")

    kernel_cmdline = ctx.target / "etc" / "kernel" / "cmdline"
    if not kernel_cmdline.exists():
        raise RuntimeError(f"{kernel_cmdline} missing — UKI would have no cmdline")

    default_limine = ctx.target / "etc" / "default" / "limine"
    config_text = _limine_combined_config_text(ctx, default_limine.read_text())
    uki_prefix = _limine_setting(config_text, "CUSTOM_UKI_NAME", "omarchy") or "omarchy"
    kernel = storage.get("kernel") or (ctx.user_configuration.get("kernels") or ["linux"])[0]

    if arch.has_uefi():
        limine_binary = esp_mount / boot.get("esp_path", "/EFI/limine").lstrip("/") / boot.get("efi_binary", "limine_x64.efi")
        if not limine_binary.exists() or limine_binary.stat().st_size == 0:
            raise RuntimeError(f"{limine_binary} missing or empty")

        # Hardware packages (omarchy-hw-intel-ptl, …) can swap the kernel out
        # from under us mid-install, so trust what's on disk over what we asked
        # for and only fall back to the configured name when nothing's there.
        uki_dir = esp_mount / "EFI" / "Linux"
        candidates = _installed_kernels(ctx) or [kernel]
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
    fstype = _findmnt_value(ctx.target, "FSTYPE")
    if fstype != "btrfs":
        info(f"› target root is {fstype or 'unknown'}, not btrfs; skipping factory snapshot")
        return

    options = (_findmnt_value(ctx.target, "OPTIONS") or "").split(",")
    if not any(opt in ("subvol=/@", "subvol=@") for opt in options):
        info("› target root is not the @ subvolume; skipping factory snapshot")
        return

    device = (_findmnt_value(ctx.target, "SOURCE") or "").split("[")[0]
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
    res = subprocess.run(
        ["findmnt", "-no", column, str(path)],
        capture_output=True, text=True,
    )
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

    subprocess.run(["umount", "-R", str(ctx.target)], check=False, capture_output=True)
    if Path("/dev/mapper/omarchy_root").exists():
        subprocess.run(
            ["cryptsetup", "close", "omarchy_root"],
            check=False,
            capture_output=True,
        )
