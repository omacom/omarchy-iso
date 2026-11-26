#!/usr/bin/python

import re
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import keyboard as KEYBOARD  # noqa: E402

# The layout list lives in the Omarchy runtime now, shared verbatim with the
# first-boot owner setup; build-iso.sh vendors it onto the ISO. Read it from
# wherever this checkout can see a runtime, and skip the coverage test rather
# than fail when none is around (a bare CI checkout of just this repo).
SETUP_FORM_CANDIDATES = (
    Path(os.environ.get("OMARCHY_PATH", "/nonexistent")) / "install/provisioning/setup-form.sh",
    Path("/omarchy-source/install/provisioning/setup-form.sh"),
    ROOT.parent / "omarchy/install/provisioning/setup-form.sh",
    Path("/usr/share/omarchy/install/provisioning/setup-form.sh"),
)


def setup_form() -> Path | None:
    return next((candidate for candidate in SETUP_FORM_CANDIDATES if candidate.is_file()), None)


def supported_keymaps():
    for candidate in SETUP_FORM_CANDIDATES:
        if not candidate.is_file():
            continue
        block = re.search(
            r"OMARCHY_KEYBOARD_LAYOUTS=\$'(.*?)'\n", candidate.read_text(), re.DOTALL
        )
        assert block, f"no layout list in {candidate}"
        return [line.split("|")[1] for line in block.group(1).splitlines()]
    return None


SUPPORTED_KEYMAPS = supported_keymaps()


def localectl_lists_keymaps() -> bool:
    """Whether this host can answer "which keymaps exist".

    The cases below compare the configurator's list against the system's, so
    they need a systemd-booted Arch: localectl reads /usr/share/kbd/keymaps
    and refuses to run at all when PID 1 is not systemd. That is true on the
    live ISO and on a developer's Arch box, and false on a container and on
    the Ubuntu runners the CI lint/unit jobs use. Skip there rather than
    error, so this file can be part of a run on any host."""
    try:
        return KEYBOARD.capture(["localectl", "--no-pager", "list-keymaps"]).returncode == 0
    except Exception:
        return False


LOCALECTL_AVAILABLE = localectl_lists_keymaps()


class FallbackXkbSettingsTest(unittest.TestCase):
    def test_reads_extra_xkb_lines_from_setup_form(self):
        with tempfile.TemporaryDirectory() as directory:
            form = Path(directory) / "setup-form.sh"
            form.write_text(
                "omarchy_keymap_xkb_settings() {\n"
                "  case $1 in\n"
                "    no-latin1) printf 'XKBLAYOUT=no\\nXKBMODEL=pc105\\n' ;;\n"
                "    *) return 1 ;;\n"
                "  esac\n"
                "}\n"
            )
            with mock.patch.dict(os.environ, {"SETUP_FORM": str(form)}):
                self.assertEqual(KEYBOARD.fallback_xkb_settings("no-latin1"), "XKBLAYOUT=no\nXKBMODEL=pc105\n")
                self.assertEqual(KEYBOARD.fallback_xkb_settings("us"), "")

    def test_older_setup_form_without_helper_returns_empty(self):
        with tempfile.TemporaryDirectory() as directory:
            form = Path(directory) / "setup-form.sh"
            form.write_text("OMARCHY_KEYBOARD_LAYOUTS=$'English (US)|us'\n")
            with mock.patch.dict(os.environ, {"SETUP_FORM": str(form)}):
                self.assertEqual(KEYBOARD.fallback_xkb_settings("no-latin1"), "")

    def test_empty_omarchy_path_does_not_resolve_relative_path(self):
        with tempfile.TemporaryDirectory() as directory:
            rel = Path(directory) / "install/provisioning/setup-form.sh"
            rel.parent.mkdir(parents=True)
            rel.write_text("omarchy_keymap_xkb_settings() { echo XKBLAYOUT=no; }\n")
            cwd = os.getcwd()
            try:
                os.chdir(directory)
                real_is_file = Path.is_file
                with mock.patch.dict(os.environ, {"SETUP_FORM": "", "OMARCHY_PATH": ""}), \
                        mock.patch.object(Path, "is_file", new=lambda p: False if str(p) == "/usr/share/omarchy-iso/setup-form.sh" else real_is_file(p)):
                    self.assertIsNone(KEYBOARD.setup_form_path())
            finally:
                os.chdir(cwd)


