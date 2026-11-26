"""Write this install's keyboard layout into the pre-built UKI.

The UKI is built with the image, so its initramfs knows no layout: the
console and the disk password prompt come up in us. An install that picked
another layout used to build its own UKI instead, which is 4.7 s of
mkinitcpio on the install's clock for everyone not typing on a US keyboard.

build-root-image.sh reserves the room, as it does for the cmdline
(uki_cmdline.py): the initramfs carries every console keymap, and an
/etc/vconsole.conf that is one comment line of ROOM bytes. mkinitcpio keeps
that file in the early cpio, the uncompressed archive at the start of the
initramfs, so its bytes sit in the UKI as they are. Writing the install's
settings over them, padded back to ROOM bytes, moves nothing: no section
resizes, no mkinitcpio run, a few milliseconds. The kernel unpacks the early
cpio like any other, so the initramfs boots with the file it would have had
if it were built here: systemd-vconsole-setup loads KEYMAP for the console,
and Plymouth reads the XKB settings for its password prompt (its hook
already ships /usr/share/X11/xkb).

It has to happen before limine-entry-tool registers the UKI, because the
entry pins its BLAKE2B hash.
"""

from __future__ import annotations

import mmap
from pathlib import Path

ROOM = 512
MARKER = b"# omarchy.vconsole_room "
# What the initramfs uses: the console keymap and Plymouth's XKB layout. A
# FONT= names a file only an initramfs built for it carries.
SETTINGS = ("KEYMAP", "XKB")
# Layouts that cannot type Latin letters. Keep in sync with
# etc/mkinitcpio.conf.d/omarchy_hooks.conf and omarchy_vconsole.conf in omarchy.
NON_LATIN_LAYOUTS = frozenset(
    "af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm mn mv np rs ru sy th tj ua".split()
)


def vconsole_is_nonlatin(vconsole: Path) -> bool:
    """Whether vconsole.conf's leading XKBLAYOUT cannot type Latin letters.

    Matches omarchy_hooks.conf and omarchy_vconsole.conf, which leave
    /etc/vconsole.conf out of the initramfs for these layouts so the LUKS
    prompt uses US, while preserving Latin variants such as rs(latin)
    (Serbian Latin, sr-latin).
    """
    try:
        lines = vconsole.read_text().splitlines()
    except OSError:
        return False
    layout = ""
    variant = ""
    for line in lines:
        line = line.strip()
        if line.startswith("XKBLAYOUT="):
            value = line.partition("=")[2].split("#", 1)[0].strip().strip("\"'")
            layout = value.split(",", 1)[0]
        elif line.startswith("XKBVARIANT="):
            value = line.partition("=")[2].split("#", 1)[0].strip().strip("\"'")
            variant = value.split(",", 1)[0]
    if layout == "rs" and variant.startswith("latin"):
        return False
    return layout in NON_LATIN_LAYOUTS


def placeholder() -> bytes:
    """The file the image build reserves: a comment, so until it is
    overwritten the initramfs has no settings and comes up in us."""
    return MARKER + b"#" * (ROOM - len(MARKER) - 1) + b"\n"


def _settings(vconsole: Path) -> bytes | None:
    """The keyboard lines of a vconsole.conf, padded with a comment to ROOM
    bytes. None when there are none, the leading XKB layout is non-Latin, or
    they do not fit."""
    if vconsole_is_nonlatin(vconsole):
        return None
    try:
        lines = [line.strip() for line in vconsole.read_text().splitlines()]
    except OSError:
        return None
    wanted = "".join(f"{line}\n" for line in lines if line.startswith(SETTINGS)).encode()
    padding = ROOM - len(wanted) - 1
    if not wanted or padding < 1:
        return None
    return wanted + b"#" * padding + b"\n"


def _room(image: mmap.mmap) -> int:
    """Where the reserved file starts, or -1 unless it is there exactly once."""
    reserved = placeholder()
    offset = image.find(reserved)
    if offset < 0 or image.find(reserved, offset + 1) >= 0:
        return -1
    return offset


def vconsole_fits(uki: Path, vconsole: Path) -> bool:
    """Whether embed_vconsole would succeed: the UKI has the reserved room
    untouched, and the settings fit it."""
    if _settings(vconsole) is None:
        return False
    try:
        with uki.open("rb") as stream, mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as image:
            return _room(image) >= 0
    except (OSError, ValueError):
        return False


def embed_vconsole(uki: Path, vconsole: Path) -> bool:
    """Overwrite the UKI's reserved vconsole.conf with the keyboard settings
    of the given one. False (UKI untouched) if it cannot."""
    settings = _settings(vconsole)
    if settings is None:
        return False
    try:
        with uki.open("r+b") as stream, mmap.mmap(stream.fileno(), 0) as image:
            offset = _room(image)
            if offset < 0:
                return False
            image[offset:offset + ROOM] = settings
    except (OSError, ValueError):
        return False
    return True
