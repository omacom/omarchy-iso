"""Offline target keyboard configuration."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path


def configure_keyboard(target: Path, language: str) -> bool:
    """Configure a valid console keymap and preserve unsupported layouts."""
    if not language.strip():
        return True

    result = subprocess.run(
        ["localectl", "--no-pager", "list-keymaps"],
        check=False,
        text=True,
        capture_output=True,
        env={**os.environ, "SYSTEMD_COLORS": "0"},
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "localectl returned an error"
        raise RuntimeError(f"Unable to list keyboard layouts: {detail}")
    if language.lower() not in {layout.lower() for layout in result.stdout.splitlines()}:
        return False

    write_keyboard_configuration(target, language)
    return True


def write_keyboard_configuration(target: Path, language: str) -> None:
    """Write systemd console and X11 keymap files into a mounted target."""
    vconsole_path = target / "etc" / "vconsole.conf"
    font = None
    if vconsole_path.exists():
        for line in vconsole_path.read_text().splitlines():
            if line.startswith("FONT="):
                font = line.partition("=")[2]
                break

    result = subprocess.run(
        [
            "systemd-firstboot",
            f"--root={target}",
            f"--keymap={language}",
            "--force",
        ],
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "systemd-firstboot returned an error"
        raise RuntimeError(f"Unable to configure keyboard layout {language}: {detail}")

    lines = vconsole_path.read_text().splitlines()
    if font is not None:
        first_setting = next(
            (index for index, line in enumerate(lines) if not line.startswith("#")),
            len(lines),
        )
        lines.insert(first_setting, f"FONT={font}")
        vconsole_path.write_text("\n".join(lines) + "\n")

    settings = dict(line.split("=", 1) for line in lines if "=" in line)
    xkb_layout = settings.get("XKBLAYOUT")
    xorg_path = target / "etc" / "X11" / "xorg.conf.d" / "00-keyboard.conf"
    if not xkb_layout:
        xorg_path.unlink(missing_ok=True)
        return

    options = [
        ("XkbLayout", xkb_layout),
        ("XkbModel", settings.get("XKBMODEL")),
        ("XkbVariant", settings.get("XKBVARIANT")),
        ("XkbOptions", settings.get("XKBOPTIONS")),
    ]
    xorg_path.parent.mkdir(parents=True, exist_ok=True)
    xorg_path.write_text(
        "# Written by systemd-localed(8), read by systemd-localed and Xorg. It's\n"
        "# probably wise not to edit this file manually. Use localectl(1) to\n"
        "# update this file.\n"
        "Section \"InputClass\"\n"
        "        Identifier \"system-keyboard\"\n"
        "        MatchIsKeyboard \"on\"\n"
        + "".join(
            f'        Option "{name}" "{value}"\n'
            for name, value in options
            if value
        )
        + "EndSection\n"
    )
