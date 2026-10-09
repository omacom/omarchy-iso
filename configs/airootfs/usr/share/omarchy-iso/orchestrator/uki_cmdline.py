"""Write this install's kernel cmdline into the pre-built UKI.

The UKI is built with the image, so its embedded .cmdline cannot name the
root. Limine's entry carries the real cmdline and that is all a Limine boot
needs, but EFI/Linux/*.efi is a Boot Loader Specification Type #2 image:
rEFInd, systemd-boot and firmware boot entries run it directly, with no
cmdline. On a full-disk install systemd-gpt-auto-generator then finds the
root by its GPT type. A free-space install's root is a plain Linux partition
(and a disk with two installs has two roots), so booted from rEFInd it
waits on /dev/gpt-auto-root for 90 s with no passphrase prompt. A UKI every
later kernel update builds embeds the full cmdline; this makes the first one
do the same.

build-root-image.sh reserves the room: the build-time cmdline ends in one
long placeholder parameter, so .cmdline has room for any real one. Embedding
overwrites those bytes in place, space-padded, and moves nothing: no section
resizes, no ukify run, a few milliseconds. It has to happen before
limine-entry-tool registers the UKI, because the entry pins its BLAKE2B hash.
"""

from __future__ import annotations

import struct
from pathlib import Path

PLACEHOLDER = "omarchy.cmdline_room="


def _cmdline_section(header: bytes) -> tuple[int, int] | None:
    """(file offset, byte length) of .cmdline, from the PE section table."""
    if len(header) < 0x40 or header[:2] != b"MZ":
        return None
    pe = struct.unpack_from("<I", header, 0x3C)[0]
    if header[pe:pe + 4] != b"PE\0\0":
        return None
    sections, optional_size = struct.unpack_from("<H", header, pe + 6)[0], struct.unpack_from("<H", header, pe + 20)[0]
    table = pe + 24 + optional_size
    for index in range(sections):
        entry = table + 40 * index
        if header[entry:entry + 8].rstrip(b"\0") == b".cmdline":
            virtual_size, _, raw_size, raw_offset = struct.unpack_from("<IIII", header, entry + 8)
            return raw_offset, min(virtual_size, raw_size)
    return None


def embed_cmdline(uki: Path, cmdline: str) -> bool:
    """Overwrite the UKI's embedded cmdline. False (UKI untouched) if it cannot."""
    data = " ".join(cmdline.split()).encode()
    with uki.open("r+b") as image:
        found = _cmdline_section(image.read(4096))
        if found is None:
            return False
        offset, room = found
        image.seek(offset)
        if PLACEHOLDER.encode() not in image.read(room) or len(data) > room:
            return False
        image.seek(offset)
        image.write(data.ljust(room, b" "))
    return True
