"""Free-space install execution in the orchestrator.

Unifies free-space installs with full-disk sequencing: the configurator writes
only a declarative `omarchy_install.free_space_plan`, the orchestrator verifies
the install medium and validates the plan before touching the disk, then
creates the two new partitions, formats, sets up in-process deferred LUKS2,
mounts the btrfs subvolumes and ESP, and rolls back ONLY the partitions it
created if anything fails.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import stat
import subprocess
import time

from . import disk_udev
from .command import capture
from .luks_calibration import format_and_open_luks
from .ui import info

BOOT_MEDIUM_MOUNT = Path("/run/archiso/bootmnt")
MIN_PARTITION_BYTES = 1024 * 1024
SIZE_TOLERANCE_BYTES = 1024 * 1024
WAIT_DEVICE_TIMEOUT = 10.0
WAIT_DEVICE_INTERVAL = 0.2

_SFDISK_PART_RE = re.compile(r"^(\S+)\s*:\s*start=\s*(\d+),\s*size=\s*(\d+)\b")


def free_space_plan(ctx) -> dict | None:
    """Return the declarative free_space_plan dict when present, else None."""
    omarchy_install = getattr(ctx, "omarchy_install", None)
    if not isinstance(omarchy_install, dict):
        return None
    plan = omarchy_install.get("free_space_plan")
    return plan if isinstance(plan, dict) else None


def partition_path(disk: str, part_num: int) -> str:
    """Partition device path for `disk` and `part_num`, handling NVMe/mmcblk/loop pN."""
    if "nvme" in disk or "mmcblk" in disk or (disk and disk[-1].isdigit()):
        return f"{disk}p{part_num}"
    return f"{disk}{part_num}"


def _is_block_device(path: str | Path) -> bool:
    try:
        return stat.S_ISBLK(Path(path).stat().st_mode)
    except OSError:
        return False


def _block_device_size(disk: str) -> int:
    fd = os.open(disk, os.O_RDONLY | os.O_CLOEXEC)
    try:
        return os.lseek(fd, 0, os.SEEK_END)
    finally:
        os.close(fd)


def _boot_medium_disk() -> Path | None:
    """Whole block device backing /run/archiso/bootmnt, if mounted from a block device."""
    res = capture(["findmnt", "-no", "SOURCE", str(BOOT_MEDIUM_MOUNT)])
    source = res.stdout.strip() if res.returncode == 0 else ""
    if not source.startswith("/dev/"):
        return None
    pk = capture(["lsblk", "-no", "PKNAME", source])
    pkname = pk.stdout.strip().splitlines()[0].strip() if pk.returncode == 0 and pk.stdout.strip() else ""
    candidate = Path("/dev") / pkname if pkname else Path(source)
    try:
        return candidate.resolve(strict=True)
    except OSError:
        return None


def _parse_sfdisk_dump(disk: str, output: str) -> tuple[str, list[tuple[int, int, int]]]:
    """Parse `sfdisk -d` output into (label, [(part_num, start_bytes, size_bytes), ...])."""
    label = ""
    sector_size = 512
    partitions: list[tuple[int, int, int]] = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("label:"):
            label = line.split(":", 1)[1].strip().lower()
            continue
        if line.startswith("sector-size:"):
            val = line.split(":", 1)[1].strip()
            if val.isdigit() and int(val) > 0:
                sector_size = int(val)
            continue
        match = _SFDISK_PART_RE.match(line)
        if not match:
            continue
        node, start_s, size_s = match.group(1), int(match.group(2)), int(match.group(3))
        if size_s == 0:
            continue
        if not node.startswith(disk):
            continue
        suffix = node[len(disk):]
        if suffix.startswith("p"):
            suffix = suffix[1:]
        if not suffix.isdigit():
            continue
        partitions.append((int(suffix), start_s * sector_size, size_s * sector_size))
    return label, partitions


def _read_partition_table(disk: str) -> tuple[str, list[tuple[int, int, int]]]:
    """Read the on-disk partition table using O_RDONLY `sfdisk -d` (0 udev events)."""
    result = subprocess.run(
        ["sfdisk", "-d", disk],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or f"exit {result.returncode}").strip()
        raise RuntimeError(f"could not read partition table on {disk}: {detail}")
    return _parse_sfdisk_dump(disk, result.stdout)


def _require_strict_int(plan: dict, key: str) -> int:
    value = plan.get(key)
    if type(value) is not int:
        raise RuntimeError(f"free_space_plan.{key} must be an integer, got {value!r}")
    return value


def _require_strict_bool(plan: dict, key: str) -> bool:
    value = plan.get(key)
    if type(value) is not bool:
        raise RuntimeError(f"free_space_plan.{key} must be a boolean, got {value!r}")
    return value


def validate_free_space_plan(ctx) -> Path:
    """Validate `omarchy_install.free_space_plan` before touching the disk.

    Returns the canonical resolved block device Path for `disk`.
    """
    plan = free_space_plan(ctx)
    if plan is None:
        raise RuntimeError("free_space_plan missing")

    raw_disk = plan.get("disk")
    if not isinstance(raw_disk, str) or not raw_disk:
        raise RuntimeError("free_space_plan.disk missing")
    try:
        resolved = Path(raw_disk).resolve(strict=True)
    except OSError as exc:
        raise RuntimeError(f"free_space_plan.disk does not exist: {raw_disk}") from exc
    if not _is_block_device(resolved):
        raise RuntimeError(f"free_space_plan.disk is not a block device: {raw_disk} -> {resolved}")

    boot_disk = _boot_medium_disk()
    if boot_disk is not None and resolved == boot_disk:
        raise RuntimeError(f"free_space_plan targets the boot medium disk: {resolved}")

    needs_mklabel = _require_strict_bool(plan, "needs_mklabel")
    encrypt = _require_strict_bool(plan, "encrypt")
    efi_start = _require_strict_int(plan, "efi_start_b")
    efi_end = _require_strict_int(plan, "efi_end_b")
    root_start = _require_strict_int(plan, "root_start_b")
    root_end = _require_strict_int(plan, "root_end_b")

    disk_size = _block_device_size(str(resolved))
    if not (0 < efi_start < efi_end <= root_start < root_end <= disk_size):
        raise RuntimeError(
            f"free_space_plan byte ranges invalid for {resolved} ({disk_size}B): "
            f"efi=[{efi_start}, {efi_end}), root=[{root_start}, {root_end})"
        )
    if (efi_end - efi_start) < MIN_PARTITION_BYTES or (root_end - root_start) < MIN_PARTITION_BYTES:
        raise RuntimeError("free_space_plan partition size below minimum 1 MiB")

    if os.path.ismount(ctx.target):
        raise RuntimeError(f"free_space_plan target {ctx.target} is already mounted")

    if not needs_mklabel:
        label, existing = _read_partition_table(str(resolved))
        for p_num, p_start, p_size in existing:
            p_end = p_start + p_size
            for role, start_b, end_b in (("EFI", efi_start, efi_end), ("root", root_start, root_end)):
                if start_b < p_end and p_start < end_b:
                    raise RuntimeError(
                        f"free_space_plan {role} range [{start_b}, {end_b}) overlaps "
                        f"existing partition {p_num} [{p_start}, {p_end}) on {resolved}"
                    )
        if label in ("dos", "msdos") and len(existing) > 2:
            raise RuntimeError(
                f"MBR disk {resolved} already has {len(existing)} partitions; need 2 free slots"
            )
    else:
        probe = subprocess.run(
            ["sfdisk", "-d", str(resolved)],
            capture_output=True,
            text=True,
            check=False,
        )
        if probe.returncode == 0:
            _, existing = _parse_sfdisk_dump(str(resolved), probe.stdout)
            if existing:
                raise RuntimeError(
                    f"free_space_plan requested mklabel gpt on {resolved}, "
                    f"but {len(existing)} partition(s) already exist"
                )

    if encrypt:
        password = (getattr(ctx, "user_credentials", None) or {}).get("encryption_password") or ""
        if not password:
            raise RuntimeError("free_space_plan has encrypt=True but encryption_password is missing")

    return resolved


def settle_disk_devices(disk: str, timeout: float = 30.0) -> None:
    """Settle udev for `disk` without stranding on systemd-udevd's EVENT_LOCKED
    200 ms + 1 s retry timer.

    Delegates to the shared `disk_udev.settle_disk` watchdog, which probes with
    non-blocking O_RDONLY `flock(LOCK_EX | LOCK_NB)` and nudges via sysfs
    `uevent` `"change\\n"` when the disk is unlocked.
    """
    disk_udev.settle_disk(
        disk,
        lambda: subprocess.run(
            ["udevadm", "settle", f"--timeout={int(timeout)}"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ),
    )


def wait_for_device(
    device: str,
    *,
    timeout: float = WAIT_DEVICE_TIMEOUT,
    interval: float = WAIT_DEVICE_INTERVAL,
) -> None:
    """Wait up to `timeout` seconds for block device node `device` to appear."""
    if _is_block_device(device):
        return
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        subprocess.run(
            ["udevadm", "settle", "--timeout=2"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if _is_block_device(device):
            return
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(interval, remaining))
    if not _is_block_device(device):
        raise RuntimeError(f"block device {device} did not appear within {timeout:g}s")


def _create_partition(
    disk: str,
    start_b: int,
    end_b: int,
    fstype: str,
    name: str,
    created_parts: list[int],
) -> int:
    """Create one partition in `[start_b, end_b)` and discover its exact on-disk
    number via O_RDONLY `sfdisk -d` diffing. Immediately appends to `created_parts`
    for scoped rollback before verifying size."""
    label, before_rows = _read_partition_table(disk)
    before_nums = {row[0] for row in before_rows}

    mkpart_arg = name if (label == "gpt" and name) else "primary"
    # parted end is inclusive, so end_b - 1 yields exact size (end_b - start_b),
    # preserving 4096-byte alignment for LUKS2.
    result = subprocess.run(
        [
            "parted", "--script", disk, "mkpart",
            mkpart_arg, fstype, f"{start_b}B", f"{end_b - 1}B",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or f"exit {result.returncode}").strip()
        raise RuntimeError(f"parted mkpart {name} on {disk} failed: {detail}")

    _, after_rows = _read_partition_table(disk)
    after_by_num = {row[0]: row[2] for row in after_rows}
    after_nums = set(after_by_num)
    if len(after_nums) != len(before_nums) + 1 or not before_nums.issubset(after_nums):
        raise RuntimeError(
            f"unexpected partition table change on {disk}: before={sorted(before_nums)} after={sorted(after_nums)}"
        )

    new_nums = after_nums - before_nums
    part_num = next(iter(new_nums))
    created_parts.append(part_num)

    actual_size = after_by_num[part_num]
    want_size = end_b - start_b
    if not (want_size - SIZE_TOLERANCE_BYTES <= actual_size <= want_size + SIZE_TOLERANCE_BYTES):
        raise RuntimeError(
            f"partition {part_num} on {disk} size {actual_size}B outside expected {want_size}B +/- 1 MiB"
        )
    return part_num


def _run_disk_cmd(cmd: list[str], desc: str) -> None:
    """Run a disk command; on failure, log its output and raise with detail."""
    res = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if res.returncode != 0:
        combined = "\n".join(
            line for part in (res.stdout, res.stderr) for line in (part or "").splitlines() if line.strip()
        )
        if combined:
            for line in combined.splitlines():
                info(f"  {line}")
            raise RuntimeError(f"{desc} failed (exit {res.returncode}): {combined.splitlines()[-1]}")
        raise RuntimeError(f"{desc} failed (exit {res.returncode})")


def execute_free_space_plan(ctx) -> None:
    """Execute `omarchy_install.free_space_plan`: partition, settle, wipefs,
    optional in-process deferred LUKS2, mkfs.btrfs -K + subvolumes + mounts,
    mkfs.fat + typed mount -t vfat, populate storage intent, and verify."""
    from .phases_impl import (
        _boot_intent,
        _time_step,
        verify_pre_mounted_root_empty,
        verify_protected_mounts,
    )

    resolved = validate_free_space_plan(ctx)
    disk = str(resolved)
    plan = free_space_plan(ctx)
    assert plan is not None

    needs_mklabel = plan["needs_mklabel"]
    encrypt = plan["encrypt"]
    efi_start = plan["efi_start_b"]
    efi_end = plan["efi_end_b"]
    root_start = plan["root_start_b"]
    root_end = plan["root_end_b"]
    esp_mount = _boot_intent(ctx)["esp_mount"]

    created_state: dict[str, object] = {"disk": disk, "parts": []}
    ctx.state["free_space_created_parts"] = created_state
    created_parts: list[int] = created_state["parts"]  # type: ignore[assignment]

    with _time_step("FS.free_space_partition"):
        if needs_mklabel:
            _run_disk_cmd(["parted", "--script", disk, "mklabel", "gpt"], f"initializing GPT on {disk}")
        efi_num = _create_partition(disk, efi_start, efi_end, "fat32", "OMARCHY_EFI", created_parts)
        root_num = _create_partition(disk, root_start, root_end, "btrfs", "OMARCHY_ROOT", created_parts)
        _run_disk_cmd(
            ["parted", "--script", disk, "set", str(efi_num), "esp", "on"],
            f"flagging partition {efi_num} as ESP on {disk}",
        )
        efi_dev = partition_path(disk, efi_num)
        root_dev = partition_path(disk, root_num)
        if not (_is_block_device(efi_dev) and _is_block_device(root_dev)):
            subprocess.run(["partprobe", disk], check=False, capture_output=True, text=True)

    with _time_step("FS.free_space_settle"):
        settle_disk_devices(disk)
        wait_for_device(efi_dev)
        wait_for_device(root_dev)

    with _time_step("FS.free_space_wipefs"):
        _run_disk_cmd(["wipefs", "-af", efi_dev], f"clearing stale signatures on {efi_dev}")
        _run_disk_cmd(["wipefs", "-af", root_dev], f"clearing stale signatures on {root_dev}")

    luks_uuid: str | None = None
    if encrypt:
        with _time_step("FS.free_space_luks"):
            passphrase = (ctx.user_credentials.get("encryption_password") or "").encode("utf-8")
            deferred = format_and_open_luks(root_dev, "omarchy_root", passphrase)
            if deferred is not None:
                ctx.state.setdefault("luks_deferred_keyslots", []).append(deferred)
            root_mapper = "/dev/mapper/omarchy_root"
            luks_uuid = capture(["blkid", "-p", "-s", "UUID", "-o", "value", root_dev]).stdout.strip()
            if not luks_uuid:
                raise RuntimeError(f"blkid -p returned no LUKS UUID for {root_dev}")
    else:
        root_mapper = root_dev

    with _time_step("FS.free_space_mkfs_and_mount"):
        # -K skips whole-device TRIM on this throwaway btrfs (the root image overwrites
        # it moments later, and trim_target trims free space once the install timer stops).
        _run_disk_cmd(["mkfs.btrfs", "-K", "-f", "-L", "OMARCHY", root_mapper], f"creating Btrfs on {root_mapper}")
        wait_for_device(root_mapper)

        btrfs_root = ctx.target / "btrfs-root"
        btrfs_root.mkdir(parents=True, exist_ok=True)
        _run_disk_cmd(["mount", root_mapper, str(btrfs_root)], f"mounting {root_mapper}")
        try:
            for subvol in ("@", "@home", "@log", "@pkg"):
                _run_disk_cmd(
                    ["btrfs", "subvolume", "create", str(btrfs_root / subvol)],
                    f"creating subvolume {subvol}",
                )
        finally:
            subprocess.run(["umount", str(btrfs_root)], check=False, capture_output=True, text=True)
            try:
                btrfs_root.rmdir()
            except OSError:
                pass

        _run_disk_cmd(
            ["mount", "-o", "noatime,compress=zstd,subvol=@", root_mapper, str(ctx.target)],
            f"mounting target root {ctx.target}",
        )
        esp_target = ctx.target / esp_mount.lstrip("/")
        for rel in ("home", "var/log", "var/cache/pacman/pkg"):
            (ctx.target / rel).mkdir(parents=True, exist_ok=True)
        esp_target.mkdir(parents=True, exist_ok=True)

        for subvol, rel in (("@home", "home"), ("@log", "var/log"), ("@pkg", "var/cache/pacman/pkg")):
            _run_disk_cmd(
                ["mount", "-o", f"noatime,compress=zstd,subvol={subvol}", root_mapper, str(ctx.target / rel)],
                f"mounting /{rel}",
            )

        _run_disk_cmd(["mkfs.fat", "-F32", "-n", "OMARCHY_EFI", efi_dev], f"creating ESP filesystem on {efi_dev}")
        # Typed mount (-t vfat): avoids /proc/filesystems probing squashfs before udev finishes.
        _run_disk_cmd(["mount", "-t", "vfat", efi_dev, str(esp_target)], f"mounting ESP at {esp_target}")

    storage = ctx.omarchy_install.setdefault("storage", {})
    storage["esp_device"] = efi_dev
    storage["root_device"] = root_dev
    storage["root_mapper"] = root_mapper
    storage["luks_uuid"] = luks_uuid

    with _time_step("FS.free_space_verify"):
        verify_protected_mounts(ctx)
        verify_pre_mounted_root_empty(ctx, root_mapper)

    info(f"› free-space layout ready: esp={efi_dev} root={root_dev} mapper={root_mapper}")


def rollback_free_space_parts(ctx) -> None:
    """Idempotently delete ONLY the partitions created by `execute_free_space_plan`,
    highest number first, leaving all pre-existing OS partitions untouched."""
    state = getattr(ctx, "state", None)
    if not isinstance(state, dict):
        return
    created = state.get("free_space_created_parts")
    if not isinstance(created, dict):
        return
    parts = created.get("parts") or []
    disk = created.get("disk")
    if not disk or not parts:
        return
    for num in sorted({int(n) for n in parts}, reverse=True):
        subprocess.run(["parted", "--script", str(disk), "rm", str(num)], check=False, capture_output=True, text=True)
    subprocess.run(["partprobe", str(disk)], check=False, capture_output=True, text=True)
    settle_disk_devices(str(disk))
    parts.clear()
