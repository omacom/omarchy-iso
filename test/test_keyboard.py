#!/usr/bin/python

import importlib.util
import re
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "configs/airootfs/usr/share/omarchy-iso/orchestrator/keyboard.py"
SPEC = importlib.util.spec_from_file_location("installer_keyboard", MODULE_PATH)
KEYBOARD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(KEYBOARD)

CONFIGURATOR = (ROOT / "configs/airootfs/root/configurator").read_text()
KEYBOARD_BLOCK = re.search(r"keyboards=\$'(.*?)'\n  choice=", CONFIGURATOR, re.DOTALL)
assert KEYBOARD_BLOCK
SUPPORTED_KEYMAPS = [
    line.split("|", 1)[1]
    for line in KEYBOARD_BLOCK.group(1).splitlines()
]
UNSUPPORTED_KEYMAPS = {"ba", "khmer"}


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

    def test_all_configurator_keymaps_are_known_to_localectl(self):
        for keymap in SUPPORTED_KEYMAPS:
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                configured = KEYBOARD.configure_keyboard(target, keymap)
                self.assertEqual(configured, keymap not in UNSUPPORTED_KEYMAPS)
                if configured:
                    lines = (target / "etc/vconsole.conf").read_text().splitlines()
                    self.assertIn(f"KEYMAP={keymap}", lines)
                    self.assertEqual(lines.count("FONT=default8x16"), 1)

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
