#!/usr/bin/python

import re
import os
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
    Path(os.environ.get("OMARCHY_PATH", "/nonexistent")) / "install/provisioning/setup-form.sh",
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
        return [line.split("|")[1] for line in block.group(1).splitlines()]
    return None


SUPPORTED_KEYMAPS = supported_keymaps()


class KeyboardConfigurationTest(unittest.TestCase):
    def target(self, directory: str) -> Path:
        target = Path(directory)
        (target / "etc").mkdir()
        (target / "etc/vconsole.conf").write_text(
            "KEYMAP=us\nFONT=default8x16\n"
        )
        for name in ("us", "jp106"):
            keymap = target / f"usr/share/kbd/keymaps/i386/qwerty/{name}.map.gz"
            keymap.parent.mkdir(parents=True, exist_ok=True)
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

    def test_input_choice_survives_while_console_keymap_stays_real(self):
        for method, keymap, layout in (("mozc", "jp106", ""), ("mozc", "us", ""), ("hangul", "us", "kr"), ("pinyin", "us", ""), ("chewing", "us", "")):
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
        for method, layout in (("unknown", ""), ("hangul", "kr\nKEYMAP=ru")):
            with tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                with self.assertRaises(ValueError):
                    KEYBOARD.configure_keyboard(target, "us", method, layout)
                self.assertFalse((target / "etc/omarchy/input-method").exists())


if __name__ == "__main__":
    unittest.main()
