"""Region selection: which of the runtime's region profiles a target gets.

The live ISO carries the runtime's profiles (default/regions/ of the bundled
settings package); a profile only reorders mirrors. Nobody picks a region by
hand. The media's region is the preset's (--preset), or global. The timezone
the user already chose settles it, as docs/regions.md in the runtime defines:
a timezone a profile lists picks that profile, Hong Kong, Macau and Taiwan are
always global, and any other timezone keeps the media's region. An autoinstall
config may name one explicitly in omarchy_install.region. Run as
`python -m orchestrator.region <timezone>` to print the region the installer
would use, which is how the configurator fills its summary.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REGIONS_DIR = Path("/usr/share/omarchy/default/regions")
PRESET = Path("/usr/share/omarchy-iso/preset.json")
GLOBAL = "global"

# Every tzdata name for Hong Kong, Macau and Taiwan, the same list as the
# runtime's first-boot configure_region (omarchy-provision-owner).
ALWAYS_GLOBAL = frozenset({"Asia/Hong_Kong", "Hongkong", "Asia/Macau", "Asia/Macao", "Asia/Taipei", "ROC"})


def _entries(path: Path) -> list[str]:
    if not path.is_file():
        return []
    lines = (line.strip() for line in path.read_text().splitlines())
    return [line for line in lines if line and not line.startswith("#")]


def _validate(region: object, regions_dir: Path) -> str:
    # Profiles are named by ISO 3166-1 alpha-2 code; checking the shape first
    # keeps a path like ".." from passing the directory test.
    if not isinstance(region, str) or (
        region != GLOBAL and not (re.fullmatch(r"[a-z]{2}", region) and (regions_dir / region).is_dir())
    ):
        raise RuntimeError(f"Unsupported region: {region!r}")
    return region


def media_region(preset: Path | None = None, regions_dir: Path | None = None) -> str:
    preset = preset or PRESET
    region = json.loads(preset.read_text()).get("region") if preset.is_file() else None
    return _validate(region, regions_dir or REGIONS_DIR) if region else GLOBAL


def region_for_timezone(timezone: str | None, fallback: str = GLOBAL, regions_dir: Path | None = None) -> str:
    regions_dir = regions_dir or REGIONS_DIR
    if timezone in ALWAYS_GLOBAL:
        return GLOBAL
    if timezone and regions_dir.is_dir():
        for profile in sorted(regions_dir.iterdir()):
            if timezone in _entries(profile / "timezones"):
                return profile.name
    return fallback


def resolve_region(
    omarchy_install: dict,
    timezone: str | None,
    regions_dir: Path | None = None,
    preset: Path | None = None,
) -> str:
    regions_dir = regions_dir or REGIONS_DIR
    region = omarchy_install.get("region")
    if region is None or region == "":
        return region_for_timezone(timezone, media_region(preset, regions_dir), regions_dir)
    return _validate(region, regions_dir)


if __name__ == "__main__":
    print(region_for_timezone(sys.argv[1] if len(sys.argv) > 1 else None, media_region()))
