# Integration with archinstall (https://github.com/archlinux/archinstall,
# GPL-3.0-only, by the archinstall contributors): this module patches its Luks2
# (archinstall/lib/disk/luks.py). Attribution as omacom/omarchy-iso#202 asks.
"""LUKS open tuning for the unattended install, applied to archinstall's
Luks2 before any encryption happens.

The volume is opened once, at install time, with --allow-discards and
--perf-no_read_workqueue, stored persistently in the header, and stays open
for the whole install instead of archinstall's three open/close cycles:
each open is a full key derivation (2.2 s on a 12600K at the configurator's
iter-time). The cmdline (see phases_impl) spells the same options for both
initramfs flavours.

The format itself is archinstall's. For the configurator's 2 s Argon2id
policy, a completed calibration from this live boot can replace the search.
The format is given the volume key in a file, and that first open uses the
same file, so it derives nothing: the passphrase's key was derived a moment
before, by the format.
"""

from __future__ import annotations

from contextlib import contextmanager
import os
from pathlib import Path
from subprocess import CalledProcessError
from typing import Iterator

from archinstall.lib.command import run
from archinstall.lib.disk.luks import Luks2
from archinstall.lib.exceptions import DiskError
from archinstall.lib.log import debug

# --persistent writes the flags into the LUKS2 header, so every later open
# (busybox encrypt hook, sd-encrypt, systemd-gpt-auto) applies them without
# needing them on the kernel cmdline. no_write_workqueue is deliberately not
# here: in the install VM the image write onto the virtio disk takes
# 6.7-7.5 s with it and 5.0 s without, although a plain dd of zeros is
# faster with it (2.3 s against 3.4 s).
OPEN_FLAGS = ["--persistent", "--allow-discards", "--perf-no_read_workqueue"]
# The same options as the busybox encrypt hook and crypttab spell them.
CMDLINE_OPTIONS = "allow-discards,no-read-workqueue"


def _unlock(self: Luks2, key_file: Path | None = None) -> None:
    debug(f"Unlocking luks2 device (omarchy tuning): {self.luks_dev_path}")
    if not self.mapper_name:
        raise ValueError("mapper name missing")
    if self.is_unlocked():
        debug(f"{self.mapper_name} is already open; not deriving the key again")
        return
    # The volume key the format just used, when this is the open after it.
    volume_key = getattr(self, "omarchy_volume_key", None)
    keep_volume_key = getattr(self, "omarchy_keep_volume_key", False)
    self.omarchy_volume_key = None
    self.omarchy_keep_volume_key = False
    if volume_key is not None:
        key_file_arg, passphrase = ["--volume-key-file", str(volume_key)], None
    else:
        key_file_arg, passphrase = self._get_passphrase_args(key_file)
    cmd = ["cryptsetup", "open", str(self.luks_dev_path), str(self.mapper_name),
           *key_file_arg, "--type", "luks2", *OPEN_FLAGS]
    try:
        result = run(cmd, input_data=passphrase)
    except CalledProcessError as err:
        raise DiskError(f'Could not unlock luks2 device "{self.luks_dev_path}": {err.stdout.decode().rstrip()}')
    finally:
        if volume_key is not None and not keep_volume_key:
            volume_key.unlink(missing_ok=True)
    debug(f"cryptsetup open output: {result.stdout.decode().rstrip()}")
    if not self.is_unlocked():
        raise DiskError(f"Failed to unlock luks2 device: {self.luks_dev_path}")


_original_lock = Luks2.lock


def _lock(self: Luks2) -> None:
    """archinstall opens the new volume three times during an install: to
    check the format, to create the btrfs subvolumes, and to mount the
    layout, closing it in between. Each open is a full argon2id derivation.
    Keeping the mapper open makes the guarded unlocks above no-ops; the
    reboot at the end of the install closes it like any other mapping."""
    if os.environ.get("OMARCHY_LUKS_KEEP_OPEN", "1") == "1":
        debug(f"keeping {self.mapper_name} open for the rest of the install")
        return
    _original_lock(self)


