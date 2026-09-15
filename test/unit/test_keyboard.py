#!/usr/bin/python

import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import keyboard as KEYBOARD  # noqa: E402

# The layout list lives in the Omarchy runtime now, shared verbatim with the
# first-boot owner setup; build-iso.sh vendors it onto the ISO. Read it from
# wherever this checkout can see a runtime, and skip the coverage test rather
# than fail when none is around (a bare CI checkout of just this repo).
SETUP_FORM_CANDIDATES = KEYBOARD.setup_form_candidates()


def setup_form_text():
    for candidate in SETUP_FORM_CANDIDATES:
        if candidate.is_file():
            return candidate.read_text()
    return None


def supported_keymaps():
    text = setup_form_text()
    if text is None:
        return None
    block = re.search(
        r"OMARCHY_KEYBOARD_LAYOUTS=\$'(.*?)'\n", text, re.DOTALL
    )
    assert block, "no layout list in setup-form.sh"
    return [line.split("|", 1)[1] for line in block.group(1).splitlines()]


def xkb_only_from_setup_form():
    text = setup_form_text()
    if text is None:
        return None
    match = re.search(r'^OMARCHY_XKB_ONLY_LAYOUTS="([^"]*)"', text, re.MULTILINE)
    if match is None:
        return set()
    return {part for part in match.group(1).split() if part}


SUPPORTED_KEYMAPS = supported_keymaps()
XKB_ONLY_LAYOUTS = xkb_only_from_setup_form()


class KeyboardConfigurationTest(unittest.TestCase):
    def target(self, directory: str) -> Path:
        target = Path(directory)
        (target / "etc").mkdir()
        (target / "etc/vconsole.conf").write_text(
            "KEYMAP=us\nFONT=default8x16\n"
        )
        return target

    def test_writes_keymap_and_xkb_settings_and_preserves_font(self):
        # XKBLAYOUT is load-bearing: omarchy's detect-keyboard-layout.sh copies
        # it into Hyprland's kb_layout on the installed system.
        with tempfile.TemporaryDirectory() as directory:
            target = self.target(directory)
            self.assertTrue(KEYBOARD.configure_keyboard(target, "us"))
            lines = (target / "etc/vconsole.conf").read_text().splitlines()
            self.assertIn("KEYMAP=us", lines)
            self.assertIn("XKBLAYOUT=us", lines)
            self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_console_keymaps_from_the_picker_still_write_themselves(self):
        if SUPPORTED_KEYMAPS is None:
            self.skipTest("no Omarchy runtime checkout to read the layout list from")
        xkb_only = XKB_ONLY_LAYOUTS or set()
        console_maps = [keymap for keymap in SUPPORTED_KEYMAPS if keymap not in xkb_only]
        self.assertTrue(console_maps, "picker still offers console keymaps")
        for keymap in console_maps:
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertTrue(KEYBOARD.configure_keyboard(target, keymap))
                lines = (target / "etc/vconsole.conf").read_text().splitlines()
                self.assertIn(f"KEYMAP={keymap}", lines)
                self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_xkb_only_picker_values_write_us_console_and_xkb_layout(self):
        if XKB_ONLY_LAYOUTS is None:
            self.skipTest("no Omarchy runtime checkout to read the layout list from")
        if not XKB_ONLY_LAYOUTS:
            self.skipTest("setup-form.sh names no xkb-only layouts")
        for keymap in sorted(XKB_ONLY_LAYOUTS):
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertTrue(KEYBOARD.configure_keyboard(target, keymap))
                lines = (target / "etc/vconsole.conf").read_text().splitlines()
                self.assertIn("KEYMAP=us", lines)
                self.assertIn(f"XKBLAYOUT={keymap}", lines)
                self.assertEqual(lines.count("FONT=default8x16"), 1)
                self.assertEqual(sum(1 for line in lines if line.startswith("XKBLAYOUT=")), 1)

    def test_thai_persists_as_us_console_and_th_xkb_even_without_setup_form(self):
        with patch.object(KEYBOARD, "xkb_only_layouts", return_value={"th"}):
            with tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertTrue(KEYBOARD.configure_keyboard(target, "th"))
                lines = (target / "etc/vconsole.conf").read_text().splitlines()
                self.assertIn("KEYMAP=us", lines)
                self.assertIn("XKBLAYOUT=th", lines)
                self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_configurator_loadkeys_uses_shared_console_helper(self):
        configurator = ROOT / "configs/airootfs/root/configurator"
        text = configurator.read_text()
        self.assertIn("omarchy_console_keymap_for", text)
        self.assertIn('loadkeys "$(omarchy_console_keymap_for "$keyboard")"', text)

    def test_unknown_and_empty_keymaps_match_archinstall_behavior(self):
        for keymap, expected in (("definitely-not-a-keymap", False), ("", True)):
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertEqual(KEYBOARD.configure_keyboard(target, keymap), expected)
                self.assertEqual(
                    (target / "etc/vconsole.conf").read_text(),
                    "KEYMAP=us\nFONT=default8x16\n",
                )


if __name__ == "__main__":
    unittest.main()
