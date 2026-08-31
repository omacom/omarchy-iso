"""Offline target keyboard configuration.

archinstall's set_keyboard_language boots the installed system in a
systemd-nspawn container just to run localectl. systemd-firstboot --root
produces the part of that output Omarchy actually consumes — KEYMAP for the
console plus the XKB* settings in vconsole.conf that omarchy's
detect-keyboard-layout.sh copies into Hyprland's kb_layout — without booting
anything. The Xorg 00-keyboard.conf that localectl also writes is not
generated: nothing on an Omarchy system reads it.
"""

from __future__ import annotations

import re
from pathlib import Path

from .command import capture

_XKB_ONLY_RE = re.compile(r'^OMARCHY_XKB_ONLY_LAYOUTS="([^"]*)"', re.MULTILINE)


def setup_form_candidates() -> tuple[Path, ...]:
    """Places the shared picker list is vendored or checked out.

    Live ISO: setup-form.sh sits beside this package at
    /usr/share/omarchy-iso/setup-form.sh. A developer checkout also looks at a
    sibling omarchy tree before the installed runtime, so tests see unreleased
    picker changes rather than /usr/share/omarchy.
    """
    here = Path(__file__).resolve()
    paths = [here.parent.parent / "setup-form.sh"]
    for parent in here.parents:
        if parent.name == "omarchy-iso" and (parent / "configs").is_dir():
            paths.append(parent.parent / "omarchy/install/provisioning/setup-form.sh")
            break
    paths.append(Path("/omarchy-source/install/provisioning/setup-form.sh"))
    paths.append(Path("/usr/share/omarchy/install/provisioning/setup-form.sh"))
    return tuple(paths)


def xkb_only_layouts() -> set[str]:
    """Picker values that are XKB layouts, not kbd console keymaps."""
    for candidate in setup_form_candidates():
        if not candidate.is_file():
            continue
        match = _XKB_ONLY_RE.search(candidate.read_text())
        if match:
            return {part for part in match.group(1).split() if part}
    return set()


def _set_vconsole_key(path: Path, key: str, value: str) -> None:
    prefix = f"{key}="
    lines = path.read_text().splitlines() if path.exists() else []
    replaced = False
    new_lines = []
    for line in lines:
        if line.startswith(prefix):
            new_lines.append(f"{prefix}{value}")
            replaced = True
        else:
            new_lines.append(line)
    if not replaced:
        new_lines.append(f"{prefix}{value}")
    path.write_text("\n".join(new_lines) + "\n")


def configure_keyboard(target: Path, language: str) -> bool:
    """Write the console keymap into a mounted target without booting it.

    Returns False for layouts localectl doesn't know, matching archinstall:
    warn and keep the default. The guard is for the kb_layout an autoinstall
    drive can name freely.

    A few picker values (OMARCHY_XKB_ONLY_LAYOUTS in setup-form.sh) are XKB
    layouts kbd does not ship. Those persist KEYMAP=us so LUKS and the console
    stay Latin, then XKBLAYOUT is pointed at the chosen layout for Hyprland.
    """
    if not language.strip():
        return True

    result = capture(["localectl", "--no-pager", "list-keymaps"])
    if result.returncode != 0:
        detail = result.stderr.strip() or "localectl returned an error"
        raise RuntimeError(f"Unable to list keyboard layouts: {detail}")
    known = language.lower() in {layout.lower() for layout in result.stdout.splitlines()}
    xkb_only = language.lower() in {name.lower() for name in xkb_only_layouts()}
    if not known and not xkb_only:
        return False

    console_keymap = "us" if xkb_only else language

    # systemd-firstboot --force rewrites vconsole.conf wholesale, dropping the
    # FONT= line archinstall's set_vconsole wrote earlier.
    vconsole_path = target / "etc" / "vconsole.conf"
    font = None
    if vconsole_path.exists():
        font = next(
            (line for line in vconsole_path.read_text().splitlines() if line.startswith("FONT=")),
            None,
        )

    result = capture(["systemd-firstboot", f"--root={target}", f"--keymap={console_keymap}", "--force"])
    if result.returncode != 0:
        detail = result.stderr.strip() or "systemd-firstboot returned an error"
        raise RuntimeError(f"Unable to configure keyboard layout {language}: {detail}")

    if font:
        vconsole_path.write_text(vconsole_path.read_text() + font + "\n")

    if xkb_only:
        _set_vconsole_key(vconsole_path, "XKBLAYOUT", language)

    return True
