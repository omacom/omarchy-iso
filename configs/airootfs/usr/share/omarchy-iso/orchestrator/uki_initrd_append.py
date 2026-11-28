"""Append small machine-specific files to a pre-built UKI's .initrd section.

Linux unpacks concatenated CPIO archives sequentially from the initrd buffer,
skipping NUL padding between archives (init/initramfs.c). When a pre-built
Qualcomm UKI lacks only a board's small early DRM firmware blob(s) named by
qcom-firmware.conf (typically 2-50 KiB), appending an uncompressed SVR4 newc
CPIO archive directly to the trailing .initrd PE section avoids a ~10 s
mkinitcpio + ukify rebuild on the laptop while producing an equivalent initrd.

Safety invariants (returns False, leaving the UKI untouched, if any fail):
  - Valid PE32+ executable with no Authenticode signature (Security directory = 0).
  - Exactly one .initrd section, and it is strictly the last section both on
    disk (PointerToRawData + SizeOfRawData == file size) and in virtual address
    space, so extending it moves no other section or header.
  - Every archive path is normalized, relative, and free of traversal segments.
"""

from __future__ import annotations

import struct
from pathlib import Path

_DOS_MAGIC = b"MZ"
_PE_MAGIC = b"PE\x00\x00"
_PE32PLUS_MAGIC = 0x20B
_SEC_HEADER_SIZE = 40
_SEC_DIR_INDEX = 4  # IMAGE_DIRECTORY_ENTRY_SECURITY
_CPIO_TRAILER = "TRAILER!!!"


def _align_up(value: int, alignment: int) -> int:
    if alignment <= 1:
        return value
    return (value + alignment - 1) & ~(alignment - 1)


def _newc_entry(name: str, data: bytes, mode: int, ino: int) -> bytes:
    name_bytes = name.encode("utf-8") + b"\x00"
    header = (
        f"070701"
        f"{ino:08x}"
        f"{mode:08x}"
        f"{0:08x}"  # uid
        f"{0:08x}"  # gid
        f"{1:08x}"  # nlink
        f"{0:08x}"  # mtime
        f"{len(data):08x}"
        f"{0:08x}"  # devmajor
        f"{0:08x}"  # devminor
        f"{0:08x}"  # rdevmajor
        f"{0:08x}"  # rdevminor
        f"{len(name_bytes):08x}"
        f"{0:08x}"  # check
    ).encode("ascii")
    out = bytearray(header)
    out.extend(name_bytes)
    pad = (-len(out)) & 3
    if pad:
        out.extend(b"\x00" * pad)
    if data:
        out.extend(data)
        dpad = (-len(data)) & 3
        if dpad:
            out.extend(b"\x00" * dpad)
    return bytes(out)


def build_newc_cpio(files: list[tuple[str, bytes]]) -> bytes:
    """Build an uncompressed SVR4 newc CPIO archive for relative (arcpath, bytes) pairs."""
    out = bytearray()
    emitted_dirs: set[str] = set()
    ino = 1

    for raw_path, data in files:
        parts = [p for p in raw_path.lstrip("/").split("/") if p]
        if not parts or any(p in (".", "..") for p in parts):
            raise ValueError(f"Unsafe CPIO path: {raw_path!r}")
        for depth in range(1, len(parts)):
            d = "/".join(parts[:depth])
            if d not in emitted_dirs:
                emitted_dirs.add(d)
                out.extend(_newc_entry(d, b"", 0o040755, ino))
                ino += 1
        arcpath = "/".join(parts)
        out.extend(_newc_entry(arcpath, data, 0o100644, ino))
        ino += 1

    out.extend(_newc_entry(_CPIO_TRAILER, b"", 0, 0))
    return bytes(out)


