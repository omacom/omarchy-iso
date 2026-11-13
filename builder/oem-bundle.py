#!/usr/bin/python
"""Check an OEM's bundle and lay it out for the ISO build.

Usage: oem-bundle.py <output-dir> [--config oem.json] [--script setup.sh]...

The config names what first-boot setup shows a machine's owner:

    {
      "name": "Acme Computers",
      "logo": "logo.txt",
      "tagline": "Acme Book 14, powered by Omarchy",
      "color": "#ff9e64",
      "eula": {"title": "Acme Computers License Agreement", "file": "eula.txt"}
    }

Only the name is required, and paths are relative to the config. The scripts
run as root in the installed system, in the order given.

Setup is drawn on the Linux console, in a 512-glyph font and sixteen colours,
so the logo is text and everything is checked here against what that console
can draw: a mistake stops the build, not a machine's first boot. The logo
heads setup's opening screen and its agreement; a logo in braille dots has
them added to the font there, in glyphs the text beside it leaves free. The output
is what the installer reads from /usr/share/omarchy-iso/oem: oem.json (name,
tagline, color, eula_title), logo.txt, eula.txt and scripts/NN-name.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

# The column setup is laid out in, which is the Omarchy logo's width.
COLUMN = 81
LOGO_MAX_ROWS = 12
NAME_MAX = 60

# Every character the console font draws: Terminus (ter-v16b and ter-v32b, the
# same 512 glyphs) as console-font.py patches it. Latin, Greek and Cyrillic
# with their punctuation; CJK, Arabic, Hebrew, the Indic scripts, Thai and
# Vietnamese are beyond it. test_oem_bundle.py holds this to the font itself.
CONSOLE_GLYPHS = (
    "0020-007E 00A0-0107 010C-0113 0116-011B 011E-011F 0122-0123 0127-012B 012E-0131 0136-0148 014A-014D "
    "0150-015B 015E-0165 0168-016B 016E-0175 0178-017E 0186 018F-0190 0192 019D 0218-021B 0232-0233 0254 "
    "0259 025B 0272 02BB-02BD 02C6-02C7 02D8-02D9 02DB-02DD 0301-0303 0306 030C 0384-0386 0388-038A 038C "
    "038E-03A1 03A3-03CE 03F2-03F4 0400-045F 0490-0493 0496-049D 04A0-04A3 04AA-04AB 04AE-04B3 04B6-04BB "
    "04C0 04CF-04D5 04D8-04D9 04E2-04E3 04E6-04E9 04EE-04F1 1EBD 1EF9 2000-200A 2010-2015 2018-201A "
    "201C-201E 2020-2022 2026 202F-2030 2039-203A 207F 20AC 210E-210F 2116 2122 2126 2190-2193 2205-2206 "
    "2208 220A 2212 2219-221A 221E 2229 2248 2261 2264-2265 2310 2320-2321 2500-2503 250C 2510 2514 2518 "
    "251C 2524 252C 2534 253C 256A 256C-2570 2580 2584 2588 2591-2593 25A0 25B2 25B6 25BA 25BC 25C0 25C4 "
    "25C6 2666 2713"
)
CONSOLE_TEXT = {
    chr(codepoint)
    for first, _, last in (span.partition("-") for span in CONSOLE_GLYPHS.split())
    for codepoint in range(int(first, 16), int(last or first, 16) + 1)
}

# What a logo is drawn with: ASCII, that font's blocks and lines, and braille
# dots, which the runtime's console-font.py draws into the font for the screens
# that show the logo.
BRAILLE = set(map(chr, range(0x2800, 0x2900)))
LOGO_CHARACTERS = set(map(chr, range(0x20, 0x7F))) | set("▀▄█░▒▓─│┌┐└┘├┤┬┴┼") | BRAILLE

# A logo's dot patterns take glyphs from the font, so they and the characters
# of the text shown with them share what setup's own strings leave: 512 glyphs
# less ASCII, what setup draws its screens with, and one language's catalog,
# which is under 70 characters more in any language the console draws.
LOGO_DOTS_MAX = 128
DOTS_AND_TEXT_MAX = 256

CONFIG_KEYS = {"name", "logo", "tagline", "color", "eula"}
EULA_KEYS = {"title", "file"}


class BundleError(Exception):
    pass


def undrawable(text: str) -> str | None:
    """The first character the setup console cannot show, if any."""
    return next((char for char in text if char not in CONSOLE_TEXT), None)


def describe(char: str) -> str:
    name = unicodedata.name(char, "")
    shown = f"'{char}'" if char.isprintable() else repr(char)
    return f"{shown} (U+{ord(char):04X}{' ' + name if name else ''})"


def one_line(config: dict, key: str, where: str, limit: int) -> str | None:
    if key not in config:
        return None
    value = config[key]
    if not isinstance(value, str) or not value.strip():
        raise BundleError(f"{where}: \"{key}\" must be a line of text")
    value = value.strip()
    if (char := undrawable(value)) is not None:
        raise BundleError(f"{where}: \"{key}\" has {describe(char)}, which the setup console cannot draw")
    if len(value) > limit:
        raise BundleError(f"{where}: \"{key}\" is {len(value)} characters; the limit is {limit}")
    return value


def read_text(path: Path, what: str) -> str:
    if not path.is_file():
        raise BundleError(f"{what} not found at {path}")
    try:
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError as error:
        raise BundleError(f"{path}: {what} must be UTF-8 text ({error.reason} at byte {error.start})") from error


def check_logo(path: Path) -> str:
    # A blank braille cell is a space, as chafa writes one.
    text = read_text(path, "the logo").replace("\r\n", "\n").replace("\u2800", " ")
    rows = [row.rstrip() for row in text.split("\n")]
    while rows and not rows[-1]:
        rows.pop()
    while rows and not rows[0]:
        rows.pop(0)
    if not rows:
        raise BundleError(f"{path}: the logo is empty")
    for number, row in enumerate(rows, 1):
        for char in row:
            if char not in LOGO_CHARACTERS:
                raise BundleError(
                    f"{path}: row {number} has {describe(char)}. The setup console draws a logo from ASCII, "
                    "the characters ▀ ▄ █ ░ ▒ ▓ ─ │ ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ and braille dots"
                )
        if len(row) > COLUMN:
            raise BundleError(f"{path}: row {number} is {len(row)} columns wide; the logo fits in {COLUMN}")
    if len(rows) > LOGO_MAX_ROWS:
        raise BundleError(f"{path}: the logo is {len(rows)} rows tall; the limit is {LOGO_MAX_ROWS}")
    if (dots := len(BRAILLE.intersection("".join(rows)))) > LOGO_DOTS_MAX:
        raise BundleError(f"{path}: the logo uses {dots} different dot patterns; the console font has room for {LOGO_DOTS_MAX}")
    return "\n".join(rows) + "\n"


def check_eula(path: Path) -> str:
    text = read_text(path, "the agreement").replace("\r\n", "\n").replace("\r", "\n")
    rows = [row.rstrip() for row in text.expandtabs(4).split("\n")]
    while rows and not rows[-1]:
        rows.pop()
    while rows and not rows[0]:
        rows.pop(0)
    if not rows:
        raise BundleError(f"{path}: the agreement is empty")
    for number, row in enumerate(rows, 1):
        if (char := undrawable(row)) is not None:
            raise BundleError(
                f"{path}: line {number} has {describe(char)}. The setup console draws Latin, Greek and "
                "Cyrillic text; an agreement in another script cannot be shown there"
            )
    return "\n".join(rows) + "\n"


def check_config(path: Path) -> tuple[dict, dict[str, str]]:
    """The config as the installed system reads it, and the text files beside it."""
    where = path.name
    try:
        config = json.loads(read_text(path, "the OEM config"))
    except json.JSONDecodeError as error:
        raise BundleError(f"{path}: not JSON: {error}") from error
    if not isinstance(config, dict):
        raise BundleError(f"{where}: must be a JSON object")
    if unknown := sorted(set(config) - CONFIG_KEYS):
        raise BundleError(f"{where}: unknown key \"{unknown[0]}\"; it takes {', '.join(sorted(CONFIG_KEYS))}")

    staged: dict = {}
    files: dict[str, str] = {}
    if (name := one_line(config, "name", where, NAME_MAX)) is None:
        raise BundleError(f"{where}: \"name\" is required")
    staged["name"] = name
    if (tagline := one_line(config, "tagline", where, COLUMN)) is not None:
        staged["tagline"] = tagline

    if "color" in config:
        color = config["color"]
        if not isinstance(color, str) or not re.fullmatch(r"#[0-9A-Fa-f]{6}", color):
            raise BundleError(f"{where}: \"color\" must be a colour like #ff9e64")
        staged["color"] = color.lower()

    if "logo" in config:
        if not isinstance(config["logo"], str) or not config["logo"]:
            raise BundleError(f"{where}: \"logo\" must be the path of a text file")
        files["logo.txt"] = check_logo(path.parent / config["logo"])

    if "eula" in config:
        eula = config["eula"]
        if not isinstance(eula, dict):
            raise BundleError(f"{where}: \"eula\" must be an object with a \"file\" and an optional \"title\"")
        if unknown := sorted(set(eula) - EULA_KEYS):
            raise BundleError(f"{where}: unknown key \"{unknown[0]}\" in \"eula\"; it takes {', '.join(sorted(EULA_KEYS))}")
        if not isinstance(eula.get("file"), str) or not eula["file"]:
            raise BundleError(f"{where}: \"eula\" needs a \"file\", the path of the agreement's text")
        if (title := one_line(eula, "title", f"{where} eula", COLUMN)) is not None:
            staged["eula_title"] = title
        files["eula.txt"] = check_eula(path.parent / eula["file"])

    dots = BRAILLE.intersection(files.get("logo.txt", ""))
    text = {char for char in "".join([*staged.values(), files.get("eula.txt", "")]) if ord(char) > 0x7E}
    if dots and len(dots) + len(text) > DOTS_AND_TEXT_MAX:
        raise BundleError(
            f"{where}: the logo's {len(dots)} dot patterns and the {len(text)} characters beyond ASCII in the text "
            f"shown with it do not fit the console font together; the limit is {DOTS_AND_TEXT_MAX}"
        )

    return staged, files


def check_script(path: Path) -> bytes:
    if not path.is_file():
        raise BundleError(f"OEM script not found at {path}")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", path.name):
        raise BundleError(f"{path}: a script's name may have letters, digits, dots, dashes and underscores")
    result = subprocess.run(["bash", "-n", "--", str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        raise BundleError(f"{path}: not a bash script that parses:\n{result.stderr.strip()}")
    return path.read_bytes()


def stage(output: Path, config: Path | None, scripts: list[Path]) -> None:
    if config is None and not scripts:
        raise BundleError("an OEM bundle needs a config, a script, or both")
    if len(scripts) > 99:
        raise BundleError("an OEM bundle takes at most 99 scripts")

    staged, files = check_config(config) if config else ({}, {})
    bodies = [(script.name, check_script(script)) for script in scripts]

    output.mkdir(parents=True, exist_ok=True)
    if staged:
        (output / "oem.json").write_text(json.dumps(staged, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")
    for name, text in files.items():
        (output / name).write_text(text, encoding="utf-8")
    if bodies:
        (output / "scripts").mkdir()
        for order, (name, body) in enumerate(bodies, 1):
            (output / "scripts" / f"{order:02d}-{name}").write_bytes(body)


def main() -> int:
    parser = argparse.ArgumentParser(description="Check an OEM's bundle and lay it out for the ISO build.")
    parser.add_argument("output", type=Path)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--script", type=Path, action="append", default=[])
    args = parser.parse_args()
    try:
        stage(args.output, args.config, args.script)
    except BundleError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
