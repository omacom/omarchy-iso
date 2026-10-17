"""Validate A16 firmware staging before the installer writes any disks."""

import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import textwrap


class MissingFirmwareError(RuntimeError):
    pass


def is_a16(compatible: Path = Path("/sys/firmware/devicetree/base/compatible")) -> bool:
    try:
        names = set(compatible.read_bytes().lower().split(b"\0"))
    except OSError:
        return False
    return bool(names & {b"asus,zenbook-a16-ux3607oa", b"asus,ux3607oa"})


def validate_a16_stage(tool: str, stage: Path) -> None:
    result = subprocess.run([tool, "--list-required"], capture_output=True, text=True, check=True)
    missing = set(result.stdout.splitlines())
    if not missing:
        return
    manifest = {}
    try:
        for line in (stage / "manifest").read_text().splitlines():
            fields = line.split(maxsplit=2)
            if len(fields) >= 2:
                manifest[fields[0]] = fields[1]
    except FileNotFoundError:
        pass
    unresolved = []
    for name in sorted(missing):
        path = (stage / name).resolve()
        if not path.is_relative_to(stage.resolve()):
            raise RuntimeError(f"Invalid firmware path: {name}")
        try:
            contents = path.read_bytes()
            digest = hashlib.sha256(contents).hexdigest() if contents else None
        except OSError:
            digest = None
        if digest is None or digest != manifest.get(name):
            unresolved.append(name)
    if unresolved:
        raise MissingFirmwareError(
            "A16 firmware is missing or its staged checksum is invalid: "
            + ", ".join(unresolved)
            + ". Installation stopped before disk cleanup. The A16 firmware "
            "package must supply its DSP images and board calibration. Check the "
            "installer image and its package bundle before retrying."
        )


def prepare_a16_stage(tool: str, stage: Path) -> None:
    """Stage the packaged board firmware before any destructive disk action."""
    subprocess.run(["/usr/lib/asus-zenbook-a16-firmware/activate-calibration"], check=True)
    subprocess.run([tool, "--stage", str(stage), "--stage-installed"], check=True)
    validate_a16_stage(tool, stage)


if __name__ == "__main__":
    try:
        if is_a16():
            tool = shutil.which("qcom-firmware-extract")
            if not tool:
                raise RuntimeError("The installer is missing qcom-firmware-extract.")
            prepare_a16_stage(tool, Path("/run/omarchy/firmware"))
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError, KeyboardInterrupt) as error:
        print("\n" + textwrap.fill(f"Firmware setup stopped: {error}", 76), file=sys.stderr)
        print("Installation has not started.", file=sys.stderr)
        sys.exit(1)
