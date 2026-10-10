"""Region selection: which of the runtime's region profiles a target gets.

The builder copies every profile from the bundled runtime's default/regions/
into REGIONS_DIR, and their packages into the offline mirror. Nobody picks a
region by hand: the timezone the user already chose selects it, and an
autoinstall config may name one explicitly in omarchy_install.region. Run as
`python -m orchestrator.region <timezone>` to print the region the installer
would use, which is how the configurator fills its summary.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REGIONS_DIR = Path("/usr/share/omarchy-iso/regions")
GLOBAL = "global"


def _entries(path: Path) -> list[str]:
    if not path.is_file():
        return []
    lines = (line.strip() for line in path.read_text().splitlines())
    return [line for line in lines if line and not line.startswith("#")]


def region_for_timezone(timezone: str | None, regions_dir: Path | None = None) -> str:
    regions_dir = regions_dir or REGIONS_DIR
    if timezone and regions_dir.is_dir():
        for profile in sorted(regions_dir.iterdir()):
            if timezone in _entries(profile / "timezones"):
                return profile.name
    return GLOBAL


def resolve_region(omarchy_install: dict, timezone: str | None, regions_dir: Path | None = None) -> str:
    regions_dir = regions_dir or REGIONS_DIR
    region = omarchy_install.get("region")
    if region is None or region == "":
        return region_for_timezone(timezone, regions_dir)
    # Profiles are named by ISO 3166-1 alpha-2 code; checking the shape first
    # keeps a path like ".." from passing the directory test.
    if not isinstance(region, str) or (
        region != GLOBAL and not (re.fullmatch(r"[a-z]{2}", region) and (regions_dir / region).is_dir())
    ):
        raise RuntimeError(f"Unsupported region: {region!r}")
    return region


def region_packages(region: str, regions_dir: Path | None = None) -> list[str]:
    if region == GLOBAL:
        return []
    return _entries((regions_dir or REGIONS_DIR) / region / "packages")


def region_keyrings(region: str, regions_dir: Path | None = None) -> list[str]:
    """Pacman keyrings the profile ships, named the Arch way: <name>-keyring
    installs /usr/share/pacman/keyrings/<name>.gpg."""
    return [
        package.removesuffix("-keyring")
        for package in region_packages(region, regions_dir)
        if package.endswith("-keyring")
    ]


if __name__ == "__main__":
    print(region_for_timezone(sys.argv[1] if len(sys.argv) > 1 else None))
