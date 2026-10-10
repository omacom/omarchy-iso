"""ARM platform requirements shared by offline builds and target installation."""

from __future__ import annotations

import json
import platform
import re
import sys
from pathlib import Path

MANIFEST = Path("/usr/share/omarchy-iso/platforms.json")
MEDIA_TARGET = Path("/root/omarchy_media_target")
DMI = Path("/sys/class/dmi/id")
# The N1x image is built for that one laptop family and has no entry of its own:
# its setup lives in the runtime. It still records its target, so every aarch64
# image reads the manifest the same way.
TARGETS = {"aarch64/snapdragon", "aarch64/generic", "aarch64/n1x"}
BOOT_CONFIG = Path("etc/limine-entry-tool.d/80-omarchy-aarch64-platform.conf")


def load_platforms(manifest: Path) -> list[dict]:
    data = json.loads(manifest.read_text())
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise ValueError("Unsupported ARM platform manifest schema")
    platforms = data.get("platforms")
    if not isinstance(platforms, list):
        raise ValueError("ARM platform manifest must contain a platform list")

    ids = set()
    identities = set()
    for entry in platforms:
        if not isinstance(entry, dict):
            raise ValueError("Invalid ARM platform entry")
        identifier = entry.get("id")
        if not isinstance(identifier, str) or not re.fullmatch(r"[a-z0-9-]+", identifier):
            raise ValueError("Invalid ARM platform ID")
        if identifier in ids:
            raise ValueError(f"Duplicate ARM platform ID: {identifier}")
        ids.add(identifier)
        if not isinstance(entry.get("name"), str) or not entry["name"].strip():
            raise ValueError(f"Missing name for ARM platform {identifier}")
        if entry.get("media_target") not in TARGETS:
            raise ValueError(f"Invalid media target for {identifier}")
        matches = entry.get("match")
        if not isinstance(matches, list) or not matches:
            raise ValueError(f"Missing hardware identity for {identifier}")
        for match in matches:
            if not isinstance(match, dict) or set(match) != {"sys_vendor", "product_name"}:
                raise ValueError(f"Expected vendor and product identity for {identifier}")
            if any(not isinstance(value, str) or not value.strip() for value in match.values()):
                raise ValueError(f"Empty hardware identity for {identifier}")
            identity = (match["sys_vendor"], match["product_name"])
            if identity in identities:
                raise ValueError(f"Ambiguous hardware identity: {identity}")
            identities.add(identity)
        for field, pattern in (("packages", r"[a-z0-9][a-z0-9@._+-]*"),
                               ("kernel_cmdline", r"[a-zA-Z0-9_.=/,:+-]+")):
            values = entry.get(field)
            if not isinstance(values, list) or any(
                not isinstance(value, str) or not re.fullmatch(pattern, value) for value in values
            ):
                raise ValueError(f"Invalid {field} for {identifier}")
    return platforms


def select_platform(platforms: list[dict], dmi: Path, media_target: str) -> dict | None:
    if media_target not in TARGETS:
        raise ValueError(f"Unsupported ARM media target: {media_target}")
    try:
        identity = {field: (dmi / field).read_text().strip() for field in ("sys_vendor", "product_name")}
    except FileNotFoundError:
        # Generic UEFI guests may have no SMBIOS product identity.
        return None
    for entry in platforms:
        if identity in entry["match"]:
            if entry["media_target"] != media_target:
                raise ValueError(f"{entry['name']} requires {entry['media_target']} media")
            return entry
    return None


def detect_platform() -> dict | None:
    if platform.machine() != "aarch64":
        return None
    return select_platform(load_platforms(MANIFEST), DMI, MEDIA_TARGET.read_text().strip())


def configure_boot(target: Path, entry: dict | None) -> None:
    if not entry or not entry["kernel_cmdline"]:
        return
    config = target / BOOT_CONFIG
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(
        f"# Omarchy platform {entry['id']}\n"
        f"KERNEL_CMDLINE[default]+=\" {' '.join(entry['kernel_cmdline'])}\"\n"
    )


def offline_packages(platforms: list[dict], media_target: str) -> list[str]:
    if media_target not in TARGETS:
        raise ValueError(f"Unsupported ARM media target: {media_target}")
    return sorted({package for entry in platforms if entry["media_target"] == media_target
                   for package in entry["packages"]})


if __name__ == "__main__":
    # Used by build-iso.sh before any packages are downloaded. The installer
    # reads the same validated manifest and installs only its matched profile.
    for package in offline_packages(load_platforms(Path(sys.argv[1])), sys.argv[2]):
        print(package)