def _chroot_argv(self, *args: str) -> list[str]:
    """archinstall runs its chroot commands through `arch-chroot -S`, which
    wraps each one in a transient systemd unit (systemd-run). Measured in a
    traced install: useradd 0.77 s of which 0.6 s is useradd itself, a
    chpasswd 0.15 s for 5 ms of work. The orchestrator's own chroots use
    plain arch-chroot, and so do these.

    When the orchestrator sets _omarchy_empty_skel on the installer, useradd
    skips copying /etc/skel byte-by-byte so the host can reflink-copy it
    across btrfs subvolumes instead."""
    argv = list(args)
    empty_skel = getattr(self, "_omarchy_empty_skel", None)
    if empty_skel and argv and argv[0] == "useradd" and "-k" not in argv and "--skel" not in argv:
        argv = [argv[0], "-k", str(empty_skel), *argv[1:]]
    return ["arch-chroot", str(self.target), *argv]


def _locale_archive_has_all(target: Path) -> bool:
    """True when every uncommented locale in the target's locale.gen is
    already in its locale archive (build-root-image.sh compiles en_US.UTF-8
    into the image), so locale-gen would only rebuild what is there."""
    try:
        wanted = []
        for line in (target / "etc" / "locale.gen").read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                wanted.append(line.split()[0])
        have = run(["arch-chroot", str(target), "localedef", "--list-archive"]).stdout.decode().split()
    except (OSError, CalledProcessError):
        return False
    norm = lambda name: name.replace("-", "").lower()  # en_US.UTF-8 is listed as en_US.utf8
    return bool(wanted) and all(norm(w) in {norm(h) for h in have} for w in wanted)


def _run_command(self, cmd: str, peek_output: bool = False):
    """The string-form twin of _chroot_argv (set_locale's locale-gen, the
    timezone symlink, plymouth-set-default-theme) without the systemd-run
    wrapper, and no locale-gen at all when the image's locale archive already
    holds every requested locale (0.77 s in a traced install)."""
    from archinstall.lib.command import SysCommand
    if cmd.strip() == "locale-gen" and _locale_archive_has_all(Path(self.target)):
        debug("locale archive already holds every locale in locale.gen; skipping locale-gen")
        return SysCommand("true")
    return SysCommand(f"arch-chroot {self.target} {cmd}", peek_output=peek_output)


_deferred_keyslots: list | None = None


@contextmanager
def defer_argon2_keyslot() -> Iterator[list]:
    """Allow Luks2.encrypt inside this block to defer Argon2id slot-0
    enrollment so the orchestrator can overlap it with post-image-write setup.
    Standalone callers outside this block stay synchronous."""
    global _deferred_keyslots
    previous = _deferred_keyslots
    collected: list = []
    _deferred_keyslots = collected
    try:
        yield collected
    except BaseException:
        for entry in collected:
            entry.abort()
        raise
    finally:
        _deferred_keyslots = previous


def _with_calibration(original_encrypt):
    def encrypt(self, *args, **kwargs):
        from archinstall.lib.disk import luks
        from .luks_calibration import (
            DeferredKeyslot,
            can_defer_keyslot,
            deferred_format_command,
            format_command,
            new_volume_key,
            stop_calibration,
        )
        # When deferring Argon2id enrollment, stop any in-flight calibration
        # immediately rather than waiting ~2-3s for it: fast_cmd uses minimal
        # PBKDF2, and the background enrollment after image-write uses either
        # the cached result (if calibration already finished) or --iter-time.
        if _deferred_keyslots is not None and can_defer_keyslot():
            stop_calibration(wait=0)
        else:
            stop_calibration()
        original_run = luks.run
        volume_key = new_volume_key()
        temp_keyfile: Path | None = None
        deferred_entry: DeferredKeyslot | None = None

        # Keep archinstall's passphrase/key-file handling, return value and
        # error handling intact. Only adjust its format argv, for this call.
        def calibrated_run(command, *run_args, **run_kwargs):
            nonlocal temp_keyfile, deferred_entry
            input_data = run_kwargs.get("input_data")
            if (_deferred_keyslots is not None and deferred_entry is None
                    and isinstance(input_data, (bytes, bytearray)) and input_data):
                candidate_temp = new_volume_key(256)
                split = deferred_format_command(command, volume_key, candidate_temp)
                if split is not None:
                    fast_cmd, enroll_cmd, kill_cmd = split
                    temp_keyfile = candidate_temp
                    device = command[command.index("luksFormat") + 1]
                    no_input_kwargs = {k: v for k, v in run_kwargs.items() if k != "input_data"}
                    result = original_run(fast_cmd, *run_args, **no_input_kwargs)
                    deferred_entry = DeferredKeyslot(
                        device=device,
                        volume_key=volume_key,
                        temp_keyfile=temp_keyfile,
                        enroll_cmd=enroll_cmd,
                        kill_cmd=kill_cmd,
                        passphrase=bytes(input_data),
                    )
                    return result
                candidate_temp.unlink(missing_ok=True)
            return original_run(format_command(command, volume_key), *run_args, **run_kwargs)

        luks.run = calibrated_run
        try:
            result = original_encrypt(self, *args, **kwargs)
        except BaseException:
            volume_key.unlink(missing_ok=True)
            if temp_keyfile is not None:
                temp_keyfile.unlink(missing_ok=True)
            raise
        finally:
            luks.run = original_run
        # For the unlock that follows on this handler, which removes it unless
        # a deferred keyslot enrollment still needs it.
        self.omarchy_volume_key = volume_key
        if deferred_entry is not None:
            self.omarchy_keep_volume_key = True
            _deferred_keyslots.append(deferred_entry)
        return result
    return encrypt


