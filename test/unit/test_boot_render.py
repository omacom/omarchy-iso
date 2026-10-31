"""test/boot-render's frame checks, on frames drawn here.

Each case draws a console frame the way fbcon or the VGA text mode would
(cells of block glyphs, or glyphs from the real console fonts where they are
installed) and checks what boot-render makes of it: the logo at the greeter's
place passes, and every glitch the boot has shown fails, the box drawing of a
font loaded under the logo among them.
"""

import gzip
import importlib.util
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SHARE = ROOT / "configs/airootfs/usr/share/omarchy-iso"
LOGO = Path("/usr/share/omarchy/logo.txt")
KERNEL_FONT = Path("/usr/share/kbd/consolefonts/default8x16.psfu.gz")
TERMINUS = Path("/usr/share/kbd/consolefonts/ter-v16b.psf.gz")

loader = SourceFileLoader("boot_render", str(ROOT / "test/boot-render"))
spec = importlib.util.spec_from_loader("boot_render", loader)
br = importlib.util.module_from_spec(spec)
sys.modules["boot_render"] = br  # dataclasses look their module up
loader.exec_module(br)

BG, GREEN, GREY = (0x1A, 0x1B, 0x26), (0x9E, 0xCE, 0x6A), (0xC0, 0xCA, 0xF5)
# A stand-in for the logo where the Omarchy package is not installed: blocks
# of every kind, an empty top half row like the real one, 81 columns.
FIXTURE = [
    " " * 17 + "▄▄▄" + " " * 61,
    " ▄█████▄    ▄███████████▄    ▄" + " " * 50 + "█",
] + ["███   ███  ███   ███   ███  ██" + " " * 51 + "█"] * 7 + [" ▀█████▀    ▀█   ███   █▀   ██" + " " * 51 + "▀"]


def logo_lines():
    if LOGO.is_file():
        return LOGO.read_text(encoding="utf-8").rstrip("\n").split("\n")
    return FIXTURE


class Canvas:
    def __init__(self, width, height, bg=BG):
        self.width, self.height = width, height
        self.px = bytearray(bytes(bg) * width * height)

    def fill(self, x0, y0, x1, y1, colour):
        x0, x1 = max(0, x0), min(self.width, x1)
        if x0 >= x1:
            return
        for y in range(max(0, y0), min(self.height, y1)):
            row = y * self.width
            self.px[(row + x0) * 3:(row + x1) * 3] = bytes(colour) * (x1 - x0)

    def glyph(self, x, y, rows, width, colour):
        """A glyph bitmap, one int per pixel row, most significant bit left."""
        for dy, bits in enumerate(rows):
            for dx in range(width):
                if bits >> (width - 1 - dx) & 1:
                    self.fill(x + dx, y + dy, x + dx + 1, y + dy + 1, colour)

    def frame(self):
        return br.Frame(self.width, self.height, bytes(self.px))


def blocks(canvas, lines, col, row, cw, ch, split, colour=GREEN, skip=()):
    """The logo in block glyphs, cells of cw x ch, ▀ split rows high."""
    for r, line in enumerate(lines):
        for c, char in enumerate(line):
            if (r, c) in skip:
                continue
            x, y = (col + c) * cw, (row + r) * ch
            if char in "█▀":
                canvas.fill(x, y, x + cw, y + split, colour)
            if char in "█▄":
                canvas.fill(x, y + split, x + cw, y + ch, colour)


def text(canvas, string, col, row, cw, ch, colour=GREY):
    """Text as a lit bar per letter: what boot-render looks at is where."""
    for i, char in enumerate(string):
        if char != " ":
            x, y = (col + i) * cw, row * ch
            canvas.fill(x + 1, y + 3, x + cw - 1, y + ch - 3, colour)


