#!/usr/bin/env python3
"""Assemble a (multi-profile) Unified Kernel Image from the systemd stub.

A stand-in for `ukify build --join-profile=...` that needs nothing beyond the
Python standard library, so the prototype runs on a stock Omarchy install
without systemd-ukify, python-pefile or python-cryptography. Production should
call ukify; the section layout written here is the one ukify writes:

    stub sections | base sections (.osrel .cmdline .uname .splash .initrd .linux)
                  | .profile [.cmdline]    <- profile 0
                  | .profile [.cmdline]    <- profile 1 ...

Per the UKI specification, sections before the first .profile are shared by
every profile, and a section inside a profile overrides the base one.

Usage:
    uki_build.py --stub STUB --out OUT NAME=PATH [NAME=PATH ...]

NAME=PATH pairs are appended in the order given. The output is unsigned; sign
it afterwards (systemd-sbsign, sbsign or pesign).
"""

import argparse
import struct
import sys

IMAGE_SCN_CNT_INITIALIZED_DATA = 0x00000040
IMAGE_SCN_MEM_READ = 0x40000000
SECTION_HEADER_SIZE = 40


def align(value, alignment):
    return (value + alignment - 1) // alignment * alignment


def build(stub_path, out_path, sections):
    image = bytearray(open(stub_path, "rb").read())

    pe = struct.unpack_from("<I", image, 0x3C)[0]
    if image[pe : pe + 4] != b"PE\0\0":
        sys.exit(f"{stub_path}: not a PE image")
    coff = pe + 4
    n_sections = struct.unpack_from("<H", image, coff + 2)[0]
    opt_size = struct.unpack_from("<H", image, coff + 16)[0]
    opt = coff + 20
    if struct.unpack_from("<H", image, opt)[0] != 0x20B:
        sys.exit(f"{stub_path}: expected a PE32+ stub")

    section_alignment, file_alignment = struct.unpack_from("<II", image, opt + 32)
    size_of_headers = struct.unpack_from("<I", image, opt + 60)[0]
    # PE32+ data directory 4 is the certificate table; a signed stub would
    # have its signature invalidated (and misplaced) by appending sections.
    cert_dir = opt + 112 + 4 * 8
    if struct.unpack_from("<II", image, cert_dir) != (0, 0):
        sys.exit(f"{stub_path}: stub is already signed; use the unsigned stub")

    table = opt + opt_size
    if table + SECTION_HEADER_SIZE * (n_sections + len(sections)) > size_of_headers:
        sys.exit("not enough room in the stub's section table")

    last_va_end = 0
    for i in range(n_sections):
        vsize, va = struct.unpack_from("<II", image, table + i * SECTION_HEADER_SIZE + 8)
        last_va_end = max(last_va_end, va + vsize)

    size_of_init_data = struct.unpack_from("<I", image, opt + 8)[0]
    for name, path in sections:
        data = open(path, "rb").read()
        encoded = name.encode()
        if len(encoded) > 8:
            sys.exit(f"section name too long: {name}")
        va = align(last_va_end, section_alignment)
        raw_ptr = align(len(image), file_alignment)
        raw_size = align(len(data), file_alignment)
        image.extend(b"\0" * (raw_ptr - len(image)))
        image.extend(data)
        image.extend(b"\0" * (raw_size - len(data)))

        header = struct.pack(
            "<8sIIIIIIHHI",
            encoded.ljust(8, b"\0"),
            len(data),  # VirtualSize
            va,
            raw_size,
            raw_ptr,
            0, 0, 0, 0,
            IMAGE_SCN_CNT_INITIALIZED_DATA | IMAGE_SCN_MEM_READ,
        )
        image[table + n_sections * SECTION_HEADER_SIZE : table + (n_sections + 1) * SECTION_HEADER_SIZE] = header
        n_sections += 1
        last_va_end = va + len(data)
        size_of_init_data += raw_size

    struct.pack_into("<H", image, coff + 2, n_sections)
    struct.pack_into("<I", image, opt + 8, size_of_init_data)
    struct.pack_into("<I", image, opt + 56, align(last_va_end, section_alignment))  # SizeOfImage
    struct.pack_into("<I", image, opt + 64, 0)  # CheckSum; the signer recomputes it

    with open(out_path, "wb") as f:
        f.write(image)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stub", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("sections", nargs="+", metavar="NAME=PATH")
    args = parser.parse_args()

    sections = []
    for spec in args.sections:
        name, sep, path = spec.partition("=")
        if not sep or not name.startswith("."):
            sys.exit(f"bad section spec: {spec}")
        sections.append((name, path))
    build(args.stub, args.out, sections)


if __name__ == "__main__":
    main()
