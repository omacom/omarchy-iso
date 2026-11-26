"""Region selection: which of the runtime's region profiles a target gets.

The live ISO carries the runtime's profiles (default/regions/ of the bundled
settings package); a profile only reorders mirrors. Nobody picks a region by
hand. The media's region is the preset's (--preset), or global. The timezone
the user already chose settles it, as docs/regions.md in the runtime defines:
a timezone a profile lists picks that profile (global lists Hong Kong, Macau
and Taiwan), and any other timezone keeps the media's region. An autoinstall
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


def _entries(path: Path) -> list[str]:
    if not path.is_file():
        return []
    lines = (line.strip() for line in path.read_text().splitlines())
    return [line for line in lines if line and not line.startswith("#")]


def _validate(region: object) -> str:
    # Profiles are named by ISO 3166-1 alpha-2 code; checking the shape first
    # keeps a path like ".." from passing the directory test.
    if not isinstance(region, str) or (
        region != GLOBAL and not (re.fullmatch(r"[a-z]{2}", region) and (REGIONS_DIR / region).is_dir())
    ):
        raise RuntimeError(f"Unsupported region: {region!r}")
    return region


def resolve_region(omarchy_install: dict, timezone: str | None) -> str:
    region = omarchy_install.get("region")
    if region not in (None, ""):
        return _validate(region)
    media = json.loads(PRESET.read_text()).get("region") if PRESET.is_file() else None
    fallback = _validate(media) if media else GLOBAL
    if timezone and REGIONS_DIR.is_dir():
        for profile in sorted(REGIONS_DIR.iterdir()):
            if timezone in _entries(profile / "timezones"):
                return profile.name
    return fallback


if __name__ == "__main__":
    print(resolve_region({}, sys.argv[1] if len(sys.argv) > 1 else None))
