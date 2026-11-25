"""Offline target keyboard configuration.

archinstall's set_keyboard_language boots the installed system in a
systemd-nspawn container just to run localectl. systemd-firstboot --root
produces the part of that output Omarchy actually consumes without booting
anything. That part is KEYMAP for the console and the XKB* settings in
vconsole.conf, which Omarchy's default/hypr/keyboard.lua reads for Hyprland's
kb_layout. The Xorg 00-keyboard.conf that localectl also writes is not
generated: nothing on an Omarchy system reads it.
"""

from __future__ import annotations

import os
from pathlib import Path

from .command import capture


def setup_form_path() -> Path | None:
    """Find the shared setup form, as the configurator does."""
    omarchy_path = os.environ.get("OMARCHY_PATH") or "/nonexistent"
    candidates = (
        os.environ.get("SETUP_FORM", ""),
        "/usr/share/omarchy-iso/setup-form.sh",
        str(Path(omarchy_path) / "install/provisioning/setup-form.sh"),
    )
    return next((Path(path) for path in candidates if path and Path(path).is_file()), None)


def fallback_xkb_settings(keymap: str) -> str:
    """Return the XKB lines that the Omarchy setup form gives a keymap.

    systemd-firstboot writes XKBLAYOUT only for keymaps in kbd-model-map.
    The setup form holds the settings for the keymaps that it lacks, and
    first-boot setup adds the same lines. Returns an empty string for a keymap
    that the form has no settings for, and when the form predates
    omarchy_keymap_xkb_settings.
    """
    form = setup_form_path()
    if form is None:
        return ""
    result = capture(["bash", "-c", 'source "$1" && omarchy_keymap_xkb_settings "$2"', "bash", str(form), keymap])
    return result.stdout if result.returncode == 0 else ""


def configure_keyboard(target: Path, language: str, input_method: str | None = None, xkb_layout: str = "") -> bool:
    """Write the console keymap into a mounted target without booting it.

    Returns False for layouts localectl doesn't know, matching archinstall:
    warn and keep the default. Every layout the configurator offers is known;
    the guard is for the kb_layout an autoinstall drive can name freely.
    """
    validate_input_selection(input_method, xkb_layout)
    if not language.strip():
        if input_method is None:
            return True
        language = "us"

    # Input engines are separate from real console keymaps. The shared picker
    # uses US for Chinese/Korean and carries its preference in omarchy_install.
    if input_method is None:
        input_method = "mozc" if language == "jp106" else "none"

    result = capture(["localectl", "--no-pager", "list-keymaps"])
    if result.returncode != 0:
        detail = result.stderr.strip() or "localectl returned an error"
        raise RuntimeError(f"Unable to list keyboard layouts: {detail}")
    if language.lower() not in {layout.lower() for layout in result.stdout.splitlines()}:
        if input_method != "none":
            raise ValueError(f"Unknown keyboard language: {language}")
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

    # Hyprland reads XKBLAYOUT from this file. Without it the desktop types US
    # while the console and the disk password prompt use the chosen layout.
    if not any(line.startswith("XKBLAYOUT=") and len(line) > len("XKBLAYOUT=") for line in vconsole_path.read_text().splitlines()):
        extra = fallback_xkb_settings(language)
        if extra:
            vconsole_path.write_text(vconsole_path.read_text() + extra)

    preference = target / "etc/omarchy/input-method"
    preference.parent.mkdir(parents=True, exist_ok=True)
    preference.write_text(f"INPUT_METHOD={input_method}\nXKB_LAYOUT={xkb_layout}\n")

    return True


def validate_input_selection(input_method: str | None, xkb_layout: str) -> None:
    if input_method is not None and input_method not in {"none", "mozc", "hangul", "pinyin", "chewing", "cangjie5"}:
        raise ValueError(f"Unknown input method: {input_method}")
    if xkb_layout not in {"", "kr", "kr:kr104", "la"}:
        raise ValueError(f"Unknown input keyboard layout: {xkb_layout}")
