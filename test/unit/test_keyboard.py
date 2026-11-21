#!/usr/bin/python

import re
import os
import sys
import tempfile
import unittest
from pathlib import Path


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

# What systemd-firstboot derives XKBLAYOUT from, and what the layouts it
# names must exist in.
KBD_MODEL_MAP = Path("/usr/share/systemd/kbd-model-map")
XKB_SYMBOLS = Path("/usr/share/X11/xkb/symbols")


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
        # XKBLAYOUT is load-bearing: omarchy's detect-keyboard-layout.sh copies
        # it into Hyprland's kb_layout on the installed system.
        with tempfile.TemporaryDirectory() as directory:
            target = self.target(directory)
            self.assertTrue(KEYBOARD.configure_keyboard(target, "us"))
            lines = (target / "etc/vconsole.conf").read_text().splitlines()
            self.assertIn("KEYMAP=us", lines)
            self.assertIn("XKBLAYOUT=us", lines)
            self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_all_setup_form_keymaps_reach_the_console_and_the_desktop(self):
        if SUPPORTED_KEYMAPS is None:
            self.skipTest("no Omarchy runtime checkout to read the layout list from")
        for keymap in SUPPORTED_KEYMAPS:
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertTrue(KEYBOARD.configure_keyboard(target, keymap))
                lines = (target / "etc/vconsole.conf").read_text().splitlines()
                self.assertIn(f"KEYMAP={keymap}", lines)
                # Without XKBLAYOUT Hyprland falls back to us: the keymap is
                # in kbd-model-map or in KEYBOARD.XKB_ALIASES, or this fails.
                self.assertEqual(
                    sum(line.startswith("XKBLAYOUT=") for line in lines), 1,
                    f"{keymap}: no XKBLAYOUT in vconsole.conf, the desktop would type us",
                )
                self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_aliases_fill_in_the_xkb_settings_the_model_map_lacks(self):
        # systemd-firstboot writes XKBLAYOUT only for keymaps in kbd-model-map.
        # no-latin1 has no row there, so a Norwegian install typed US in
        # Hyprland while its console and LUKS prompt were Norwegian.
        for keymap, layout, variant in (("no-latin1", "no", ""), ("de_CH-latin1", "ch", "de"), ("colemak", "us", "colemak")):
            with self.subTest(keymap=keymap), tempfile.TemporaryDirectory() as directory:
                target = self.target(directory)
                self.assertTrue(KEYBOARD.configure_keyboard(target, keymap))
                lines = (target / "etc/vconsole.conf").read_text().splitlines()
                self.assertIn(f"KEYMAP={keymap}", lines)
                self.assertEqual([line for line in lines if line.startswith("XKBLAYOUT=")], [f"XKBLAYOUT={layout}"])
                self.assertEqual(
                    [line for line in lines if line.startswith("XKBVARIANT=")],
                    [f"XKBVARIANT={variant}"] if variant else [],
                )
                self.assertIn("XKBMODEL=pc105", lines)
                self.assertEqual(lines.count("FONT=default8x16"), 1)

    def test_aliases_leave_a_keymap_the_model_map_knows_alone(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.target(directory)
            self.assertTrue(KEYBOARD.configure_keyboard(target, "de-latin1"))
            lines = (target / "etc/vconsole.conf").read_text().splitlines()
            self.assertEqual([line for line in lines if line.startswith("XKBLAYOUT=")], ["XKBLAYOUT=de"])
            self.assertEqual([line for line in lines if line.startswith("XKBVARIANT=")], [])

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


class XkbAliasTableTest(unittest.TestCase):
    """The alias table against the two files it bridges: kbd-model-map (what
    systemd-firstboot knows) and xkeyboard-config (what Hyprland can load)."""

    def test_aliases_name_only_keymaps_the_model_map_lacks(self):
        # When systemd adds a row for one of these, firstboot writes the real
        # thing and the alias is dead weight: drop it.
        if not KBD_MODEL_MAP.is_file():
            self.skipTest("no kbd-model-map on this host")
        mapped = {
            line.split()[0]
            for line in KBD_MODEL_MAP.read_text().splitlines()
            if line.strip() and not line.startswith("#")
        }
        for keymap in KEYBOARD.XKB_ALIASES:
            with self.subTest(keymap=keymap):
                self.assertNotIn(keymap, mapped, f"kbd-model-map now knows {keymap}; drop the alias")

    def test_aliases_name_layouts_and_variants_xkeyboard_config_has(self):
        if not XKB_SYMBOLS.is_dir():
            self.skipTest("no xkeyboard-config on this host")
        for keymap, (layout, variant) in KEYBOARD.XKB_ALIASES.items():
            with self.subTest(keymap=keymap):
                symbols = XKB_SYMBOLS / layout
                self.assertTrue(symbols.is_file(), f"no XKB layout {layout}")
                if variant:
                    self.assertIn(f'xkb_symbols "{variant}"', symbols.read_text(), f"no variant {variant} in {layout}")

    def test_aliases_are_not_empty_or_multiline(self):
        # vconsole.conf is sourced as shell by Omarchy's migrations; a value
        # with a newline or a space would break that.
        for keymap, (layout, variant) in KEYBOARD.XKB_ALIASES.items():
            with self.subTest(keymap=keymap):
                self.assertRegex(layout, r"^[a-z]+$")
                self.assertRegex(variant, r"^[a-z_]*$")


if __name__ == "__main__":
    unittest.main()