def _parse_trailing_initrd(blob: bytes, file_size: int) -> dict | None:
    if len(blob) < 0x40 or blob[:2] != _DOS_MAGIC:
        return None
    pe_off = struct.unpack_from("<I", blob, 0x3C)[0]
    if pe_off + 24 > len(blob) or blob[pe_off:pe_off + 4] != _PE_MAGIC:
        return None

    num_sections = struct.unpack_from("<H", blob, pe_off + 6)[0]
    opt_size = struct.unpack_from("<H", blob, pe_off + 20)[0]
    opt_off = pe_off + 24
    sec_off = opt_off + opt_size
    if opt_size < 112 or sec_off + num_sections * _SEC_HEADER_SIZE > len(blob):
        return None

    opt_magic = struct.unpack_from("<H", blob, opt_off)[0]
    if opt_magic != _PE32PLUS_MAGIC:
        return None

    section_align = struct.unpack_from("<I", blob, opt_off + 32)[0]
    file_align = struct.unpack_from("<I", blob, opt_off + 36)[0]
    if section_align < 512 or file_align < 512:
        return None
    if (section_align & (section_align - 1)) or (file_align & (file_align - 1)):
        return None

    # Refuse signed PE binaries so we never silently corrupt an Authenticode signature.
    num_rva = struct.unpack_from("<I", blob, opt_off + 108)[0]
    if num_rva > _SEC_DIR_INDEX:
        dd_off = opt_off + 112 + _SEC_DIR_INDEX * 8
        if dd_off + 8 <= opt_off + opt_size:
            sec_rva, sec_sz = struct.unpack_from("<II", blob, dd_off)
            if sec_rva != 0 or sec_sz != 0:
                return None

    initrd_idx = None
    max_file_end = 0
    max_va_end = 0
    sections = []
    for i in range(num_sections):
        o = sec_off + i * _SEC_HEADER_SIZE
        name = blob[o:o + 8].rstrip(b"\x00").decode("ascii", errors="replace")
        vsize, vaddr, rsize, rptr = struct.unpack_from("<IIII", blob, o + 8)
        sections.append((i, o, name, vsize, vaddr, rsize, rptr))
        if name == ".initrd":
            if initrd_idx is not None:
                return None
            initrd_idx = i
        else:
            max_file_end = max(max_file_end, rptr + rsize)
            max_va_end = max(max_va_end, vaddr + max(vsize, rsize))

    if initrd_idx is None:
        return None
    _, hdr_off, _, vsize, vaddr, rsize, rptr = sections[initrd_idx]
    if rptr == 0 or rptr < max_file_end or vaddr < max_va_end:
        return None
    if rptr + rsize != file_size:
        return None
    if vsize > rsize:
        return None

    return {
        "opt_off": opt_off,
        "hdr_off": hdr_off,
        "section_align": section_align,
        "file_align": file_align,
        "vsize": vsize,
        "vaddr": vaddr,
        "rsize": rsize,
        "rptr": rptr,
    }


def can_append_initrd(uki: Path) -> bool:
    """Return True if uki is an unsigned PE32+ UKI with .initrd as its final section."""
    try:
        file_size = uki.stat().st_size
        with uki.open("rb") as f:
            head = f.read(min(file_size, 65536))
    except OSError:
        return False
    return _parse_trailing_initrd(head, file_size) is not None


def append_files_to_initrd(uki: Path, files: list[tuple[str, bytes]]) -> bool:
    """Append an uncompressed newc CPIO carrying files to uki's trailing .initrd section.

    Updates VirtualSize, SizeOfRawData, SizeOfImage, and clears the PE CheckSum
    (matching ukify's unsigned UKI output). Returns True on success, False
    without modifying uki if the binary layout does not satisfy the safety checks.
    """
    if not files:
        return True
    try:
        cpio_bytes = build_newc_cpio(files)
        file_size = uki.stat().st_size
        with uki.open("r+b") as f:
            head = f.read(min(file_size, 65536))
            info = _parse_trailing_initrd(head, file_size)
            if info is None:
                return False

            # Place the appended CPIO on a 4-byte boundary after VirtualSize;
            # Linux's initramfs unpacker skips intervening NUL bytes between
            # concatenated archives.
            write_rel = _align_up(info["vsize"], 4)
            write_abs = info["rptr"] + write_rel
            new_vsize = write_rel + len(cpio_bytes)
            new_rsize = _align_up(new_vsize, info["file_align"])
            new_file_size = info["rptr"] + new_rsize
            new_size_of_image = _align_up(info["vaddr"] + new_vsize, info["section_align"])

            # Zero any bytes between previous VirtualSize and write_rel (if any),
            # write CPIO, and pad to new_file_size.
            if write_rel > info["vsize"]:
                f.seek(info["rptr"] + info["vsize"])
                f.write(b"\x00" * (write_rel - info["vsize"]))
            f.seek(write_abs)
            f.write(cpio_bytes)
            trail_pad = new_file_size - (write_abs + len(cpio_bytes))
            if trail_pad > 0:
                f.write(b"\x00" * trail_pad)
            f.truncate(new_file_size)

            # Update .initrd VirtualSize & SizeOfRawData
            f.seek(info["hdr_off"] + 8)
            f.write(struct.pack("<I", new_vsize))
            f.seek(info["hdr_off"] + 16)
            f.write(struct.pack("<I", new_rsize))

            # Update OptionalHeader.SizeOfImage (+56) and clear CheckSum (+64)
            f.seek(info["opt_off"] + 56)
            f.write(struct.pack("<I", new_size_of_image))
            f.seek(info["opt_off"] + 64)
            f.write(struct.pack("<I", 0))
        return True
    except (OSError, ValueError):
        return False
