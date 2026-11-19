"""Preserve Apple T2 Broadcom firmware before a full-disk install.

The firmware is legally obtained from the Mac's own macOS volume by
apple-bcm-firmware-fetcher.  The live ISO runs linux-t2, whose APFS driver can
still read that volume before the installer repartitions the disk.  Keep the
extracted files in /run, then copy them into the installed system after its
root image has landed.
"""

from __future__ import annotations

import hashlib
import shutil
import subprocess
from pathlib import Path


PCI_DEVICES = Path("/sys/bus/pci/devices")
FETCHER = Path("/usr/bin/apple-bcm-firmware-fetcher")
LIVE_FIRMWARE = Path("/lib/firmware/brcm")
FETCHER_MANIFEST = Path("/var/lib/apple-bcm-firmware-fetcher/installed-files")
STAGE = Path("/run/omarchy/apple-t2-firmware")
TARGET_FIRMWARE = Path("usr/lib/firmware/brcm")
TARGET_STATE = Path("var/lib/apple-bcm-firmware-fetcher/installed-files")

MAX_FILES = 512
MAX_BYTES = 128 * 1024 * 1024


def is_apple_t2(pci_devices: Path = PCI_DEVICES) -> bool:
    """The exact PCI IDs used by Omarchy and t2linux for the T2 chip."""
    for device in pci_devices.glob("*"):
        try:
            vendor = (device / "vendor").read_text().strip().lower()
            device_id = (device / "device").read_text().strip().lower()
        except OSError:
            continue
        if vendor == "0x106b" and device_id in {"0x1801", "0x1802"}:
            return True
    return False


def _installed_names(manifest: Path, firmware: Path) -> list[str]:
    """Return only flat filenames the fetcher actually installed.

    GNU tar's verbose extraction output is persisted by the fetcher.  Its
    generated names never contain whitespace or directories; accepting that
    deliberately narrow alphabet makes the state file safe to replay even if
    a damaged macOS volume or future fetcher emits surprising output.
    """
    if not manifest.is_file():
        return []

    names: list[str] = []
    seen: set[str] = set()
    allowed = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._,-")
    for line in manifest.read_text(errors="replace").splitlines():
        # A verbose hard-link line may carry explanatory text after the name.
        fields = line.split(maxsplit=1)
        name = fields[0] if fields else ""
        if not name or name in seen or any(char not in allowed for char in name):
            continue
        source = firmware / name
        if source.is_symlink() or not source.is_file():
            continue
        names.append(name)
        seen.add(name)
    return names


def _digest(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def stage_from_macos(
    *,
    pci_devices: Path = PCI_DEVICES,
    fetcher: Path = FETCHER,
    firmware: Path = LIVE_FIRMWARE,
    manifest: Path = FETCHER_MANIFEST,
    stage: Path = STAGE,
) -> int | None:
    """Extract and stage T2 firmware; None means this is not a T2 Mac.

    A zero result is best-effort failure/no firmware.  The caller logs that
    prominently but preserves the installer's existing ability to continue
    when macOS is already gone and firmware will be supplied separately.
    """
    if not is_apple_t2(pci_devices):
        return None
    # A retried install must never reuse an earlier attempt's stage after a
    # new fetch fails or the source volume changes.
    shutil.rmtree(stage, ignore_errors=True)
    if not fetcher.is_file():
        return 0

    result = subprocess.run([str(fetcher)], check=False)
    if result.returncode != 0:
        return 0

    names = _installed_names(manifest, firmware)
    if not names or len(names) > MAX_FILES:
        return 0
    total = sum((firmware / name).stat().st_size for name in names)
    if total > MAX_BYTES:
        return 0

    temporary = stage.with_name(f".{stage.name}.new")
    shutil.rmtree(temporary, ignore_errors=True)
    temporary.mkdir(parents=True)
    try:
        staged_firmware = temporary / "brcm"
        staged_firmware.mkdir()
        for name in names:
            shutil.copy2(firmware / name, staged_firmware / name)
        (temporary / "installed-files").write_text("".join(f"{name}\n" for name in names))

        shutil.rmtree(stage, ignore_errors=True)
        temporary.replace(stage)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return len(names)


def install_into_target(target: Path, stage: Path = STAGE) -> int:
    """Install a previously verified stage and preserve fetcher ownership."""
    staged_firmware = stage / "brcm"
    names = _installed_names(stage / "installed-files", staged_firmware)
    if not names:
        return 0
    if len(names) > MAX_FILES or sum((staged_firmware / name).stat().st_size for name in names) > MAX_BYTES:
        raise RuntimeError("Apple T2 firmware stage exceeds its safety limit")

    destination = target / TARGET_FIRMWARE
    destination.mkdir(parents=True, exist_ok=True)
    for name in names:
        source = staged_firmware / name
        installed = destination / name
        shutil.copy2(source, installed)
        if _digest(source) != _digest(installed):
            raise RuntimeError(f"T2 firmware copy did not verify: {name}")

    state = target / TARGET_STATE
    state.parent.mkdir(parents=True, exist_ok=True)
    state.write_text("".join(f"{name}\n" for name in names))
    return len(names)
