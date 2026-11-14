#!/usr/bin/env python3
"""Recolor the systemd-boot menu by patching its two entry colors.

systemd-boot has no theme or color settings. Its menu is drawn through the
UEFI text console, so every color is one of the 16 EFI text attributes
(foreground | background << 4), not an RGB value. The entry loop compiles to

    mov  $0x07, %eax        ; COLOR_ENTRY      light gray on black
    ...
    mov  $0x70, %r12d       ; COLOR_HIGHLIGHT  black on light gray
    cmovne %rax, %r12

This finds that sequence in systemd-bootx64.efi (systemd 262 as built by
Arch) and swaps the two attribute bytes. It refuses unless the pattern
matches exactly once. The result must be signed again.

This is for previewing only. A shipped build would carry the same change as a
source patch to COLOR_ENTRY / COLOR_HIGHLIGHT in src/boot/, built and signed
in omarchy-pkgs.

Usage: recolor-sdboot.py IN.efi OUT.efi ENTRY_ATTR HIGHLIGHT_ATTR   (hex, e.g. 08 0a)
"""

import re
import sys

# mov $imm,%eax ; mov (%r15,%r14,8),%rcx ; mov $imm,%r12d ; cmovne %rax,%r12
PATTERN = re.compile(rb"\xb8(.)\x00\x00\x00\x4b\x8b\x0c\xf7\x41\xbc(.)\x00\x00\x00\x4c\x0f\x45\xe0", re.S)


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    src, dst, entry, highlight = sys.argv[1], sys.argv[2], int(sys.argv[3], 16), int(sys.argv[4], 16)
    data = bytearray(open(src, "rb").read())
    matches = list(PATTERN.finditer(data))
    if len(matches) != 1:
        sys.exit(f"expected one menu color sequence, found {len(matches)}; systemd-boot changed")
    m = matches[0]
    if (m.group(1), m.group(2)) != (b"\x07", b"\x70"):
        sys.exit(f"unexpected stock colors {m.group(1).hex()} / {m.group(2).hex()}")
    data[m.start(1)] = entry
    data[m.start(2)] = highlight
    # Strip any existing signature: PE32+ certificate table, data directory 4.
    pe = int.from_bytes(data[0x3C:0x40], "little")
    cert_dir = pe + 24 + 112 + 4 * 8
    data[cert_dir : cert_dir + 8] = bytes(8)
    open(dst, "wb").write(data)
    print(f"patched at file offset {m.start(1):#x}: entry {entry:#04x}, highlight {highlight:#04x}")


if __name__ == "__main__":
    main()
