"""Region selection: which of the runtime's region profiles a target gets.

The builder copies every profile from the bundled runtime's default/regions/
into REGIONS_DIR; a profile only reorders mirrors. Nobody picks a
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
# Hong Kong, Macau and Taiwan are never part of a region, under any of
# tzdata's names, whatever install media or profile says.
NEVER_REGIONAL = frozenset({"Asia/Hong_Kong", "Hongkong", "Asia/Macau", "Asia/Macao", "Asia/Taipei", "ROC"})


def _entries(path: Path) -> list[str]:
    if not path.is_file():
        return []
    lines = (line.strip() for line in path.read_text().splitlines())
    return [line for line in lines if line and not line.startswith("#")]


def region_for_timezone(timezone: str | None, regions_dir: Path | None = None) -> str:
    regions_dir = regions_dir or REGIONS_DIR
    if timezone and timezone not in NEVER_REGIONAL and regions_dir.is_dir():
        for profile in sorted(regions_dir.iterdir()):
            if timezone in _entries(profile / "timezones"):
                return profile.name
    return GLOBAL


def resolve_region(omarchy_install: dict, timezone: str | None, regions_dir: Path | None = None, preset: str | None = None) -> str:
    regions_dir = regions_dir or REGIONS_DIR
    region = omarchy_install.get("region")
    if region is None or region == "":
        return region_for_install(timezone, preset, regions_dir)
    # Profiles are named by ISO 3166-1 alpha-2 code; checking the shape first
    # keeps a path like ".." from passing the directory test.
    if not isinstance(region, str) or (
        region != GLOBAL and not (re.fullmatch(r"[a-z]{2}", region) and (regions_dir / region).is_dir())
    ):
        raise RuntimeError(f"Unsupported region: {region!r}")
    return region


def region_for_install(timezone: str | None, preset: str | None = None, regions_dir: Path | None = None) -> str:
    """A preset ISO's region applies where the chosen timezone names no
    region, including UTC and other countries' timezones; Hong Kong, Macau and
    Taiwan always stay global."""
    regions_dir = regions_dir or REGIONS_DIR
    region = region_for_timezone(timezone, regions_dir)
    if region != GLOBAL or not preset or timezone in NEVER_REGIONAL:
        return region
    return preset if preset == GLOBAL or (re.fullmatch(r"[a-z]{2}", preset) and (regions_dir / preset).is_dir()) else GLOBAL



def region_packages(region: str, regions_dir: Path | None = None) -> tuple[list[str], list[str]]:
    """The packages a region's profile leaves out of and adds to the defaults
    (packages-skip, packages-add); global and profiles without them change nothing."""
    regions_dir = regions_dir or REGIONS_DIR
    if region == GLOBAL or not re.fullmatch(r"[a-z]{2}", region):
        return [], []
    profile = regions_dir / region
    return _entries(profile / "packages-skip"), _entries(profile / "packages-add")

if __name__ == "__main__":
    print(region_for_install(sys.argv[1] if len(sys.argv) > 1 else None, sys.argv[2] if len(sys.argv) > 2 else None))