def apply() -> None:
    if os.environ.get("OMARCHY_LUKS_TUNING", "1") != "1":
        return
    Luks2.encrypt = _with_calibration(Luks2.encrypt)  # type: ignore[method-assign]
    Luks2.unlock = _unlock    # type: ignore[method-assign]
    Luks2.lock = _lock        # type: ignore[method-assign]
    from archinstall.lib.installer import Installer
    Installer._chroot_argv = _chroot_argv  # type: ignore[method-assign]
    Installer.run_command = _run_command   # type: ignore[method-assign]


def _luks_uuid_of(spec: str) -> str | None:
    """LUKS header UUID of the device a cryptdevice= spec names
    (UUID=, PARTUUID=, or a path).

    For a UUID= spec the value is the header UUID by definition (that is
    what /dev/disk/by-uuid holds for a LUKS partition), so it is the
    fallback whenever the link is not there yet or blkid has nothing to say:
    a lookup hiccup must never silently drop the unlock parameters."""
    fallback = None
    if "=" in spec:
        tag, _, value = spec.partition("=")
        dev = Path("/dev/disk") / f"by-{tag.lower()}" / value
        if tag.upper() == "UUID":
            fallback = value
    else:
        dev = Path(spec)
    if not dev.exists():
        return fallback
    try:
        return run(["blkid", "-s", "UUID", "-o", "value", str(dev)]).stdout.decode().strip() or fallback
    except CalledProcessError:
        return fallback


def with_cmdline_options(cmdline: str) -> str:
    """Append the dm-crypt options to a cryptdevice=UUID=...:name parameter
    that has none, and add the sd-encrypt spelling of the same mapping
    (rd.luks.name= / rd.luks.options=), leaving anything else untouched.

    Limine boots the pre-built UKI with this cmdline (limine-entry-tool
    writes it into the entry, overriding the UKI's embedded one). That
    initramfs has the systemd hooks, which ignore cryptdevice= and would wait
    on root=/dev/mapper/root forever; the rd.luks.* parameters make it
    unlock the same partition under the same mapper name. A later
    limine-mkinitcpio rebuild from the busybox drop-ins reads cryptdevice=
    and ignores rd.luks.*, so one cmdline serves both initramfs flavours."""
    out = []
    extra = []
    tokens = cmdline.split()
    existing_rd_names = {
        token.rsplit("=", 1)[1]
        for token in tokens
        if token.startswith("rd.luks.name=") and token.count("=") >= 2
    }
    for param in tokens:
        if param.startswith("cryptdevice=") and param.count(":") == 1:
            param = f"{param}:{CMDLINE_OPTIONS}"
        if param.startswith("cryptdevice="):
            spec, _, rest = param[len("cryptdevice="):].partition(":")
            name = rest.split(":")[0] or "root"
            # Idempotent: every cmdline passes through here once at the
            # writer, and the archinstall-derived one has been here before.
            # Skip shelling out to blkid once this mapper already has an
            # rd.luks.name= parameter on the cmdline.
            if name not in existing_rd_names:
                uuid = _luks_uuid_of(spec)
                if uuid and f"rd.luks.name={uuid}=" not in cmdline:
                    extra += [f"rd.luks.name={uuid}={name}",
                              f"rd.luks.options={uuid}={CMDLINE_OPTIONS.replace('allow-discards', 'discard')}"]
                    existing_rd_names.add(name)
        out.append(param)
    return " ".join(out + extra)
