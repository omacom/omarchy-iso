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

    def test_us_output_matches_systemd_localed_files(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.target(directory)
            self.assertTrue(KEYBOARD.configure_keyboard(target, "us"))
            self.assertEqual(
                (target / "etc/vconsole.conf").read_text(),
                "# Written by systemd-localed(8) or systemd-firstboot(1), read by systemd-localed\n"
                "# and systemd-vconsole-setup(8). Use localectl(1) to update this file.\n"
                "FONT=default8x16\n"
                "KEYMAP=us\n"
                "XKBLAYOUT=us\n"
                "XKBMODEL=pc105+inet\n"
                "XKBOPTIONS=terminate:ctrl_alt_bksp\n",
            )
            self.assertEqual(
                (target / "etc/X11/xorg.conf.d/00-keyboard.conf").read_text(),
                "# Written by systemd-localed(8), read by systemd-localed and Xorg. It's\n"
                "# probably wise not to edit this file manually. Use localectl(1) to\n"
                "# update this file.\n"
                "Section \"InputClass\"\n"
                "        Identifier \"system-keyboard\"\n"
                "        MatchIsKeyboard \"on\"\n"
                "        Option \"XkbLayout\" \"us\"\n"
                "        Option \"XkbModel\" \"pc105+inet\"\n"
                "        Option \"XkbOptions\" \"terminate:ctrl_alt_bksp\"\n"
                "EndSection\n",
            )

    def test_all_configurator_keymaps_preserve_console_font(self):
        for keymap in SUPPORTED_KEYMAPS:
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                configured = KEYBOARD.configure_keyboard(target, keymap)
                self.assertEqual(configured, keymap not in UNSUPPORTED_KEYMAPS)
                lines = (target / "etc/vconsole.conf").read_text().splitlines()
                if configured:
                    self.assertIn(f"KEYMAP={keymap}", lines)
                    self.assertEqual(lines.count("FONT=default8x16"), 1)
                    has_xkb = any(line.startswith("XKBLAYOUT=") for line in lines)
                    self.assertEqual(
                        (target / "etc/X11/xorg.conf.d/00-keyboard.conf").exists(),
                        has_xkb,
                    )
                else:
                    self.assertEqual(lines, ["KEYMAP=us", "FONT=default8x16"])
                    self.assertFalse(
                        (target / "etc/X11/xorg.conf.d/00-keyboard.conf").exists()
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
                self.assertFalse(
                    (target / "etc/X11/xorg.conf.d/00-keyboard.conf").exists()
                )


if __name__ == "__main__":
    unittest.main()
