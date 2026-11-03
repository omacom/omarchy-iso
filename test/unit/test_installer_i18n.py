"""The installer's translations: catalogs in step with English and the code that
reads them, drawable by the live console font, and the chosen language handed
to the installed system."""

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHARE = ROOT / "configs/airootfs/usr/share/omarchy-iso"
I18N = SHARE / "i18n"
SOURCES = (
    ROOT / "configs/airootfs/root/configurator",
    ROOT / "configs/airootfs/usr/local/bin/omarchy-install-dashboard",
)
OMARCHY_CANDIDATES = (
    Path(os.environ.get("OMARCHY_PATH", "/nonexistent")),
    Path("/omarchy-source"),
    ROOT.parent / "omarchy",
    Path("/usr/share/omarchy"),
)
TERMINUS = Path("/usr/share/kbd/consolefonts")
PLACEHOLDER = re.compile(r"%\d")
# What the installer draws besides catalog text: the logo, gum's borders and spinner.
UI_GLYPHS = "▀▄█╭╮╰╯─│▒▓•›…—"

sys.path.insert(0, str(SHARE))
sys.modules.setdefault("orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter"))

from orchestrator import phases_impl  # noqa: E402
from orchestrator.context import validate_language  # noqa: E402


def catalogs():
    return {path.stem: json.loads(path.read_text()) for path in sorted(I18N.glob("*.json"))}


def omarchy_file(relative):
    for root in OMARCHY_CANDIDATES:
        if (root / relative).is_file():
            return root / relative
    return None


