#!/usr/bin/env python3
"""Write a GRUB font (PFF2) at twice the size by doubling every pixel.

The boot menu draws in the installer's console face, Terminus Bold. Terminus
keeps a 2 px stroke at every size, so its 28 and 32 px builds read thin next
to the 16 px font the console shows; GRUB cannot scale a bitmap font itself.
Doubling the 16 px font gives the console's own glyphs at menu size.

Usage: grub-font-double.py <in.pf2> <out.pf2> <family>

PFF2 (grub-core/font/font.c): sections of a 4-byte tag, a big-endian length
and data. CHIX lists each character as code point (u32), storage flags (u8)
and the file offset of its glyph (u32); DATA has length 0xffffffff and holds
the glyphs: width, height (u16), x and y offset, device width (s16), then the
bitmap, rows packed together most significant bit first.
"""

import struct
import sys

SCALED = {b"PTSZ", b"MAXW", b"MAXH", b"ASCE", b"DESC"}


def sections(data):
    pos = 0
    while pos < len(data):
        tag, length = data[pos:pos + 4], struct.unpack(">I", data[pos + 4:pos + 8])[0]
        pos += 8
        if tag == b"DATA":
            yield tag, None
            return
        yield tag, data[pos:pos + length]
        pos += length


def double_glyph(glyph):
    width, height, xoff, yoff, dwidth = struct.unpack(">HHhhh", glyph[:10])
    bits = glyph[10:]
    rows = []
    for y in range(height):
        row = []
        for x in range(width):
            i = y * width + x
            row += [(bits[i // 8] >> (7 - i % 8)) & 1] * 2
        rows += [row, row]
    flat = [b for row in rows for b in row]
    packed = bytearray((len(flat) + 7) // 8)
    for i, b in enumerate(flat):
        if b:
            packed[i // 8] |= 0x80 >> (i % 8)
    return struct.pack(">HHhhh", width * 2, height * 2, xoff * 2, yoff * 2, dwidth * 2) + bytes(packed)


def glyph_at(data, offset):
    width, height = struct.unpack(">HH", data[offset:offset + 4])
    return data[offset:offset + 10 + (width * height + 7) // 8]


def double(data, family):
    head = []
    chix = None
    weight = b""
    for tag, body in sections(data):
        if tag == b"DATA":
            break
        if tag == b"CHIX":
            chix = body
            continue
        if tag in SCALED:
            body = struct.pack(">H", struct.unpack(">H", body)[0] * 2)
        if tag == b"FAMI":
            body = family.encode() + b"\0"
        if tag == b"WEIG":
            weight = body.rstrip(b"\0")
        head.append([tag, body])
    if chix is None:
        raise ValueError("not a PFF2 font: no CHIX section")

    size = next(struct.unpack(">H", b)[0] for t, b in head if t == b"PTSZ")
    name = f"{family} {weight.decode().capitalize()} {size}".encode() + b"\0"
    for section in head:
        if section[0] == b"NAME":
            section[1] = name

    entries = [struct.unpack(">IBI", chix[i:i + 9]) for i in range(0, len(chix), 9)]
    glyphs = [double_glyph(glyph_at(data, offset)) for _, _, offset in entries]

    out = bytearray()
    for tag, body in head:
        out += tag + struct.pack(">I", len(body)) + body
    data_start = len(out) + 8 + len(entries) * 9 + 8
    index = bytearray()
    offset = data_start
    for (code, flags, _), glyph in zip(entries, glyphs):
        index += struct.pack(">IBI", code, flags, offset)
        offset += len(glyph)
    out += b"CHIX" + struct.pack(">I", len(index)) + index
    out += b"DATA" + struct.pack(">I", 0xFFFFFFFF)
    for glyph in glyphs:
        out += glyph
    return bytes(out)


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__.split("\n\n")[2])
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    with open(sys.argv[2], "wb") as f:
        f.write(double(data, sys.argv[3]))


if __name__ == "__main__":
    main()
