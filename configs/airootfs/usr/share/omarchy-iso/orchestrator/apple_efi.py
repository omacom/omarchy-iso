"""Apple's coprocessor firmware folder, carried across a full-disk install.

On 2016/2017 Touch Bar MacBook Pros the T1 coprocessor holds no firmware of
its own: the Mac loads it from `EFI/APPLE/EMBEDDEDOS` on the EFI System
Partition at every boot, and the Touch Bar, Touch ID and the FaceTime camera
are all behind that chip. Recreating the ESP deletes the folder, and nothing
in Linux puts it back — the machine installs and boots fine, with three pieces
of hardware permanently dead until macOS is reinstalled to write the folder
again (basecamp/omarchy#8271).

So the folder is copied into the live system's RAM before the partition table
is touched, and written back onto the new ESP before the bootloader lands on
it. Everything here is best-effort by construction: a failure is logged and
the install carries on, because a machine that boots with a dead Touch Bar is
today's outcome, while an install aborted over a firmware copy is worse than
the bug it protects against.

The folder is the whole signal — there is no hardware sniffing. A disk that
has one gets it preserved, and a disk that has none costs a read-only mount
of the partitions the installer is about to erase anyway.
"""

from __future__ import annotations

import shutil
import tempfile
from collections.abc import Iterator
from contextlib import ExitStack, contextmanager
from pathlib import Path

from .command import capture, require_text
from .ui import info

# Relative to the root of the ESP, in the case the firmware itself uses.
APPLE_DIR = Path("EFI/APPLE")
FIRMWARE_DIR = "EMBEDDEDOS"

# The real folder is a few MB. These bound what a surprising one may cost the
# live system, whose RAM the install itself is also spending.
MAX_STASH_BYTES = 256 * 1024 * 1024
FREE_SPACE_MARGIN = 256 * 1024 * 1024


def preserve(disk: str, stash: Path) -> Path | None:
    """Copy EFI/APPLE off `disk` into `stash` before the disk is wiped.

    Returns the stash path, or None when there was nothing to preserve or the
    copy did not work out. Every mount is read-only: the source is never
    written, only read out of the way.
    """
    try:
        with ExitStack() as mounts:
            candidates = []
            for partition in _vfat_partitions(disk):
                root = mounts.enter_context(_mounted_ro(partition))
                if root and (root / APPLE_DIR).is_dir():
                    candidates.append((partition, root / APPLE_DIR))

            if not candidates:
                info("› no Apple coprocessor firmware on the install disk")
                return None

            # More than one ESP can carry an EFI/APPLE; the one holding the
            # firmware itself is the one worth keeping.
            partition, source = max(
                candidates, key=lambda found: (found[1] / FIRMWARE_DIR).is_dir()
            )
            return _stash(partition, source, stash)
    except Exception as exc:  # noqa: BLE001 — never abort an install over this
        info(f"› warning: could not preserve Apple coprocessor firmware: {exc}")
        return None


def restore(esp_root: Path, stash: Path) -> bool:
    """Write the preserved folder back onto the freshly created ESP.

    `esp_root` is the ESP as the live system sees it (the mount under the
    install target), not the mountpoint the installed system will use.
    """
    if not stash.is_dir():
        return False

    destination = esp_root / APPLE_DIR
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(stash, destination, dirs_exist_ok=True)
        capture(["sync"])

        expected = _tree_size(stash)
        written = _tree_size(destination)
        if written != expected:
            info(
                f"› warning: Apple coprocessor firmware landed on {destination} "
                f"as {written[0]} files / {written[1]} bytes, expected "
                f"{expected[0]} / {expected[1]}"
            )
            return False
    except Exception as exc:  # noqa: BLE001 — never abort an install over this
        info(f"› warning: could not restore Apple coprocessor firmware: {exc}")
        return False

    info(
        f"› restored Apple coprocessor firmware to {destination} "
        f"({expected[0]} files, {expected[1] // 1024} KiB)"
    )
    return True


def _stash(partition: str, source: Path, stash: Path) -> Path | None:
    files, size = _tree_size(source)
    stash.parent.mkdir(parents=True, exist_ok=True)
    free = shutil.disk_usage(stash.parent).free
    if size > MAX_STASH_BYTES or size + FREE_SPACE_MARGIN > free:
        info(
            f"› warning: not preserving Apple coprocessor firmware from "
            f"{partition}: {size} bytes does not fit in the live system's "
            f"memory ({free} bytes free)"
        )
        return None

    if stash.exists():
        shutil.rmtree(stash)
    shutil.copytree(source, stash)
    info(
        f"› preserved Apple coprocessor firmware from {partition} "
        f"({files} files, {size // 1024} KiB)"
    )
    return stash


def _vfat_partitions(disk: str) -> list[str]:
    """Partitions on `disk` that could be an ESP, in on-disk order."""
    listing = capture(["lsblk", "-nrpo", "PATH,FSTYPE", disk])
    partitions = []
    for line in listing.stdout.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1] == "vfat" and fields[0] != disk:
            # This is handed to mount, so a byte lost in decoding it must stop
            # the copy rather than mount something else.
            partitions.append(require_text(fields[0], "the ESP device"))
    return partitions


@contextmanager
def _mounted_ro(partition: str) -> Iterator[Path | None]:
    """Mount `partition` read-only somewhere temporary, or yield None."""
    with tempfile.TemporaryDirectory(prefix="omarchy-esp-") as mountpoint:
        if capture(["mount", "-o", "ro", partition, mountpoint]).returncode != 0:
            yield None
            return
        try:
            yield Path(mountpoint)
        finally:
            capture(["umount", mountpoint])


def _tree_size(root: Path) -> tuple[int, int]:
    """(file count, total bytes) under `root` — what a restore must match."""
    files = [path for path in root.rglob("*") if path.is_file()]
    return len(files), sum(path.stat().st_size for path in files)
