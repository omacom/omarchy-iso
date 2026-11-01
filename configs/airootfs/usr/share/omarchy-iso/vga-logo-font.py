#!/usr/bin/python
"""The Omarchy logo at half size for the VGA text console, as a console font.

A BIOS machine boots on the VGA text console: 80x25 cells of 9x16 pixels,
720x400 stretched over the panel. The greeter's logo is 81 columns of block
glyphs and fills that width; on a framebuffer console of 8x16 cells it fills
about half of a 1280x800 panel. To show the logo there at the greeter's size,
each cell carries a 2x4 piece of the logo's pixel grid (a block glyph is one
column wide and two pixels high), drawn into glyphs of its own: 41x5 cells,
which on a 1280x800 panel are the greeter's 648x160 pixels.

The VGA draws the 9th pixel column of a cell blank, except for the glyphs in
0xC0-0xDF, whose 8th column it repeats there. Pieces whose ink runs on into
the next cell go into 0xC0-0xDA, the rest into 0xE0-0xFD.

The font is BASE-FONT (CP437 order, like the kernel's own console fonts)
with those slots replaced, and keeps its Unicode table for every other slot:
the box drawing it gives up is unused at boot, and the full, lower and upper
blocks (0xDB, 0xDC, 0xDF) stay. A GPU driver taking the console over draws
it in the kernel's default font, also CP437, and keeps the VT's Unicode
table: this one still maps the greeter's logo to the right glyphs there, so
the console needs no font loaded after the takeover (a font loaded as the
driver registers its framebuffer can be undone by it, QEMU showed).

Writes into DIRECTORY:
  vga.psf   a PSF2 font, 256 glyphs of 8x16: BASE-FONT with the logo's pieces,
            which its Unicode table maps to U+E000 onwards
  vga.txt   the logo in those private-use characters, a line per cell row
  vga.cols  its width in cells

Usage: vga-logo-font.py LOGO.txt BASE-FONT.psf[.gz] DIRECTORY
"""

from __future__ import annotations

import gzip
import struct
import sys
from pathlib import Path

PSF1_MAGIC = b"\x36\x04"
PSF2_MAGIC = b"\x72\xb5\x4a\x86"
PRIVATE_USE = 0xE000
TOP = {"█": 1, "▀": 1, "▄": 0, " ": 0}
BOTTOM = {"█": 1, "▀": 0, "▄": 1, " ": 0}
CELL_COLS, CELL_ROWS = 2, 4  # logo pixels per cell
CONTINUING = range(0xC0, 0xDB)  # the VGA repeats their 8th column in the 9th; 0xDB-0xDF are blocks
ENDING = range(0xE0, 0xFE)


def read_font(path: Path) -> tuple[list[bytes], dict[int, list[int]], int, int]:
    """Glyph bitmaps, glyph index -> its codepoints, width and height."""
    data = path.read_bytes()
    if data[:2] == b"\x1f\x8b":
        data = gzip.decompress(data)
    if data[:4] == PSF2_MAGIC:
        _, _, header, flags, count, size, height, width = struct.unpack("<4sIIIIIII", data[:32])
        glyphs = [data[header + i * size:header + (i + 1) * size] for i in range(count)]
        table = data[header + count * size:] if flags & 1 else b""
        chars: dict[int, list[int]] = {}
        for index, entry in enumerate(table.split(b"\xff")[:count]):
            for sequence in entry.split(b"\xfe")[:1]:
                chars[index] = [ord(char) for char in sequence.decode("utf-8", "replace")]
        return glyphs, chars, width, height
    if data[:2] == PSF1_MAGIC:
        mode, height = data[2], data[3]
        count = 512 if mode & 1 else 256
        glyphs = [data[4 + i * height:4 + (i + 1) * height] for i in range(count)]
        chars = {}
        if mode & 2:
            table = data[4 + count * height:]
            for index in range(count):
                while table:
                    (value,) = struct.unpack("<H", table[:2])
                    table = table[2:]
                    if value == 0xFFFF:
                        break
                    if value != 0xFFFE:
                        chars.setdefault(index, []).append(value)
        return glyphs, chars, 8, height
    raise SystemExit(f"{path}: not a PSF font")


