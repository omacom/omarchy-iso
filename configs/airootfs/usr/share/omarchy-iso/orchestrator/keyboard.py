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

from pathlib import Path

from .command import capture


def configure_keyboard(target: Path, language: str) -> bool:
    """Write the console keymap into a mounted target without booting it.

    Returns False for layouts the installed kbd package doesn't know, matching archinstall:
    warn and keep the default. Every layout the configurator offers is known;
    the guard is for the kb_layout an autoinstall drive can name freely.
    """
    if not language.strip():
        return True

    if language.casefold() not in _installed_keymaps(target):
        return False

    # systemd-firstboot --force rewrites vconsole.conf wholesale, dropping the
    # FONT= line archinstall's set_vconsole wrote earlier.
    vconsole_path = target / "etc" / "vconsole.conf"
    font = None
    if vconsole_path.exists():
        font = next(
            (line for line in vconsole_path.read_text().splitlines() if line.startswith("FONT=")),
            None,
        )

    result = capture(["systemd-firstboot", f"--root={target}", f"--keymap={language}", "--force"])
    if result.returncode != 0:
        detail = result.stderr.strip() or "systemd-firstboot returned an error"
        raise RuntimeError(f"Unable to configure keyboard layout {language}: {detail}")

    if font:
        vconsole_path.write_text(vconsole_path.read_text() + font + "\n")

    return True


def _installed_keymaps(target: Path) -> set[str]:
    """Return console keymap names from the mounted target's kbd package.

    Host `localectl list-keymaps` talks to PID 1 and therefore fails in image
    builders that are not booted with systemd. The target has already been
    pacstrapped at this point, so its keymap files are the authoritative catalog
    for the system being built and require no live service.
    """
    roots = (
        target / "usr/share/kbd/keymaps",
        target / "usr/lib/kbd/keymaps",
    )
    existing_roots = [root for root in roots if root.is_dir()]
    if not existing_roots:
        raise RuntimeError("Unable to list keyboard layouts: target kbd keymaps are missing")

    layouts: set[str] = set()
    for root in existing_roots:
        for path in root.rglob("*.map*"):
            name = path.name
            for suffix in (".gz", ".bz2", ".xz", ".zst"):
                if name.endswith(suffix):
                    name = name[: -len(suffix)]
                    break
            if name.endswith(".map"):
                layouts.add(name[:-4].casefold())
    return layouts
