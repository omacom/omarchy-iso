#!/usr/bin/env python3

"""Make Archinstall's Limine path use the AArch64 UEFI fallback binary."""

from pathlib import Path
import sys


REPLACEMENTS = (
    (
        "for file in ('BOOTIA32.EFI', 'BOOTX64.EFI'):",
        "for file in ('BOOTAA64.EFI',):",
    ),
    (
        "f'/usr/bin/cp /usr/share/limine/BOOTIA32.EFI {efi_dir_path_target}/ && "
        "/usr/bin/cp /usr/share/limine/BOOTX64.EFI {efi_dir_path_target}/'",
        "f'/usr/bin/cp /usr/share/limine/BOOTAA64.EFI {efi_dir_path_target}/'",
    ),
    ("\\\\EFI\\\\arch-limine\\\\BOOTX64.EFI", "\\\\EFI\\\\arch-limine\\\\BOOTAA64.EFI"),
    ("\\\\EFI\\\\arch-limine\\\\BOOTIA32.EFI", "\\\\EFI\\\\arch-limine\\\\BOOTAA64.EFI"),
)


def patch_installer(path: Path) -> None:
    source = path.read_text()
    for old, new in REPLACEMENTS:
        count = source.count(old)
        if count != 1:
            raise RuntimeError(
                f"unsupported archinstall Limine source: expected one occurrence of {old!r}, found {count}"
            )
        source = source.replace(old, new)

    if "BOOTX64.EFI" in source or "BOOTIA32.EFI" in source:
        raise RuntimeError("unsupported archinstall Limine source: unpatched x86 EFI fallback remains")
    path.write_text(source)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} INSTALLER.PY")
    patch_installer(Path(sys.argv[1]))
