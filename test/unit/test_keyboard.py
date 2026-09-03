#!/usr/bin/python

import re
import sys
import tempfile
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import keyboard as KEYBOARD  # noqa: E402

# The layout list lives in the Omarchy runtime now, shared verbatim with the
# first-boot owner setup; build-iso.sh vendors it onto the ISO. Read it from
# wherever this checkout can see a runtime, and skip the coverage test rather
# than fail when none is around (a bare CI checkout of just this repo).
SETUP_FORM_CANDIDATES = (
    Path("/omarchy-source/install/provisioning/setup-form.sh"),
    ROOT.parent / "omarchy/install/provisioning/setup-form.sh",
    Path("/usr/share/omarchy/install/provisioning/setup-form.sh"),
)


def supported_keymaps():
    for candidate in SETUP_FORM_CANDIDATES:
        if not candidate.is_file():
            continue
        block = re.search(
            r"OMARCHY_KEYBOARD_LAYOUTS=\$'(.*?)'\n", candidate.read_text(), re.DOTALL
        )
        assert block, f"no layout list in {candidate}"
        return [line.split("|", 1)[1] for line in block.group(1).splitlines()]
    return None


SUPPORTED_KEYMAPS = supported_keymaps()


class KeyboardConfigurationTest(unittest.TestCase):
    def target(self, directory: str) -> Path:
        target = Path(directory)
        (target / "etc").mkdir()
        (target / "etc/vconsole.conf").write_text(
            "KEYMAP=us\nFONT=default8x16\n"
        )
        keymap = target / "usr/share/kbd/keymaps/i386/qwerty/us.map.gz"
        keymap.parent.mkdir(parents=True)
        keymap.touch()
        return target

    def test_uses_target_keymap_catalog_without_host_localectl(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.target(directory)
            keymap = target / "usr/share/kbd/keymaps/i386/qwerty/us.map.gz"
            keymap.parent.mkdir(parents=True, exist_ok=True)
            keymap.touch()

            def run_firstboot(command):
                self.assertEqual(command[0], "systemd-firstboot")
                (target / "etc/vconsole.conf").write_text("KEYMAP=us\nXKBLAYOUT=us\n")
                return CompletedProcess(command, 0, "", "")

            with patch.object(KEYBOARD, "capture", side_effect=run_firstboot) as capture:
                self.assertTrue(KEYBOARD.configure_keyboard(target, "us"))

            capture.assert_called_once()

    def test_writes_keymap_and_xkb_settings_and_preserves_font(self):
        # XKBLAYOUT is load-bearing: omarchy's detect-keyboard-layout.sh copies
        # it into Hyprland's kb_layout on the installed system.
        with tempfile.TemporaryDirectory() as directory:
            target = self.target(directory)

            def run_firstboot(command):
                (target / "etc/vconsole.conf").write_text(
                    "KEYMAP=us\nXKBLAYOUT=us\n"
                )
                return CompletedProcess(command, 0, "", "")

            with patch.object(KEYBOARD, "capture", side_effect=run_firstboot):
                self.assertTrue(KEYBOARD.configure_keyboard(target, "us"))
            lines = (target / "etc/vconsole.conf").read_text().splitlines()
            self.assertIn("KEYMAP=us", lines)
            self.assertIn("XKBLAYOUT=us", lines)
            self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_all_configurator_keymaps_are_in_installed_kbd_catalog(self):
        if SUPPORTED_KEYMAPS is None:
            self.skipTest("no Omarchy runtime checkout to read the layout list from")
        try:
            installed = KEYBOARD._installed_keymaps(Path("/"))
        except RuntimeError:
            self.skipTest("no host kbd keymap catalog")
        for keymap in SUPPORTED_KEYMAPS:
            with self.subTest(keymap=keymap):
                self.assertIn(keymap.casefold(), installed)

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