def logo_pixels(path: Path) -> list[list[int]]:
    lines = path.read_text(encoding="utf-8").rstrip("\n").split("\n")
    width = max(len(line) for line in lines)
    pixels = []
    for line in lines:
        line = line.ljust(width)
        if any(char not in TOP for char in line):
            raise SystemExit(f"{path}: only block glyphs and spaces can be drawn")
        pixels.append([TOP[char] for char in line])
        pixels.append([BOTTOM[char] for char in line])
    width += -width % CELL_COLS
    for row in pixels:
        row.extend([0] * (width - len(row)))
    pixels.extend([[0] * width for _ in range(-len(pixels) % CELL_ROWS)])
    return pixels


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    logo, base, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    pixels = logo_pixels(logo)
    base_glyphs, base_chars, base_width, base_height = read_font(base)
    if (base_width, base_height) != (8, 16) or len(base_glyphs) < 256:
        raise SystemExit(f"{base}: {len(base_glyphs)} glyphs of {base_width}x{base_height}, the VGA console needs 256 of 8x16")
    if any(base_chars.get(slot) != [code] for slot, code in ((0xDB, 0x2588), (0xDC, 0x2584), (0xDF, 0x2580), (0x41, 0x41))):
        raise SystemExit(f"{base}: not in CP437 order")

    blank = (0,) * (CELL_COLS * CELL_ROWS)
    cells = []
    for y in range(0, len(pixels), CELL_ROWS):
        cells.append([
            tuple(pixels[y + dy][x + dx] for dy in range(CELL_ROWS) for dx in range(CELL_COLS))
            for x in range(0, len(pixels[0]), CELL_COLS)
        ])
    # Pieces in order of first appearance; those whose right column meets ink in
    # the next cell's left column need the VGA's 9th column.
    pieces: list[tuple[int, ...]] = []
    continuing: set[tuple[int, ...]] = set()
    for row in cells:
        for x, piece in enumerate(row):
            if piece == blank:
                continue
            if piece not in pieces:
                pieces.append(piece)
            following = row[x + 1] if x + 1 < len(row) else blank
            if any(piece[dy * CELL_COLS + 1] and following[dy * CELL_COLS] for dy in range(CELL_ROWS)):
                continuing.add(piece)
    free = list(ENDING)
    wide = list(CONTINUING)
    if len(continuing) > len(wide) or len(pieces) - len(continuing) > len(free):
        raise SystemExit(f"{len(pieces)} logo pieces, {len(continuing)} of them continuing: more than the font has room for")

    glyphs = [glyph[:16] for glyph in base_glyphs[:256]]
    unicode: list[list[int]] = [list(base_chars.get(slot, [])) for slot in range(256)]
    slot_of: dict[tuple[int, ...], int] = {}
    for number, piece in enumerate(pieces):
        slot = wide.pop(0) if piece in continuing else free.pop(0)
        slot_of[piece] = slot
        rows = bytearray()
        for dy in range(CELL_ROWS):
            byte = (0xF0 if piece[dy * CELL_COLS] else 0) | (0x0F if piece[dy * CELL_COLS + 1] else 0)
            rows += bytes([byte]) * (16 // CELL_ROWS)
        glyphs[slot] = bytes(rows)
        unicode[slot] = [PRIVATE_USE + number]

    out.mkdir(parents=True, exist_ok=True)
    table = b"".join("".join(map(chr, codes)).encode() + b"\xff" for codes in unicode)
    header = struct.pack("<4sIIIIIII", PSF2_MAGIC, 0, 32, 1, 256, 16, 16, 8)
    (out / "vga.psf").write_bytes(header + b"".join(glyphs) + table)
    lines = []
    for row in cells:
        line = "".join(" " if piece == blank else chr(PRIVATE_USE + pieces.index(piece)) for piece in row)
        lines.append(line.rstrip())
    (out / "vga.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (out / "vga.cols").write_text(f"{max(len(line) for line in lines)}\n")
    print(f"vga-logo-font: {max(len(line) for line in lines)}x{len(lines)} cells, "
          f"{len(pieces)} pieces ({len(continuing)} continuing)", file=sys.stderr)


if __name__ == "__main__":
    main()
