# Community Build: Try Omarchy Live Desktop Preview

> [!WARNING]
> **Community Build Notice & Testing Disclosure**  
> This is an unofficial, community-compiled bootable ISO built from John Sideserf's [`try-omarchy` branch](https://github.com/johnsideserf/omarchy-iso/tree/try-omarchy) (commit `91ec6f94fdff6d8bd01b23ccd09adbb0fce3ecfd`).  
> **Hardware Testing Status:** The build completed successfully and passed John's full unit test suite (`test/unit/try-*`), but has **not yet been booted on physical bare metal hardware** by the author. Community members are invited to test it on real hardware (x86_64 PCs and T2 Intel MacBooks) and share feedback.

---

## What is "Try Omarchy"?

"Try Omarchy" allows users to boot an Omarchy ISO on their machine and experience the live desktop on their hardware before committing to wiping their disk — the x86 counterpart of the `try-omarchy` Mac app.

- **Ephemeral live desktop session** powered by Hyprland.
- Installed **just-in-time** directly from the ISO's offline bundled mirror (`/var/cache/omarchy/mirror/offline`) into an in-memory overlayfs.
- Does not affect the clean offline install path, and exits directly back to the installer.
- Requires $\ge$ 4 GiB of RAM.

---

## ISO Image Specifications & Verification

- **ISO Filename:** `omarchy-2026.09.09-x86_64.iso`
- **File Size:** `6,260,654,080 bytes` (5.83 GiB)
- **Superblock:** SquashFS 4.0, zstd-19 (`airootfs.sfs`: 5.53 GiB)
- **Kernel:** `linux-t2` (universal x86_64 support + Intel T2 Mac support)
- **SHA-256 Checksum:**
  ```text
  EE781743C4BDDF3257241FC5C5464A7D5E66F557D280F58F59D5BA32D9489C0D
  ```

---

## Verification & Integrity Check

To verify your downloaded image against this release:

```bash
# In Linux / macOS:
sha256sum omarchy-2026.09.09-x86_64.iso

# In Windows (PowerShell):
Get-FileHash .\omarchy-2026.09.09-x86_64.iso -Algorithm SHA256
```

Confirm the output matches `EE781743C4BDDF3257241FC5C5464A7D5E66F557D280F58F59D5BA32D9489C0D`.

---

## Author & License

- **Compiled by:** Aarav Tank ([@aaravtank](https://github.com/aaravtank))
- **Based on work by:** John Sideserf ([@johnsideserf](https://github.com/johnsideserf)) and the Omarchy project contributors.
- **License:** MIT License

```text
Copyright (c) 2026 Aarav Tank

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```
