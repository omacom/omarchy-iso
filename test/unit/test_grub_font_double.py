"""Unit tests for builder/grub-font-double.py: the boot menu's doubled
Terminus. A doubled font keeps every character, names itself for the theme,
and each glyph is the source glyph with every pixel drawn twice as wide and
twice as tall."""

import importlib.util
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path("/usr/share/grub/ter-u16b.pf2")

spec = importlib.util.spec_from_file_location("grub_font_double", ROOT / "builder/grub-font-double.py")
double = importlib.util.module_from_spec(spec)
spec.loader.exec_module(double)


def parse(data):
    """Section bodies by tag, and the glyph of each code point."""
    info, glyphs = {}, {}
    for tag, body in double.sections(data):
        if tag != b"DATA":
            info[tag] = body
    chix = info[b"CHIX"]
    for i in range(0, len(chix), 9):
        code, _, offset = struct.unpack(">IBI", chix[i:i + 9])
        glyphs[code] = double.glyph_at(data, offset)
    return info, glyphs


def pixels(glyph):
    width, height = struct.unpack(">HH", glyph[:4])
    bits = glyph[10:]
    return [[(bits[(y * width + x) // 8] >> (7 - (y * width + x) % 8)) & 1 for x in range(width)]
            for y in range(height)]


@unittest.skipUnless(SOURCE.exists(), "terminus-font is not installed")
class DoubledTerminus(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_bytes()
        cls.doubled = double.double(cls.source, "Terminus 2x")
        cls.src_info, cls.src_glyphs = parse(cls.source)
        cls.info, cls.glyphs = parse(cls.doubled)

    def test_it_names_itself_for_the_theme(self):
        # configs/grub/themes/omarchy/theme.txt asks for this name.
        self.assertEqual(self.info[b"NAME"], b"Terminus 2x Bold 32\0")
        self.assertEqual(self.info[b"FAMI"], b"Terminus 2x\0")
        self.assertEqual(self.info[b"WEIG"], self.src_info[b"WEIG"])

    def test_every_metric_doubles(self):
        for tag in (b"PTSZ", b"MAXW", b"MAXH", b"ASCE", b"DESC"):
            source = struct.unpack(">H", self.src_info[tag])[0]
            self.assertEqual(struct.unpack(">H", self.info[tag])[0], source * 2, tag)

    def test_it_keeps_every_character(self):
        self.assertEqual(sorted(self.glyphs), sorted(self.src_glyphs))
        self.assertGreater(len(self.glyphs), 200)

    def test_each_glyph_is_its_source_with_doubled_pixels(self):
        for char in "InstalJutryScren":
            source, glyph = self.src_glyphs[ord(char)], self.glyphs[ord(char)]
            self.assertEqual(struct.unpack(">hhh", glyph[4:10]),
                             tuple(v * 2 for v in struct.unpack(">hhh", source[4:10])), char)
            big = pixels(glyph)
            for y, row in enumerate(pixels(source)):
                for x, bit in enumerate(row):
                    self.assertEqual({big[2 * y + dy][2 * x + dx] for dy in (0, 1) for dx in (0, 1)}, {bit},
                                     f"{char!r} at {x},{y}")
            self.assertTrue(any(map(any, big)), f"{char!r} is blank")


if __name__ == "__main__":
    unittest.main()
