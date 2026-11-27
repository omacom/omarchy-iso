"""Shared udev EVENT_LOCKED settle watchdog and whole-disk block-device helpers.

When a process closes a whole disk O_RDWR (parted.Disk.commit(), wipe_dev(),
mkfs, ...), systemd-udevd's IN_CLOSE_WRITE watch forks (udev-synth), which
takes flock(LOCK_EX) and emits change uevents while still locked. Any
(udev-worker) colliding with that lock hits EAGAIN and requeues its event in
EVENT_LOCKED on a 200 ms + 1 s retry timer; (udev-synth) then exits closing an
O_RDONLY descriptor (no IN_CLOSE_WRITE), stranding `udevadm settle` for up to
1.2 s.

Taking and immediately releasing a non-blocking LOCK_EX on an O_RDONLY
descriptor proves neither (udev-synth) nor any (udev-worker) holds the disk
lock, and writing "change\\n" to `/sys/class/block/<disk>/uevent` wakes the
queued event without firing IN_CLOSE_WRITE, forking (udev-synth), or spawning
a `udevadm trigger` subprocess.
"""

from __future__ import annotations

from collections.abc import Callable, Iterable, Iterator
from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import stat
import threading

# Intervals (seconds) between checks for a udevadm settle stuck on
# systemd-udevd's 200ms+1s EVENT_LOCKED retry timer after (udev-synth) exits.
# Fast settles finish before the first tick; slow disks that are actively
# locked by (udev-synth) or (udev-worker) fail the non-blocking LOCK_EX probe
# and are left undisturbed.
SETTLE_NUDGE_DELAYS: tuple[float, ...] = (0.025, 0.05, 0.1, 0.25, 0.5)
SYS_BLOCK = Path("/sys/class/block")


def whole_disk_block_device(
    disk_path: str | Path,
    *,
    sys_block: Path | None = None,
    dev_root: Path = Path("/dev"),
) -> Path | None:
    """Resolve `disk_path` to its whole-disk block device node, or None if it
    is not a block device.

    If `disk_path` is a partition (e.g. `/dev/nvme0n1p2`), follows sysfs
    (`/sys/class/block/<part>/partition` and symlink parent) to return the
    enclosing whole disk (`/dev/nvme0n1`).
    """
    base = SYS_BLOCK if sys_block is None else sys_block
    try:
        resolved = Path(disk_path).resolve()
        if not stat.S_ISBLK(resolved.stat().st_mode):
            return None
        entry = base / resolved.name
        if (entry / "partition").exists():
            parent = dev_root / entry.resolve().parent.name
            if parent.exists() and stat.S_ISBLK(parent.stat().st_mode):
                return parent
        return resolved
    except OSError:
        return None


@contextmanager
def flock_whole_disk(
    device: str | Path,
    *,
    whole_disk_fn: Callable[[str | Path], Path | None] | None = None,
) -> Iterator[None]:
    """Hold an exclusive BSD lock on `device`'s whole-disk block node (via an
    O_RDONLY descriptor so closing never fires IN_CLOSE_WRITE) so systemd-udevd
    defers probing across raw image writes and `btrfstune -m`.
    """
    resolver = whole_disk_block_device if whole_disk_fn is None else whole_disk_fn
    lock_target = resolver(device)
    if lock_target is None:
        yield
        return
    try:
        fd = os.open(str(lock_target), os.O_RDONLY | os.O_CLOEXEC)
    except OSError:
        yield
        return
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError:
            pass
        yield
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


def nudge_if_disk_unlocked(
    disk_path: str | Path,
    done: threading.Event | None = None,
    *,
    whole_disk_fn: Callable[[str | Path], Path | None] | None = None,
    sys_block: Path | None = None,
) -> bool:
    """Wake an EVENT_LOCKED retry timer on `disk_path` if no udev process holds
    a lock on its whole disk.

    Returns True iff a sysfs `"change\\n"` uevent was written.
    """
    resolver = whole_disk_block_device if whole_disk_fn is None else whole_disk_fn
    base = SYS_BLOCK if sys_block is None else sys_block
    whole_disk = resolver(disk_path)
    if whole_disk is None:
        return False
    try:
        fd = os.open(str(whole_disk), os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    finally:
        os.close(fd)
    if done is not None and done.is_set():
        return False
    try:
        (base / whole_disk.name / "uevent").write_text("change\n")
        return True
    except OSError:
        return False


def settle_disk(
    disk_path: str | Path | None,
    settle_fn: Callable[[], object],
    *,
    delays: Iterable[float] | None = None,
    nudge_fn: Callable[[str | Path, threading.Event], bool] | None = None,
):
    """Run `settle_fn()` alongside a bounded watchdog that nudges `disk_path`
    via `nudge_if_disk_unlocked` if `settle_fn()` stalls on an EVENT_LOCKED
    retry timer while the disk is unlocked.
    """
    if not disk_path:
        return settle_fn()
    done = threading.Event()
    schedule = SETTLE_NUDGE_DELAYS if delays is None else delays
    nudge = nudge_if_disk_unlocked if nudge_fn is None else nudge_fn

    def watchdog() -> None:
        for delay in schedule:
            if done.wait(delay):
                return
            nudge(disk_path, done)

    thread = threading.Thread(target=watchdog, daemon=True)
    thread.start()
    try:
        return settle_fn()
    finally:
        done.set()
        thread.join(timeout=1.0)
