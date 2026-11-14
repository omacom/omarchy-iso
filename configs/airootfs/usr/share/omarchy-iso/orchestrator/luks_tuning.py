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

# The installed system also bypasses the write workqueue where that helps:
# an NVMe SSD, a CPU with AES instructions, and real hardware. dm-crypt's write
# path otherwise hands every write to one kcryptd thread that sorts all pending
# writes by sector, so a small fsync from the desktop waits behind a background
# writer's backlog. On a Ryzen AI Max+ 395 with a Samsung 990 PRO 4TB (LUKS2 +
# btrfs, kernel 7.2) a 4K write+fdatasync under a buffered 6.5 GB/s background
# writer went from p99 114 ms / max 199 ms to p99 23 ms / max 46 ms, 6x more
# syncs completed; the background writer lost 9% (6.7 -> 6.1 GB/s) and 4K
# random reads under that load rose from p99 0.45 ms to 2 ms. The sorting helps
# rotating disks, and the offload helps when encryption is slow; neither holds
# for an NVMe SSD with AES instructions. In a VM (virtio) the install image
# write was slower with it, so VMs keep the queue. The install itself keeps
# OPEN_FLAGS above either way; this only adds the option to what the installed
# system opens with. OMARCHY_LUKS_WRITE_WORKQUEUE=bypass|keep overrides the check.
WRITE_WORKQUEUE_OPTION = "no-write-workqueue"
WRITE_WORKQUEUE_ENV = "OMARCHY_LUKS_WRITE_WORKQUEUE"


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


def _with_calibration(original_encrypt):
    def encrypt(self, *args, **kwargs):
        from archinstall.lib.disk import luks
        from .luks_calibration import format_command, stop_calibration
        stop_calibration()
        original_run = luks.run
        # Keep archinstall's passphrase/key-file handling, return value and
        # error handling intact. Only adjust its format argv, for this call.
        def calibrated_run(command, *run_args, **run_kwargs):
            return original_run(format_command(command), *run_args, **run_kwargs)
        luks.run = calibrated_run
        try:
            return original_encrypt(self, *args, **kwargs)
        finally:
            luks.run = original_run
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


def _spec_device(spec: str) -> Path:
    """The device path a cryptdevice= spec names (UUID=, PARTUUID=, or a path)."""
    if "=" in spec:
        tag, _, value = spec.partition("=")
        return Path("/dev/disk") / f"by-{tag.lower()}" / value
    return Path(spec)


def _luks_uuid_of(spec: str) -> str | None:
    """LUKS header UUID of the device a cryptdevice= spec names
    (UUID=, PARTUUID=, or a path).

    For a UUID= spec the value is the header UUID by definition (that is
    what /dev/disk/by-uuid holds for a LUKS partition), so it is the
    fallback whenever the link is not there yet or blkid has nothing to say:
    a lookup hiccup must never silently drop the unlock parameters."""
    fallback = None
    tag, _, value = spec.partition("=")
    if value and tag.upper() == "UUID":
        fallback = value
    dev = _spec_device(spec)
    if not dev.exists():
        return fallback
    try:
        return run(["blkid", "-s", "UUID", "-o", "value", str(dev)]).stdout.decode().strip() or fallback
    except CalledProcessError:
        return fallback


def _in_vm() -> bool:
    try:
        return run(["systemd-detect-virt", "--vm"]).stdout.decode().strip() not in ("", "none")
    except CalledProcessError:
        return False  # exit status 1 and "none": not virtualized
    except OSError:
        return True   # cannot tell: keep the default queue


def _cpu_has_aes(cpuinfo: Path = Path("/proc/cpuinfo")) -> bool:
    """AES instructions: x86 lists `aes` in flags, arm64 in Features."""
    try:
        for line in cpuinfo.read_text().splitlines():
            key, _, values = line.partition(":")
            if key.strip() in ("flags", "Features") and "aes" in values.split():
                return True
    except OSError:
        pass
    return False


def _is_nvme_ssd(dev: Path) -> bool:
    """True when the disk under dev (a partition or a whole disk) is a
    non-rotational NVMe device."""
    try:
        parent = run(["lsblk", "-ndo", "PKNAME", str(dev)]).stdout.decode().strip()
        disk = f"/dev/{parent}" if parent else str(dev)
        fields = run(["lsblk", "-ndo", "TRAN,ROTA", disk]).stdout.decode().split()
    except (CalledProcessError, OSError):
        return False
    return fields == ["nvme", "0"]


def bypass_write_workqueue(spec: str) -> bool:
    """Whether the installed system should open this LUKS device with
    no-write-workqueue (see WRITE_WORKQUEUE_OPTION)."""
    forced = os.environ.get(WRITE_WORKQUEUE_ENV, "").strip().lower()
    if forced in ("bypass", "keep"):
        return forced == "bypass"
    dev = _spec_device(spec)
    if not dev.exists():
        return False
    return not _in_vm() and _cpu_has_aes() and _is_nvme_ssd(dev)


def cmdline_options(spec: str) -> str:
    """dm-crypt options for the installed system, in the busybox encrypt
    hook's spelling (crypttab and rd.luks.options= say discard for
    allow-discards; see crypttab_options)."""
    if bypass_write_workqueue(spec):
        return f"{CMDLINE_OPTIONS},{WRITE_WORKQUEUE_OPTION}"
    return CMDLINE_OPTIONS


def crypttab_options(options: str) -> str:
    return options.replace("allow-discards", "discard")


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
            param = f"{param}:{cmdline_options(param[len('cryptdevice='):].partition(':')[0])}"
        if param.startswith("cryptdevice="):
            spec, _, rest = param[len("cryptdevice="):].partition(":")
            name, _, options = rest.partition(":")
            name = name or "root"
            uuid = _luks_uuid_of(spec)
            # Idempotent: every cmdline passes through here once at the
            # writer, and the archinstall-derived one has been here before.
            if uuid and f"rd.luks.name={uuid}=" not in cmdline:
                extra += [f"rd.luks.name={uuid}={name}",
                          f"rd.luks.options={uuid}={crypttab_options(options or CMDLINE_OPTIONS)}"]
        out.append(param)
    return " ".join(out + extra)