def console_font():
    spec = importlib.util.spec_from_file_location("console_font", SHARE / "console-font.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CatalogTest(unittest.TestCase):
    def setUp(self):
        self.catalogs = catalogs()
        self.english = self.catalogs["en"]

    def test_translations_only_carry_english_keys_with_their_placeholders(self):
        # A missing key is allowed and shows in English, so a new string never waits on 35 translations.
        for code, catalog in self.catalogs.items():
            with self.subTest(code=code):
                self.assertLessEqual(set(catalog), set(self.english))
                for key, text in catalog.items():
                    self.assertEqual(sorted(PLACEHOLDER.findall(text)), sorted(PLACEHOLDER.findall(self.english[key])), key)

    def test_strings_fit_the_console_and_the_places_they_are_printed(self):
        for code, catalog in self.catalogs.items():
            for key, text in catalog.items():
                with self.subTest(code=code, key=key):
                    self.assertTrue(text.strip(), "empty")
                    self.assertNotRegex(text, r"[\t\n\\]", "tabs, newlines and backslashes do not survive @tsv")
                    self.assertLessEqual(len(text), max(80, len(self.english[key]) + 10))
                    if key.startswith("summary.") and key != "summary.prompt":
                        self.assertNotIn(",", text, "the summary is a comma-separated gum table")

    def test_tips_fit_the_progress_screen_without_truncation(self):
        # The dashboard cuts the tip line at the logo's 81 columns.
        for code, catalog in self.catalogs.items():
            line = catalog.get("progress.tipLine", self.english["progress.tipLine"])
            for key, tip in catalog.items():
                if key.startswith("progress.tip."):
                    with self.subTest(code=code, key=key):
                        self.assertLessEqual(len(line.replace("%1", tip)), 80)

    def test_codes_are_omarchy_languages(self):
        registry = omarchy_file("default/i18n/locales.json")
        for code in self.catalogs:
            self.assertRegex(code, r"^[a-z]{2,3}(-[A-Z]{2})?$")
        if registry is None:
            self.skipTest("no Omarchy runtime to read the language registry from")
        self.assertLessEqual(set(self.catalogs), set(json.loads(registry.read_text())))

    def test_every_key_is_used_and_every_used_key_exists(self):
        used = set()
        for source in SOURCES:
            text = source.read_text()
            used |= set(re.findall(r"\bt ([a-z][A-Za-z]*(?:\.[A-Za-z]+)+)", text))
            used |= set(re.findall(r"^\s+(progress\.tip\.[A-Za-z]+)$", text, re.MULTILINE))
        self.assertEqual(used - set(self.english), set())
        self.assertEqual(set(self.english) - used, set())


class LanguageDefaultsTest(unittest.TestCase):
    def setUp(self):
        self.defaults = json.loads((SHARE / "language-defaults.json").read_text())

    def form_environment(self, *languages):
        # The configurator runs its screens when sourced, so take the two functions out of it.
        configurator = SOURCES[0].read_text()
        functions = "\n".join(re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", configurator, re.MULTILINE | re.DOTALL).group(0)
                              for name in ("language_default", "set_form_language"))
        steps = "".join(f'language={code}; set_form_language; env | grep "^OMARCHY_FORM_" | sort; echo --;' for code in languages)
        output = subprocess.run(
            ["bash", "-c", f"{functions}\n{steps}"],
            env={"PATH": os.environ["PATH"], "LANGUAGE_DEFAULTS": str(SHARE / "language-defaults.json")},
            capture_output=True, text=True, check=True,
        ).stdout
        return [dict(line.split("=", 1) for line in block.strip().splitlines()) for block in output.split("--\n")[:-1]]

    def test_the_setup_form_gets_the_language_and_its_defaults(self):
        polish, arabic, english, unknown = self.form_environment("pl", "ar", "en", "xx")
        self.assertEqual(polish, {"OMARCHY_FORM_LANGUAGE": "pl", "OMARCHY_FORM_KEYBOARD_DEFAULT": "Polish",
                                  "OMARCHY_FORM_TIMEZONE_FALLBACK": "Europe/Warsaw"})
        # Picking again replaces the fallback. A language with no home country
        # falls back to UTC: with no fallback at all, an offline form opens
        # its timezone search, where Enter takes the first zone, Africa/Abidjan.
        self.assertEqual(arabic, {"OMARCHY_FORM_LANGUAGE": "ar", "OMARCHY_FORM_KEYBOARD_DEFAULT": "English (US)",
                                  "OMARCHY_FORM_TIMEZONE_FALLBACK": "UTC"})
        self.assertEqual(english["OMARCHY_FORM_TIMEZONE_FALLBACK"], "UTC")
        self.assertEqual(unknown["OMARCHY_FORM_KEYBOARD_DEFAULT"], "English (US)")
        self.assertEqual(unknown["OMARCHY_FORM_TIMEZONE_FALLBACK"], "UTC")

    def test_every_language_in_the_picker_has_defaults(self):
        self.assertLessEqual(set(catalogs()), set(self.defaults))
        registry = omarchy_file("default/i18n/locales.json")
        if registry is None:
            self.skipTest("no Omarchy runtime to read the language registry from")
        self.assertEqual(set(self.defaults), set(json.loads(registry.read_text())))

    def test_every_keyboard_is_a_row_of_the_setup_form(self):
        form = omarchy_file("install/provisioning/setup-form.sh")
        if form is None:
            self.skipTest("no Omarchy runtime to read the setup form from")
        rows = re.search(r"OMARCHY_KEYBOARD_LAYOUTS=\$'(.*?)'\n", form.read_text(), re.DOTALL).group(1).splitlines()
        labels = {row.split("|")[0] for row in rows}
        for code, defaults in self.defaults.items():
            with self.subTest(code=code):
                self.assertIn(defaults["keyboard"], labels)

    def test_every_timezone_is_a_zone_the_timezone_list_offers(self):
        # timedatectl list-timezones offers tzdata's zones and links, read the same way here.
        tzdata = Path("/usr/share/zoneinfo/tzdata.zi")
        if not tzdata.is_file():
            self.skipTest("tzdata is not installed")
        zones = set()
        for line in tzdata.read_text().splitlines():
            fields = line.split()
            if fields[:1] == ["Z"]:
                zones.add(fields[1])
            elif fields[:1] == ["L"]:
                zones.add(fields[2])
        for code, defaults in self.defaults.items():
            if "timezone" in defaults:
                with self.subTest(code=code):
                    self.assertIn(defaults["timezone"], zones)


class ConsoleFontTest(unittest.TestCase):
    def test_the_live_console_font_draws_every_translated_string(self):
        registry = omarchy_file("default/i18n/locales.json")
        names = json.loads(registry.read_text()) if registry else {}
        module = console_font()
        for size in ("16", "32"):
            source = TERMINUS / f"ter-v{size}b.psf.gz"
            if not source.is_file():
                self.skipTest("terminus-font is not installed")
            import gzip

            width, height, glyphs, table = module.read_font(gzip.decompress(source.read_bytes()))
            module.patch(width, height, glyphs, table)
            drawable = {codepoint for codepoints in table for codepoint in codepoints}
            for code, catalog in catalogs().items():
                text = "".join(catalog.values()) + names.get(code, {}).get("name", "") + UI_GLYPHS
                missing = sorted({c for c in text if ord(c) > 0x7E and ord(c) not in drawable})
                with self.subTest(size=size, code=code):
                    self.assertEqual(missing, [])

    def test_cyrillic_ve_de_and_i_take_their_russian_forms(self):
        module = console_font()
        import gzip

        for size in ("16", "32"):
            source = TERMINUS / f"ter-v{size}b.psf.gz"
            if not source.is_file():
                self.skipTest("terminus-font is not installed")
            width, height, glyphs, table = module.read_font(gzip.decompress(source.read_bytes()))
            module.patch(width, height, glyphs, table)
            row_bytes = (width + 7) // 8

            def glyph_of(char):
                return glyphs[next(i for i, codepoints in enumerate(table) if ord(char) in codepoints)]

            def inked(char):
                glyph = glyph_of(char)
                return [any(glyph[row * row_bytes:(row + 1) * row_bytes]) for row in range(height)]

            def rows(char):
                ink = inked(char)
                return ink.index(True), len(ink) - 1 - ink[::-1].index(True)

            with self.subTest(size=size):
                # в is a lowercase letter: as tall as а, not as В.
                self.assertEqual(rows("в")[0], rows("а")[0])
                self.assertLess(rows("В")[0], rows("в")[0])
                # д's foot reaches below the baseline, as у's tail does.
                self.assertGreater(rows("д")[1], rows("а")[1])
                # и has its diagonal, so it doesn't read as u.
                self.assertNotEqual(glyph_of("и"), glyph_of("u"))

    def test_patch_redraws_only_its_own_glyphs(self):
        module = console_font()
        import gzip

        for size in ("16", "32"):
            source = TERMINUS / f"ter-v{size}b.psf.gz"
            if not source.is_file():
                self.skipTest("terminus-font is not installed")
            width, height, glyphs, table = module.read_font(gzip.decompress(source.read_bytes()))
            original = list(glyphs)
            try:
                module.patch(width, height, glyphs, table)
            except ValueError as error:
                self.fail(error)
            redrawn = {codepoint for index, glyph in enumerate(glyphs) if glyph != original[index]
                       for codepoint in table[index]}

            with self.subTest(size=size):
                self.assertEqual({len(glyph) for glyph in glyphs}, {len(original[0])})
                expected = {module.UPPER_HALF, module.LOWER_HALF} | set(module.RUSSIAN_FORMS[(width, height)])
                self.assertEqual(redrawn, expected)

    def test_half_blocks_fill_the_top_or_bottom_half_of_the_cell(self):
        module = console_font()
        upper = module.half_block(16, 32, True)
        self.assertEqual(upper[:2], b"\xff\xff")
        self.assertEqual(upper[-2:], b"\x00\x00")
        self.assertEqual(module.half_block(8, 16, False)[:8], bytes(8))


class ShellLookupTest(unittest.TestCase):
    def lookup(self, script, catalogs_dir):
        return subprocess.run(
            ["bash", "-c", f'source "{SHARE}/i18n.sh"; {script}'],
            env={**os.environ, "OMARCHY_ISO_I18N_DIR": str(catalogs_dir)},
            capture_output=True, text=True, check=True,
        ).stdout

    def test_placeholders_and_english_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / "en.json").write_text(json.dumps({"a.b": "Disk %1 has %2", "a.only": "English only"}))
            (directory / "da.json").write_text(json.dumps({"a.b": "%2 på %1 & mere"}))
            self.assertEqual(self.lookup('i18n_load da; t a.b /dev/sda 32GB', directory), "32GB på /dev/sda & mere")
            self.assertEqual(self.lookup('i18n_load da; t a.only', directory), "English only")
            self.assertEqual(self.lookup('i18n_load ../da; t a.b x y', directory), "Disk x has y")


