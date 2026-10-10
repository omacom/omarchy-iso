# Japanese profile

`--locale ja` adds Mozc, the Fcitx configuration tool, and CJK fonts. It selects `ja_JP.UTF-8` for the installation user while keeping the physical keyboard selected in the installer. Ctrl+Space switches input methods.

Add `--with-dictation` to configure local Japanese Whisper recognition and paste output. The default runtime supplies F9 hold-to-dictate and Super+Ctrl+X toggle bindings.

## Download a review image

- [Omarchy 4.0.4 Japanese ISO (7.01 GB)](https://storage.googleapis.com/komagata-omarchy-iso/4.0.4-jp.3/omarchy-4.0.4.jp.iso)
- [SHA-256 checksum](https://storage.googleapis.com/komagata-omarchy-iso/4.0.4-jp.3/omarchy-4.0.4.jp.iso.sha256)
- [Build provenance and verification](https://storage.googleapis.com/komagata-omarchy-iso/4.0.4-jp.3/build-provenance.md)

This unofficial review image is built from implementation commit `650c861a3df7a103067a1d3697fa8dac4515c5d2` with `--locale ja --with-dictation`, using the latest official stable Omarchy release at build time, 4.0.4. It does not bundle a third-party input-method bar plugin. It includes the fix that reads the installer's `XKBLAYOUT` from `/etc/vconsole.conf`.

The build uses the normal stable package configuration. A build-only supplemental repository restores the exact `apple-bcm-firmware` archive from the official 4.0.4 ISO because the configured mirror no longer indexes it. Four other package versions advance through normal repository resolution; see the provenance for exact versions.

SHA-256: `5ab18990efe0526417b58b6762dda0b67d1037db6c95d1d6a586f25a5406bb45`.

On September 19, 2026, this image passed a fresh QEMU/KVM UEFI installation with a German physical keyboard layout. The installer, Fcitx, and Hyprland retained `de`, and the physical Y key produced `z`. Actual Mozc conversion, local CPU Whisper-to-paste, and installation-user-only locale checks passed. Disk-only cold boot and a normal reboot succeeded; after login, the settings and active services were retained.

The previous image's intermittent early VM boot stall did not reproduce in these checks; this keyboard fix does not establish its cause or resolve it. Physical hardware has not been tested.