@unittest.skipUnless(LOCALECTL_AVAILABLE, "localectl cannot list keymaps on this host")
class KeyboardConfigurationTest(unittest.TestCase):
    def target(self, directory: str) -> Path:
        target = Path(directory)
        (target / "etc").mkdir()
        (target / "etc/vconsole.conf").write_text(
            "KEYMAP=us\nFONT=default8x16\n"
        )
        return target

    def test_writes_keymap_and_xkb_settings_and_preserves_font(self):
        # XKBLAYOUT is load-bearing: Omarchy's default/hypr/keyboard.lua reads
        # it for Hyprland's kb_layout on the installed system.
        with tempfile.TemporaryDirectory() as directory:
            target = self.target(directory)
            self.assertTrue(KEYBOARD.configure_keyboard(target, "us"))
            lines = (target / "etc/vconsole.conf").read_text().splitlines()
            self.assertIn("KEYMAP=us", lines)
            self.assertIn("XKBLAYOUT=us", lines)
            self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_all_configurator_keymaps_are_known_to_localectl(self):
        if SUPPORTED_KEYMAPS is None:
            self.skipTest("no Omarchy runtime checkout to read the layout list from")
        for keymap in SUPPORTED_KEYMAPS:
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertTrue(KEYBOARD.configure_keyboard(target, keymap))
                lines = (target / "etc/vconsole.conf").read_text().splitlines()
                self.assertIn(f"KEYMAP={keymap}", lines)
                self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_every_configurator_keymap_ends_with_an_xkb_layout(self):
        # systemd-firstboot writes XKBLAYOUT only for keymaps in kbd-model-map.
        # Without it Hyprland falls back to a US layout on the installed system.
        # The XKB lines come from the same form as the layout list.
        form = setup_form()
        if SUPPORTED_KEYMAPS is None or form is None:
            self.skipTest("no Omarchy runtime checkout to read the layout list from")
        if "omarchy_keymap_xkb_settings" not in form.read_text():
            self.skipTest("the Omarchy runtime predates omarchy_keymap_xkb_settings")
        for keymap in SUPPORTED_KEYMAPS:
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory, \
                    mock.patch.dict(os.environ, {"SETUP_FORM": str(form)}):
                target = self.target(directory)
                self.assertTrue(KEYBOARD.configure_keyboard(target, keymap))
                lines = (target / "etc/vconsole.conf").read_text().splitlines()
                self.assertTrue(
                    any(line.startswith("XKBLAYOUT=") and len(line) > 10 for line in lines),
                    f"no XKBLAYOUT for {keymap}: {lines}",
                )

    def test_unknown_and_empty_keymaps_match_archinstall_behavior(self):
        for keymap, expected in (("definitely-not-a-keymap", False), ("", True)):
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertEqual(KEYBOARD.configure_keyboard(target, keymap), expected)
                self.assertEqual(
                    (target / "etc/vconsole.conf").read_text(),
                    "KEYMAP=us\nFONT=default8x16\n",
                )

    def test_input_choice_survives_while_console_keymap_stays_real(self):
        for method, keymap, layout in (("mozc", "jp106", ""), ("mozc", "us", ""), ("hangul", "us", "kr"), ("hangul", "us", "kr:kr104"), ("none", "us", "la"), ("pinyin", "us", ""), ("chewing", "us", ""), ("cangjie5", "us", "")):
            with self.subTest(method=method), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertTrue(KEYBOARD.configure_keyboard(target, keymap, method, layout))
                self.assertIn(f"KEYMAP={keymap}", (target / "etc/vconsole.conf").read_text())
                if keymap == "jp106":
                    self.assertIn("XKBLAYOUT=jp", (target / "etc/vconsole.conf").read_text())
                self.assertEqual((target / "etc/omarchy/input-method").read_text(), f"INPUT_METHOD={method}\nXKB_LAYOUT={layout}\n")

    def test_input_choice_with_no_console_map_defaults_to_us(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.target(directory)
            self.assertTrue(KEYBOARD.configure_keyboard(target, "", "pinyin"))
            self.assertIn("INPUT_METHOD=pinyin", (target / "etc/omarchy/input-method").read_text())

    def test_unknown_keyboard_does_not_silently_drop_an_input_choice(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.target(directory)
            with self.assertRaises(ValueError):
                KEYBOARD.configure_keyboard(target, "unknown", "pinyin")

    def test_invalid_input_preferences_are_rejected_without_writes(self):
        for method, layout in (("unknown", ""), ("hangul", "kr\nKEYMAP=ru"), ("hangul", "kr:dvorak"), ("none", "az")):
            with tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                with self.assertRaises(ValueError):
                    KEYBOARD.configure_keyboard(target, "us", method, layout)
                self.assertFalse((target / "etc/omarchy/input-method").exists())


if __name__ == "__main__":
    unittest.main()