class ConsoleFontLoadTest(unittest.TestCase):
    def test_a_failing_font_probe_never_stops_a_strict_caller(self):
        with tempfile.TemporaryDirectory() as directory:
            stubs = Path(directory)
            for tool in ("showconsolefont", "setfont", "python3"):
                (stubs / tool).write_text("#!/bin/bash\nexit 1\n")
                (stubs / tool).chmod(0o755)
            result = subprocess.run(
                ["bash", "-c", f'set -euo pipefail; source "{SHARE}/i18n.sh"; i18n_console_font /dev/tty1; echo survived'],
                env={**os.environ, "PATH": f"{stubs}:{os.environ['PATH']}", "OMARCHY_ISO_CONSOLE_FONT": f"{stubs}/run/console.psf"},
                capture_output=True, text=True,
            )
            self.assertEqual(result.stdout, "survived\n", result.stderr)


class LanguageMarkerTest(unittest.TestCase):
    def marker(self, language):
        with tempfile.TemporaryDirectory() as directory:
            ctx = types.SimpleNamespace(target=Path(directory), omarchy_install={"language": language})
            phases_impl._write_language_marker(ctx)
            marker = Path(directory) / "etc/omarchy/language"
            return marker.read_text() if marker.exists() else None

    def test_a_chosen_language_reaches_the_target_and_english_writes_nothing(self):
        self.assertEqual(self.marker("da"), "da\n")
        self.assertEqual(self.marker("zh-CN"), "zh-CN\n")
        self.assertIsNone(self.marker("en"))
        self.assertIsNone(self.marker(None))

    def test_only_registry_codes_are_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Path(directory) / "locales.json"
            registry.write_text(json.dumps({"en": {}, "da": {}, "zh-CN": {}}))
            for code in ("da", "zh-CN", "", None):
                validate_language(code, registry)
            for code in ("xx", "../da", "da\n", 7):
                with self.subTest(code=code), self.assertRaises(RuntimeError):
                    validate_language(code, registry)

    def test_without_a_registry_only_english_is_accepted(self):
        missing = Path("/nonexistent/locales.json")
        validate_language("en", missing)
        with self.assertRaises(RuntimeError):
            validate_language("da", missing)


if __name__ == "__main__":
    unittest.main()