def place(width, height, cw, ch, cols=81, rows=10):
    """The greeter's top left cell on this console (console-logo.sh)."""
    return (width // cw - cols) // 2, (height // ch - rows - 4) // 2


def boot_logo(width=1280, height=800, cw=8, ch=16, split=8, **kwargs):
    canvas = Canvas(width, height)
    col, row = place(width, height, cw, ch)
    blocks(canvas, logo_lines(), col, row, cw, ch, split, **kwargs)
    return canvas


def greeter(width=1280, height=800, cw=8, ch=16, split=8):
    canvas = boot_logo(width, height, cw, ch, split)
    col, row = place(width, height, cw, ch)
    cols = width // cw
    text(canvas, br.TAGLINE, (cols - len(br.TAGLINE)) // 2, row + 11, cw, ch)
    text(canvas, br.HINT, (cols - len(br.HINT)) // 2, row + 13, cw, ch)
    return canvas


def narrow(width=600, height=800, wrapped=False, greeting=True, cw=8, ch=16):
    """A console narrower than the fitted logo (600 pixels: 75 columns of
    8x16): the fitted logo drawn from the first column, cut at the last; or
    each line's end wrapped onto the next row, as the greeter drew it after a
    line feed."""
    lines = [line.ljust(81) for line in logo_lines()]
    blank = next(c for c in range(81) if all(line[c] == " " for line in lines))
    fitted = [line[:blank] + line[blank + 1:] for line in lines]
    cols = width // cw
    canvas = Canvas(width, height)
    row = (height // ch - 10 - 4) // 2
    if wrapped:
        for r, line in enumerate(fitted):
            blocks(canvas, [line[:cols], line[cols:]], 0, row + 2 * r, cw, ch, ch // 2)
    else:
        blocks(canvas, fitted, 0, row, cw, ch, ch // 2)
    if greeting:
        text(canvas, br.TAGLINE, (cols - len(br.TAGLINE)) // 2, row + 11, cw, ch)
        text(canvas, br.HINT, (cols - len(br.HINT)) // 2, row + 13, cw, ch)
    return canvas


def read_psf(path):
    """Glyphs, character -> slot, width, height: console-font.py's reader, PSF1 and PSF2."""
    spec = importlib.util.spec_from_file_location("console_font", SHARE / "console-font.py")
    console_font = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(console_font)
    data = path.read_bytes()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    width, height, glyphs, table = console_font.read_font(data)
    slot = {}
    for index, codepoints in enumerate(table):
        for codepoint in codepoints:
            slot.setdefault(chr(codepoint), index)
    return glyphs, slot, width, height


def logos():
    path = LOGO
    if not path.is_file():
        tmp = Path(tempfile.mkdtemp()) / "logo.txt"
        tmp.write_text("\n".join(FIXTURE) + "\n", encoding="utf-8")
        path = tmp
    return br.logo_variants(path)


class FrameTest(unittest.TestCase):
    def setUp(self):
        self.logos = logos()

    def test_the_boot_logo_at_the_greeters_place(self):
        for width, height, cw, ch, split in ((1280, 800, 8, 16, 7), (1280, 800, 8, 16, 8),
                                             (1920, 1080, 16, 32, 16), (1366, 768, 8, 16, 8)):
            with self.subTest(size=f"{width}x{height}", cell=f"{cw}x{ch}/{split}"):
                v = br.classify(boot_logo(width, height, cw, ch, split).frame(), self.logos)
                self.assertEqual(v.kind, "logo")
                self.assertEqual((v.geometry.cw, v.geometry.ch, v.geometry.split), (cw, ch, split))
                col, row = place(width, height, cw, ch)
                self.assertEqual((v.geometry.ox, v.geometry.oy), (col * cw, row * ch))
                self.assertIsNone(v.stray)

    def test_the_greeter_with_its_tagline_and_hint(self):
        v = br.classify(greeter().frame(), self.logos)
        self.assertEqual(v.kind, "greeter")
        self.assertEqual(v.notes, [])
        self.assertIsNone(v.stray)

    def test_black_and_the_consoles_background(self):
        self.assertEqual(br.classify(Canvas(640, 480, (0, 0, 0)).frame(), self.logos).kind, "black")
        self.assertEqual(br.classify(Canvas(1280, 800).frame(), self.logos).kind, "blank")

    def test_a_line_of_kernel_text_is_text(self):
        canvas = Canvas(1280, 800, (0, 0, 0))
        text(canvas, "[    0.043205] RDSEED32 is broken.", 0, 0, 8, 16)
        self.assertEqual(br.classify(canvas.frame(), self.logos).kind, "text")

    def test_a_cursor_on_an_empty_console_is_a_speck(self):
        canvas = Canvas(1280, 800)
        canvas.fill(240, 302, 248, 304, GREEN)
        v = br.classify(canvas.frame(), self.logos)
        self.assertEqual(v.kind, "speck")
        self.assertEqual(v.box, (240, 302, 247, 303))

    def test_qemus_display_output_is_not_active_is_dark(self):
        canvas = Canvas(720, 400, (0, 0, 0))
        text(canvas, "Display output is not active.", 30, 12, 8, 16)  # centred, as QEMU draws it
        self.assertEqual(br.classify(canvas.frame(), self.logos).kind, "black")

    def test_stray_text_beside_the_logo(self):
        canvas = boot_logo()
        text(canvas, "login:", 0, 0, 8, 16)
        v = br.classify(canvas.frame(), self.logos)
        self.assertEqual(v.kind, "logo")
        self.assertIsNotNone(v.stray)
        self.assertLess(v.stray[1], 16)

    def test_a_half_erased_logo_is_no_logo(self):
        # ttfx's canvas of spaces caught half way: the lower rows gone.
        lines = logo_lines()
        skip = {(r, c) for r in range(5, len(lines)) for c in range(len(lines[0]))}
        v = br.classify(boot_logo(skip=skip).frame(), self.logos)
        self.assertNotIn(v.kind, ("logo", "greeter"))

    def test_a_console_narrower_than_the_fitted_logo_has_it_cut_at_its_edge(self):
        v = br.classify(narrow(greeting=False).frame(), self.logos)
        self.assertEqual((v.kind, v.geometry.logo, v.geometry.ox, v.geometry.oy), ("logo", "fitted|75", 0, 18 * 16))
        self.assertIsNone(v.stray)
        v = br.classify(narrow().frame(), self.logos)
        self.assertEqual((v.kind, v.geometry.logo, v.notes, v.stray), ("greeter", "fitted|75", [], None))

    def test_the_logo_wrapped_on_a_narrow_console_is_no_logo(self):
        v = br.classify(narrow(wrapped=True).frame(), self.logos)
        self.assertNotIn(v.kind, ("logo", "greeter"))

    def test_a_narrow_console_in_the_32_px_font_is_no_logo(self):
        # The 16x32 font goes with 115 columns and more: a console narrower
        # than the logo in it is the font gone wrong, cut or not.
        for width, height in ((1024, 768), (800, 600), (640, 480), (1200, 1920)):
            for greeting in (False, True):
                with self.subTest(size=f"{width}x{height}", greeting=greeting):
                    v = br.classify(narrow(width, height, greeting=greeting, cw=16, ch=32).frame(), self.logos)
                    self.assertNotIn(v.kind, ("logo", "greeter"))

    def test_the_greeter_text_off_centre(self):
        canvas = boot_logo()
        col, row = place(1280, 800, 8, 16)
        text(canvas, br.TAGLINE, 0, row + 11, 8, 16)
        text(canvas, br.HINT, (160 - len(br.HINT)) // 2, row + 13, 8, 16)
        v = br.classify(canvas.frame(), self.logos)
        self.assertEqual(v.kind, "greeter")
        self.assertTrue(any("tagline" in note for note in v.notes), v.notes)


class BootTest(unittest.TestCase):
    """analyse() over a boot's frames."""

    def setUp(self):
        self.logos = logos()

    def analyse(self, frames, max_dark=0.5, samples=None):
        rows, problems, summary = br.analyse(frames, self.logos, max_dark, samples)
        return problems, summary

    def test_a_clean_boot(self):
        black = Canvas(1280, 800, (0, 0, 0)).frame()
        problems, summary = self.analyse([(0.0, black), (5.0, boot_logo(split=7).frame()),
                                          (8.0, greeter().frame()), (9.0, greeter().frame())])
        self.assertEqual(problems, [])
        self.assertEqual(summary["first logo"], 5.0)
        self.assertEqual(summary["greeter"], 8.0)

    def test_a_clean_boot_on_a_console_narrower_than_the_fitted_logo(self):
        black = Canvas(600, 800, (0, 0, 0)).frame()
        problems, summary = self.analyse([(0.0, black), (5.0, narrow(greeting=False).frame()),
                                          (8.0, narrow().frame()), (9.0, narrow().frame())])
        self.assertEqual(problems, [])
        self.assertEqual(summary["greeter"], 8.0)
        problems, _ = self.analyse([(0.0, black), (5.0, narrow(greeting=False).frame()),
                                    (8.0, narrow(wrapped=True).frame()), (9.0, narrow(wrapped=True).frame())])
        self.assertIn("no greeter on screen", problems)

    def test_text_between_the_boot_loader_and_the_logo(self):
        black = Canvas(1280, 800, (0, 0, 0))
        kernel = Canvas(1280, 800, (0, 0, 0))
        text(kernel, "[    0.043205] RDSEED32 is broken.", 0, 0, 8, 16)
        problems, _ = self.analyse([(0.0, black.frame()), (4.0, kernel.frame()), (4.3, boot_logo().frame()),
                                    (8.0, greeter().frame())])
        self.assertEqual(len(problems), 1)
        self.assertIn("text before the logo", problems[0])

    def test_a_boot_menu_right_before_the_logo_is_no_text_before_it(self):
        menu = Canvas(640, 480, (0, 0, 0))
        text(menu, "Omarchy install medium (x86_64, BIOS)", 10, 10, 8, 16)
        problems, _ = self.analyse([(0.0, menu.frame()), (5.0, boot_logo().frame()), (8.0, greeter().frame())])
        self.assertEqual(problems, [])

    def test_firmware_text_before_a_boot_menu_is_not_text_before_the_logo(self):
        seabios = Canvas(720, 400, (0, 0, 0))
        text(seabios, "SeaBIOS (version 1.17.0)", 0, 0, 9, 16)
        menu = Canvas(640, 480, (0, 0, 0))
        text(menu, "Omarchy install medium (x86_64, BIOS)", 10, 10, 8, 16)
        kernel = Canvas(1280, 800, (0, 0, 0))
        text(kernel, "[    0.043205] RDSEED32 is broken.", 0, 0, 8, 16)
        problems, _ = self.analyse([(0.0, seabios.frame()), (0.3, menu.frame()), (5.0, boot_logo().frame()), (8.0, greeter().frame())])
        self.assertEqual(problems, [])
        problems, _ = self.analyse([(0.3, menu.frame()), (4.7, kernel.frame()), (5.0, boot_logo().frame()), (8.0, greeter().frame())])
        self.assertEqual(len(problems), 1, problems)

    def test_the_menu_s_video_memory_for_a_frame_as_the_text_mode_comes(self):
        menu = Canvas(640, 480, (0, 0, 0))
        text(menu, "Omarchy install medium (x86_64, BIOS)", 10, 10, 8, 16)
        old = Canvas(1280, 800, (0, 0, 0))
        for x in range(0, 1280, 4):
            old.fill(x, 0, x + 1, 800, GREY)
        problems, summary = self.analyse([(5.0, menu.frame()), (5.04, old.frame()), (5.08, boot_logo().frame()),
                                          (8.0, greeter().frame())])
        self.assertEqual(problems, [])
        self.assertIn("showed the old video memory", summary["notes"][0])
        problems, _ = self.analyse([(5.0, menu.frame()), (5.04, old.frame()), (5.5, boot_logo().frame()),
                                    (8.0, greeter().frame())])
        self.assertEqual(len(problems), 1, problems)

    def test_a_mode_passed_through_between_the_logo_and_the_greeter(self):
        # A GPU driver's modeset through a mode that lasts one frame, its old
        # video memory lit all over, is a note and dark; the same screen in a
        # mode that stays, after the greeter, or between frames of one mode
        # is text on the screen, and so is a border around a line of text.
        vga = Canvas(720, 400, (0, 0, 0))
        old = Canvas(640, 400, (0, 0, 0))
        for x in range(0, 640, 4):
            old.fill(x, 0, x + 1, 400, GREY)
        fb = Canvas(800, 600, (0, 0, 0))

        def boot(*middle, after_greeter=()):
            return [(5.0, boot_logo().frame()), *middle, (8.2, greeter().frame()), *after_greeter, (9.0, greeter().frame())]

        problems, summary = self.analyse(boot((8.0, vga.frame()), (8.04, old.frame()), (8.08, fb.frame())))
        self.assertEqual(problems, [])
        self.assertEqual(summary["notes"], ["8.04 the switch to 640x400 showed the old video memory"])
        self.assertEqual(summary["longest dark"], 0.2)
        stays = Canvas(640, 400, (0, 0, 0)).frame()
        border = Canvas(640, 400, (0, 0, 0))
        border.fill(0, 0, 640, 2, GREY)
        border.fill(0, 398, 640, 400, GREY)
        border.fill(0, 0, 2, 400, GREY)
        border.fill(638, 0, 640, 400, GREY)
        text(border, "Kernel panic - not syncing", 10, 12, 8, 16)
        for frames in (boot((8.0, vga.frame()), (8.04, old.frame()), (8.08, stays)),
                       boot((8.0, vga.frame()), (8.04, old.frame()), (8.08, vga.frame()), (8.12, fb.frame())),
                       boot((8.0, vga.frame()), (8.04, border.frame()), (8.08, fb.frame())),
                       boot(after_greeter=((8.5, vga.frame()), (8.54, old.frame()), (8.58, fb.frame())))):
            problems, _ = self.analyse(frames)
            self.assertTrue(any("text on screen" in p for p in problems), problems)
        # Dark either side of it is one stretch with it.
        problems, _ = self.analyse([(5.0, boot_logo().frame()), (7.6, vga.frame()), (8.0, old.frame()), (8.04, fb.frame()),
                                    (8.48, greeter().frame()), (9.0, greeter().frame())])
        self.assertTrue(any("dark for 0.88 s" in p for p in problems), problems)

    def test_dark_between_the_logo_and_the_greeter(self):
        blank = Canvas(1280, 800).frame()
        frames = [(5.0, boot_logo().frame()), (6.0, blank), (6.8, boot_logo().frame()), (8.0, greeter().frame())]
        problems, summary = self.analyse(frames)
        self.assertTrue(any("dark for 0.80 s" in p for p in problems), problems)
        problems, _ = self.analyse(frames, max_dark=1.0)
        self.assertEqual(problems, [])

    def test_a_logo_off_the_greeters_place(self):
        canvas = Canvas(1280, 800)
        col, row = place(1280, 800, 8, 16)
        blocks(canvas, logo_lines(), col + 1, row, 8, 16, 8)
        problems, _ = self.analyse([(5.0, canvas.frame()), (8.0, greeter().frame())])
        self.assertTrue(any("greeter's place" in p for p in problems), problems)

    def test_a_clear_caught_half_way_is_a_note_a_lasting_one_a_problem(self):
        lines = logo_lines()
        half = boot_logo(skip={(r, c) for r in range(5, len(lines)) for c in range(len(lines[0]))}).frame()
        blank = Canvas(1280, 800).frame()
        rows, problems, summary = br.analyse([(5.0, boot_logo().frame()), (6.0, half), (6.04, blank),
                                              (6.08, boot_logo().frame()), (8.0, greeter().frame())], self.logos, 0.5)
        self.assertEqual(problems, [])
        self.assertIn("cleared half way", summary["notes"][0])
        _, problems, _ = br.analyse([(5.0, boot_logo().frame()), (6.0, half), (6.5, boot_logo().frame()),
                                     (8.0, greeter().frame())], self.logos, 0.5)
        self.assertTrue(any("partly missing for 0.50 s" in p for p in problems), problems)

    def test_a_cursor_between_the_logo_and_the_greeter(self):
        canvas = Canvas(1280, 800)
        canvas.fill(240, 302, 248, 304, GREEN)
        rows, problems, summary = br.analyse([(5.0, boot_logo().frame()), (6.0, canvas.frame()), (6.04, boot_logo().frame()),
                                              (8.0, greeter().frame())], self.logos, 0.5)
        self.assertEqual(len(problems), 1)
        self.assertIn("a speck on the screen", problems[0])
        self.assertEqual(summary["longest dark"], 0.04)

    def test_the_first_logo_caught_half_drawn_is_a_note(self):
        lines = logo_lines()
        half = boot_logo(skip={(r, c) for r in range(4, len(lines)) for c in range(len(lines[0]))}).frame()
        black = Canvas(1280, 800, (0, 0, 0)).frame()
        rows, problems, summary = br.analyse([(0.0, black), (4.96, half), (5.0, boot_logo().frame()),
                                              (8.0, greeter().frame())], self.logos, 0.5)
        self.assertEqual(problems, [])
        self.assertIn("drawn half way", summary["notes"][0])

    def test_the_first_logo_caught_half_drawn_with_the_cursor_where_it_writes_is_a_note(self):
        # ISOLINUX writing its logo with the VGA's cursor under the next cell:
        # an underline where the logo is dark. Two cells of it are no cursor.
        lines = logo_lines()
        col, row = place(1280, 800, 8, 16)
        c = lines[3].index(" ", 1)
        skip = {(r, k) for r in range(3, len(lines)) for k in range(len(lines[0])) if r > 3 or k >= c}
        black = Canvas(1280, 800, (0, 0, 0)).frame()
        for cells in (1, 2):
            half = boot_logo(skip=skip)
            half.fill((col + c) * 8, (row + 3) * 16 + 13, (col + c + cells) * 8, (row + 3) * 16 + 15, GREY)
            _, problems, summary = br.analyse([(0.0, black), (4.96, half.frame()), (5.0, boot_logo().frame()),
                                               (8.0, greeter().frame())], self.logos, 0.5)
            if cells == 1:
                self.assertEqual(problems, [])
                self.assertIn("drawn half way", summary["notes"][0])
                self.assertIn("a cursor at", summary["notes"][0])
            else:
                self.assertEqual(len(problems), 1)
                self.assertIn("text before the logo", problems[0])

    def test_the_first_logo_caught_with_the_cursor_on_the_row_below_it_is_a_note(self):
        # The rows drawn but the last, the cursor under the last row's first
        # cell without a lower half: below the drawn rows, past a dark gap.
        lines = logo_lines()
        col, row = place(1280, 800, 8, 16)
        last = len(lines) - 1
        c = next(k for k, char in enumerate(lines[last]) if char in " \u2580")
        half = boot_logo(skip={(last, k) for k in range(len(lines[last]))})
        half.fill((col + c) * 8, (row + last) * 16 + 13, (col + c + 1) * 8, (row + last) * 16 + 15, GREY)
        black = Canvas(1280, 800, (0, 0, 0)).frame()
        _, problems, summary = br.analyse([(0.0, black), (4.96, half.frame()), (5.0, boot_logo().frame()),
                                           (8.0, greeter().frame())], self.logos, 0.5)
        self.assertEqual(problems, [])
        self.assertIn("a cursor at", summary["notes"][0])

    def test_dark_frames_one_after_another_are_one_stretch(self):
        black = Canvas(1280, 800, (0, 0, 0)).frame()
        blank = Canvas(1280, 800).frame()
        _, problems, summary = br.analyse([(5.0, boot_logo().frame()), (6.0, black), (6.4, blank),
                                           (6.8, boot_logo().frame()), (8.0, greeter().frame())], self.logos, 0.5)
        self.assertTrue(any("dark for 0.80 s" in p for p in problems), problems)
        self.assertEqual(summary["longest dark"], 0.8)

    def test_text_on_the_logos_rows_is_stray_not_a_half_drawn_logo(self):
        canvas = boot_logo()
        col, row = place(1280, 800, 8, 16)
        text(canvas, "login:", 0, row + 2, 8, 16)
        _, problems, summary = br.analyse([(5.0, boot_logo().frame()), (6.0, canvas.frame()), (6.04, boot_logo().frame()),
                                           (8.0, greeter().frame())], self.logos, 0.5)
        self.assertTrue(any("lit pixels besides the logo" in p for p in problems), problems)
        self.assertNotIn("notes", summary)

    def test_a_cursor_for_a_frame_is_a_note_and_one_that_stays_a_problem(self):
        cursor = boot_logo()
        col, row = place(1280, 800, 8, 16)
        cursor.fill(0, (row + 14) * 16 + 13, 8, (row + 14) * 16 + 15, GREY)
        _, problems, summary = br.analyse([(5.0, boot_logo().frame()), (6.0, cursor.frame()), (6.04, boot_logo().frame()),
                                           (8.0, greeter().frame())], self.logos, 0.5)
        self.assertEqual(problems, [])
        self.assertIn("a cursor for 0.04 s", summary["notes"][0])
        _, problems, _ = br.analyse([(5.0, boot_logo().frame()), (6.0, cursor.frame()), (6.3, boot_logo().frame()),
                                     (8.0, greeter().frame())], self.logos, 0.5)
        self.assertTrue(any("lit pixels besides the logo" in p for p in problems), problems)

    def test_the_greeter_caught_half_drawn_for_a_frame_is_a_note(self):
        half = boot_logo()
        col, row = place(1280, 800, 8, 16)
        text(half, br.TAGLINE[20:], (160 - len(br.TAGLINE)) // 2 + 20, row + 11, 8, 16)
        text(half, br.HINT, (160 - len(br.HINT)) // 2, row + 13, 8, 16)
        problems, summary = self.analyse([(5.0, boot_logo().frame()), (6.0, half.frame()), (6.04, greeter().frame()),
                                          (8.0, greeter().frame())])
        self.assertEqual(problems, [])
        self.assertIn("greeter drawn half way", summary["notes"][0])
        problems, _ = self.analyse([(5.0, boot_logo().frame()), (6.0, half.frame()), (6.5, greeter().frame())])
        self.assertTrue(any("tagline" in p for p in problems), problems)

    def test_the_greeters_hint_before_its_tagline_for_a_frame_is_a_note(self):
        # The screen copied from fbcon's shadow while the greeter was writing:
        # the hint is there for a frame, the tagline not yet.
        hint = boot_logo()
        col, row = place(1280, 800, 8, 16)
        text(hint, br.HINT, (160 - len(br.HINT)) // 2, row + 13, 8, 16)
        problems, summary = self.analyse([(5.0, boot_logo().frame()), (6.0, hint.frame()), (6.04, greeter().frame()),
                                          (8.0, greeter().frame())])
        self.assertEqual(problems, [])
        self.assertIn("greeter drawn half way", summary["notes"][0])
        # On the screen longer than a frame, it is a problem.
        problems, _ = self.analyse([(5.0, boot_logo().frame()), (6.0, hint.frame()), (6.5, greeter().frame())])
        self.assertTrue(any("lit pixels besides the logo" in p for p in problems), problems)
        # Other text right before the greeter is not the greeter's.
        junk = boot_logo()
        text(junk, "login:", (160 - len(br.HINT)) // 2, row + 13, 8, 16)
        problems, _ = self.analyse([(5.0, boot_logo().frame()), (6.0, junk.frame()), (6.04, greeter().frame())])
        self.assertTrue(any("lit pixels besides the logo" in p for p in problems), problems)

    def test_a_frame_seen_by_one_sample_is_transient_on_a_slow_sampling(self):
        # 5 samples a second: the cursor frame lasted 0.2 s to the next change,
        # but one sample saw it; three samples seeing it is a cursor that stays.
        cursor = boot_logo()
        col, row = place(1280, 800, 8, 16)
        cursor.fill(0, (row + 14) * 16 + 13, 8, (row + 14) * 16 + 15, GREY)
        frames = [(5.0, boot_logo().frame()), (6.0, cursor.frame()), (6.2, boot_logo().frame()), (8.0, greeter().frame())]
        slow = [5.0 + 0.2 * k for k in range(16)]
        problems, summary = self.analyse(frames, samples=slow)
        self.assertEqual(problems, [])
        self.assertEqual(summary["samples a second"], 5.0)
        frames[2] = (6.6, boot_logo().frame())
        problems, _ = self.analyse(frames, samples=slow)
        self.assertTrue(any("lit pixels" in p for p in problems), problems)

    def test_a_full_screen_after_a_dark_frame_in_the_same_mode_is_text(self):
        # The old video memory excuse needs a mode switch before it.
        menu_black = Canvas(1280, 800, (0, 0, 0))
        old = Canvas(1280, 800, (0, 0, 0))
        for x in range(0, 1280, 4):
            old.fill(x, 0, x + 1, 800, GREY)
        problems, _ = self.analyse([(5.0, menu_black.frame()), (5.04, old.frame()), (5.08, boot_logo().frame()),
                                    (8.0, greeter().frame())])
        self.assertTrue(any("text before the logo" in p for p in problems), problems)

    def test_many_transient_frames_are_a_flicker(self):
        cursor = boot_logo()
        col, row = place(1280, 800, 8, 16)
        cursor.fill(0, (row + 14) * 16 + 13, 8, (row + 14) * 16 + 15, GREY)
        frames = [(5.0, boot_logo().frame())]
        for k in range(4):
            frames += [(5.5 + k, cursor.frame()), (5.54 + k, boot_logo().frame())]
        frames.append((10.0, greeter().frame()))
        problems, _ = self.analyse(frames)
        self.assertTrue(any("more than 3" in p for p in problems), problems)

    def test_many_short_dark_stretches_are_a_problem(self):
        black = Canvas(1280, 800, (0, 0, 0)).frame()
        frames = [(5.0, boot_logo().frame())]
        for k in range(4):
            frames += [(5.5 + k, black), (5.8 + k, boot_logo().frame())]
        frames.append((10.0, greeter().frame()))
        problems, _ = self.analyse(frames)
        self.assertTrue(any("in 4 stretches" in p for p in problems), problems)

    def test_the_first_logo_drawn_over_two_frames(self):
        # Row by row: the top half, then all but the last rows, then whole.
        lines = logo_lines()
        top = {(r, c) for r in range(len(lines) // 2, len(lines)) for c in range(len(lines[0]))}
        most = {(r, c) for r in range(len(lines) - 2, len(lines)) for c in range(len(lines[0]))}
        black = Canvas(1280, 800, (0, 0, 0)).frame()
        frames = [(4.0, black), (4.80, boot_logo(skip=top).frame()), (4.84, boot_logo(skip=most).frame()),
                  (4.88, boot_logo().frame()), (8.0, greeter().frame())]
        problems, summary = self.analyse(frames)
        self.assertEqual(problems, [])
        self.assertEqual(sum("drawn half way" in n for n in summary["notes"]), 2)
        frames[1] = (4.30, frames[1][1])
        problems, _ = self.analyse(frames)
        self.assertTrue(any("text before the logo" in p for p in problems), problems)

    def test_a_sliver_of_the_logo_on_a_dark_frame_before_it_is_a_note(self):
        col, row = place(1280, 800, 8, 16)
        sliver = Canvas(1280, 800)
        sliver.fill((col + 41) * 8, (row + 9) * 16 + 15, (col + 46) * 8, (row + 9) * 16 + 16, GREEN)
        frames = [(5.0, boot_logo().frame()), (6.0, Canvas(1280, 800).frame()), (6.04, sliver.frame()),
                  (6.08, boot_logo().frame()), (8.0, greeter().frame())]
        problems, summary = self.analyse(frames)
        self.assertEqual(problems, [])
        self.assertIn("a speck of it", summary["notes"][0])
        # Outside the logo it is a speck still (a cursor).
        stray = Canvas(1280, 800)
        stray.fill(0, 780, 8, 782, GREY)
        frames[2] = (6.04, stray.frame())
        problems, _ = self.analyse(frames)
        self.assertTrue(any("speck" in p for p in problems), problems)

    def test_a_dark_frame_after_the_greeter(self):
        problems, _ = self.analyse([(5.0, boot_logo().frame()), (8.0, greeter().frame()),
                                    (8.5, Canvas(1280, 800).frame()), (8.6, greeter().frame())])
        self.assertTrue(any("after the greeter" in p for p in problems), problems)


class FontTest(unittest.TestCase):
    """The logo drawn with the real console fonts, the way the boot draws it."""

    def setUp(self):
        self.logos = logos()

    def draw(self, font, slot_of, split=None):
        glyphs, slot, width, height = read_psf(font)
        canvas = Canvas(1280, 800)
        col, row = place(1280, 800, 8, 16)
        for r, line in enumerate(logo_lines()):
            for c, char in enumerate(line):
                if char != " ":
                    rows = glyphs[slot_of(char, slot)]
                    canvas.glyph((col + c) * 8, (row + r) * 16, rows, 8, GREEN)
        return canvas.frame()

    @unittest.skipUnless(KERNEL_FONT.is_file(), "kbd's default8x16 is not installed")
    def test_the_kernels_font(self):
        v = br.classify(self.draw(KERNEL_FONT, lambda char, slot: slot[char]), self.logos)
        self.assertEqual(v.kind, "logo")
        self.assertEqual(v.geometry.split, 7)

    @unittest.skipUnless(KERNEL_FONT.is_file() and TERMINUS.is_file(), "kbd's default8x16 or terminus-font missing")
    def test_terminus_loaded_under_a_logo_in_the_kernels_font(self):
        # The screen keeps the kernel font's slots; unpatched Terminus has box
        # drawing in them (the X200's frame of ├ ┴ │).
        _, kernel_slot, _, _ = read_psf(KERNEL_FONT)
        frame = self.draw(TERMINUS, lambda char, slot: kernel_slot[char])
        self.assertNotIn(br.classify(frame, self.logos).kind, ("logo", "greeter"))
        _, problems, _ = br.analyse([(5.0, greeter().frame()), (5.1, frame), (5.2, greeter().frame())],
                                 self.logos, 0.5)
        self.assertTrue(any("garbled" in p for p in problems), problems)

    @unittest.skipUnless(KERNEL_FONT.is_file() and LOGO.is_file(), "kbd's default8x16 or the Omarchy logo missing")
    def test_the_half_size_logo_in_its_vga_font(self):
        with tempfile.TemporaryDirectory() as work:
            import subprocess

            subprocess.run([sys.executable, str(SHARE / "vga-logo-font.py"), str(LOGO), str(KERNEL_FONT), work],
                           check=True, capture_output=True)
            glyphs, slot, _, _ = read_psf(Path(work) / "vga.psf")
            lines = (Path(work) / "vga.txt").read_text(encoding="utf-8").rstrip("\n").split("\n")
        canvas = Canvas(720, 400, (0, 0, 0))
        col, row = (80 - 41) // 2, (25 - 5 - 2) // 2
        for r, line in enumerate(lines):
            for c, char in enumerate(line):
                if char == " ":
                    continue
                index = slot[char]
                rows = list(glyphs[index])
                if 0xC0 <= index <= 0xDF:  # the VGA repeats the 8th column in the 9th
                    rows = [bits << 1 | bits & 1 for bits in rows]
                else:
                    rows = [bits << 1 for bits in rows]
                canvas.glyph((col + c) * 9, (row + r) * 16, rows, 9, GREEN)
        v = br.classify(canvas.frame(), self.logos)
        self.assertEqual(v.kind, "logo")
        self.assertTrue(v.geometry.vga)
        self.assertEqual((v.geometry.ox, v.geometry.oy), (col * 9, row * 16))
        self.assertIsNone(v.stray)


def newc(files):
    """A newc cpio archive of NAME -> bytes, with its trailer."""
    out = b""
    for ino, (name, body) in enumerate(list(files.items()) + [("TRAILER!!!", b"")], 1):
        encoded = name.encode() + b"\0"
        fields = [ino, 0o100644, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(encoded), 0]
        header = b"070701" + b"".join(b"%08x" % f for f in fields)
        out += header + encoded + bytes(-(len(header) + len(encoded)) % 4) + body + bytes(-len(body) % 4)
    return out


class InitramfsTest(unittest.TestCase):
    def test_files_out_of_an_early_archive_and_a_compressed_one(self):
        import gzip as gz

        early = newc({"kernel/x86/microcode/GenuineIntel.bin": b"\xff" * 37})
        main = newc({"init": b"#!/bin/sh\n", "usr/share/omarchy-iso/console-logo/greeter.txt": "█▀▄\n".encode()})
        image = early + bytes(512) + gz.compress(main)
        found = br.cpio_files(image, {"usr/share/omarchy-iso/console-logo/greeter.txt", "kernel/x86/microcode/GenuineIntel.bin"})
        self.assertEqual(found["usr/share/omarchy-iso/console-logo/greeter.txt"], "█▀▄\n".encode())
        self.assertEqual(found["kernel/x86/microcode/GenuineIntel.bin"], b"\xff" * 37)

    def test_the_logos_as_an_iso_carries_them(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            self.assertIsNone(br.load_logos(directory))
            lines = logo_lines()
            (directory / "greeter.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
            (directory / "fitted.txt").write_text("\n".join(line[:9] + line[10:] for line in lines) + "\n", encoding="utf-8")
            logos = br.load_logos(directory)
        width = max(len(line) for line in lines)
        self.assertEqual([(logo.name, logo.cols) for logo in logos], [("greeter", width), ("fitted", width - 1)])


class PngTest(unittest.TestCase):
    def test_round_trip(self):
        frame = greeter().frame()
        with tempfile.TemporaryDirectory() as work:
            path = Path(work) / "f.png"
            br.write_png(path, frame)
            again = br.read_png(path)
        self.assertEqual((again.width, again.height, again.rgb), (frame.width, frame.height, frame.rgb))


if __name__ == "__main__":
    unittest.main()
