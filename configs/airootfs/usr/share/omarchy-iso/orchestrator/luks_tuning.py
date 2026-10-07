"""LUKS open tuning for the unattended install, applied to archinstall's
Luks2 before any encryption happens.

The volume is opened once, at install time, with --allow-discards and
--perf-no_read_workqueue, stored persistently in the header, and stays open
for the whole install instead of archinstall's three open/close cycles:
each open is a full key derivation (2.2 s on a 12600K at the configurator's
iter-time). The cmdline (see phases_impl) spells the same options for both
initramfs flavours.

The format itself is archinstall's: argon2id at the configurator's
iter-time, benchmarked on the machine.
"""

from __future__ import annotations

import os
from pathlib import Path
from subprocess import CalledProcessError

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
    key_file_arg, passphrase = self._get_passphrase_args(key_file)
    cmd = ["cryptsetup", "open", str(self.luks_dev_path), str(self.mapper_name),
           *key_file_arg, "--type", "luks2", *OPEN_FLAGS]
    try:
        result = run(cmd, input_data=passphrase)
    except CalledProcessError as err:
        raise DiskError(f'Could not unlock luks2 device "{self.luks_dev_path}": {err.stdout.decode().rstrip()}')
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
    plain arch-chroot, and so do these."""
    return ["arch-chroot", str(self.target), *args]


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


def apply() -> None:
    if os.environ.get("OMARCHY_LUKS_TUNING", "1") != "1":
        return
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
    for param in cmdline.split():
        if param.startswith("cryptdevice=") and param.count(":") == 1:
            param = f"{param}:{CMDLINE_OPTIONS}"
        if param.startswith("cryptdevice="):
            spec, _, rest = param[len("cryptdevice="):].partition(":")
            name = rest.split(":")[0] or "root"
            uuid = _luks_uuid_of(spec)
            # Idempotent: every cmdline passes through here once at the
            # writer, and the archinstall-derived one has been here before.
            if uuid and f"rd.luks.name={uuid}=" not in cmdline:
                extra += [f"rd.luks.name={uuid}={name}",
                          f"rd.luks.options={uuid}={CMDLINE_OPTIONS.replace('allow-discards', 'discard')}"]
        out.append(param)
    return " ".join(out + extra)
