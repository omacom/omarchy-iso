"""An OEM's bundle is checked when the ISO is built: what first-boot setup
would draw wrong, or the installer could not run, stops the build."""

import contextlib
import gzip
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "test/unit/fixtures/oem"
SHARE = ROOT / "configs/airootfs/usr/share/omarchy-iso"
TERMINUS = Path("/usr/share/kbd/consolefonts")


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


bundle = load("oem_bundle", ROOT / "builder/oem-bundle.py")


class OemBundleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.output = self.dir / "staged"

    def config(self, **overrides):
        """A config beside a logo and an agreement that pass, with the given keys changed."""
        (self.dir / "logo.txt").write_text("█▀█ █▀▀\n█▀█ █▄▄\n")
        (self.dir / "eula.txt").write_text("You may use this computer.\n")
        config = {"name": "Acme", "logo": "logo.txt", "eula": {"file": "eula.txt"}} | overrides
        path = self.dir / "oem.json"
        path.write_text(json.dumps({key: value for key, value in config.items() if value is not None}))
        return path

    def script(self, name="setup.sh", body="#!/bin/bash\necho setup\n"):
        path = self.dir / name
        path.write_text(body)
        return path

    def refused(self, pattern, config=None, scripts=()):
        with self.assertRaisesRegex(bundle.BundleError, pattern):
            bundle.stage(self.output, config, list(scripts))
        self.assertFalse(self.output.exists() and any(self.output.iterdir()), "a refused bundle left files behind")

    def test_the_example_bundle_is_laid_out_as_the_installer_reads_it(self):
        scripts = [FIXTURE / "scripts/support-info.sh", FIXTURE / "scripts/owner-defaults.sh"]
        bundle.stage(self.output, FIXTURE / "oem.json", scripts)

        self.assertEqual(json.loads((self.output / "oem.json").read_text()), {
            "name": "Acme Computers",
            "tagline": "Acme Book 14, powered by Omarchy",
            "color": "#ff9e64",
            "eula_title": "Acme Computers License Agreement",
        })
        self.assertEqual((self.output / "logo.txt").read_text(), (FIXTURE / "logo.txt").read_text())
        self.assertEqual((self.output / "eula.txt").read_text(), (FIXTURE / "eula.txt").read_text())
        # In the order given, which here is not the alphabet's.
        self.assertEqual(sorted(path.name for path in (self.output / "scripts").iterdir()),
                         ["01-support-info.sh", "02-owner-defaults.sh"])

    def test_scripts_alone_are_a_bundle(self):
        bundle.stage(self.output, None, [self.script()])
        self.assertEqual([path.name for path in self.output.iterdir()], ["scripts"])

    def test_text_is_normalised_for_the_console(self):
        config = self.config()
        (self.dir / "logo.txt").write_text("\n█▀█   \r\n█▀█\n\n\n")
        (self.dir / "eula.txt").write_text("One\r\n\tindented “quoted” – ok ©\r\n\r\n")
        bundle.stage(self.output, config, [])
        self.assertEqual((self.output / "logo.txt").read_text(), "█▀█\n█▀█\n")
        self.assertEqual((self.output / "eula.txt").read_text(), "One\n    indented “quoted” – ok ©\n")

    def test_a_config_setup_cannot_use_is_refused(self):
        cases = {
            "unknown key \"elua\"": {"elua": {"file": "eula.txt"}},
            "\"name\" is required": {"name": None},
            "\"name\" must be a line of text": {"name": "  "},
            "\"name\" is 61 characters": {"name": "A" * 61},
            "\"tagline\" has .*U\\+001B": {"tagline": "Acme\x1b[31m"},
            "\"tagline\" has '東'": {"tagline": "東京"},
            "\"tagline\" has 'ǅ'": {"tagline": "ǅ is Latin the font lacks"},
            "\"color\" must be a colour": {"color": "orange"},
            "unknown key \"text\" in \"eula\"": {"eula": {"file": "eula.txt", "text": "x"}},
            "\"eula\" needs a \"file\"": {"eula": {"title": "Agreement"}},
            "the agreement not found": {"eula": {"file": "missing.txt"}},
            "the logo not found": {"logo": "missing.txt"},
        }
        for pattern, overrides in cases.items():
            with self.subTest(pattern=pattern):
                self.refused(pattern, self.config(**overrides))

    def test_a_logo_the_console_cannot_draw_is_refused(self):
        cases = {
            "row 1 has '★'": "★ ACME\n",
            "row 1 has '═'": "═══\n",
            "uses 129 different dot patterns": "".join(map(chr, range(0x2801, 0x2852))) + "\n" + "".join(map(chr, range(0x2852, 0x2882))) + "\n",
            "row 2 has '\\\\t'": "ACME\n\tACME\n",
            "row 1 is 82 columns wide": "█" * 82 + "\n",
            "13 rows tall": "█\n" * 13,
            "the logo is empty": "\n  \n",
            "logo is empty": "⠀⠀⠀\n",
        }
        for pattern, logo in cases.items():
            with self.subTest(pattern=pattern):
                config = self.config()
                (self.dir / "logo.txt").write_text(logo)
                self.refused(pattern, config)

    def test_an_agreement_the_console_cannot_show_is_refused(self):
        cases = {
            "line 2 has '使'": "Terms\n使用許諾契約\n".encode(),
            "line 1 has .*U\\+001B": b"\x1b]P0ffffff accept\n",
            "line 1 has .*RIGHT-TO-LEFT OVERRIDE": "‮terms\n".encode(),
            "must be UTF-8": b"\xff\xfe terms",
            "the agreement is empty": b"\n\n",
        }
        for pattern, eula in cases.items():
            with self.subTest(pattern=pattern):
                config = self.config()
                (self.dir / "eula.txt").write_bytes(eula)
                self.refused(pattern, config)

    def test_a_script_the_installer_could_not_run_is_refused(self):
        self.refused("not a bash script that parses", scripts=[self.script(body="if true; then\n")])
        self.refused("a script's name may have", scripts=[self.script(name="set up.sh")])
        self.refused("OEM script not found", scripts=[self.dir / "missing.sh"])
        self.refused("needs a config, a script, or both")

    def test_a_script_named_like_an_option_is_still_checked_as_a_script(self):
        (self.dir / "-n").write_text("if true; then\n")
        (self.dir / "-setup.sh").write_text("echo setup\n")
        with contextlib.chdir(self.dir):
            self.refused("not a bash script that parses", scripts=[Path("-n")])
            bundle.stage(self.output, None, [Path("-setup.sh")])
        self.assertEqual([path.name for path in (self.output / "scripts").iterdir()], ["01--setup.sh"])

    def test_a_logo_is_drawn_with_what_the_console_draws_and_with_dots(self):
        # The dots are not in the font: the runtime draws them into it.
        self.assertEqual(bundle.LOGO_CHARACTERS - bundle.CONSOLE_TEXT, bundle.BRAILLE)

    def test_a_logo_in_dots_shares_the_font_with_the_text_shown_beside_it(self):
        config = self.config()
        # As chafa writes it: blank cells are U+2800, to the full width and height.
        (self.dir / "logo.txt").write_text("⣿⣷⣄⠀⢀⣴⣿" + "⠀" * 80 + "\n⠈⠻⣿⣷⣿⡿⠋⠀⠀\n⠀⠀⠀\n")
        bundle.stage(self.output, config, [])
        self.assertEqual((self.output / "logo.txt").read_text(), "⣿⣷⣄ ⢀⣴⣿\n⠈⠻⣿⣷⣿⡿⠋\n")

        # An agreement that uses most of the font leaves the dots no glyphs.
        crowded = sorted(bundle.CONSOLE_TEXT - set(map(chr, range(0x7F))))[:250]
        (self.dir / "eula.txt").write_text("".join(crowded) + "\n")
        self.output = self.dir / "crowded"
        self.refused("9 dot patterns and the 250 characters beyond ASCII", config)
        (self.dir / "logo.txt").write_text("█▀█\n")
        bundle.stage(self.output, config, [])

    def test_the_characters_accepted_are_the_console_fonts(self):
        font = load("console_font", SHARE / "console-font.py")
        for size in ("ter-v16b", "ter-v32b"):
            source = TERMINUS / f"{size}.psf.gz"
            if not source.exists():
                self.skipTest("terminus-font is not installed")
            width, height, glyphs, table = font.read_font(gzip.decompress(source.read_bytes()))
            font.patch(width, height, glyphs, table)
            # Not the glyphs for NUL and for a character the font lacks.
            drawn = {chr(codepoint) for codepoints in table for codepoint in codepoints} - {"\x00", "\ufffd"}
            self.assertEqual(bundle.CONSOLE_TEXT, drawn, size)


if __name__ == "__main__":
    unittest.main()
