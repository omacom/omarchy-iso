# Installing from the target disk

On UEFI machines, Omarchy can install on the disk holding the live installer
when it is mounted directly from a GPT partition. It needs at least 32 GiB of
contiguous free space. The installer partition and all EFI system partitions
are protected. If space is insufficient, the partition menu lets you delete
other inactive partitions after confirmation. Full-disk erasure, resizing and
deferred provisioning are unavailable on that disk.

Same-disk installation does not support loopback ISOs or device-mapper sources.
They can install to another disk: a loopback ISO's backing disk and the disk
under a single-disk device-mapper source, such as Ventoy's, are excluded.
Sources that may span several disks, including Btrfs-backed media, are
unsupported. After a copy-to-RAM boot, every disk is available.

BitLocker volumes can stay encrypted for a free-space install on GPT if their
protection is suspended. The ISO verifies this with a read-only clear-key probe;
it does not mount Windows or change its encryption. Failed checks block
installation. On other BitLocker disks, the partition editor is unavailable.

Save your recovery key, then suspend protection in administrator PowerShell:

- Windows OS volume: `Suspend-BitLocker -MountPoint C: -RebootCount 0`
- Affected data volumes: `Suspend-BitLocker -MountPoint D:` (replace `D:` as needed)

Suspended volumes remain encrypted but can be read offline without a key.
After installation, boot Windows through the new menu and run
`Resume-BitLocker -MountPoint C:`; resume affected data volumes too. Also resume
protection if you cancel. The ISO does not do this for you.

The installer and temporary EFI partitions remain on disk. Reclaim them only
after the installed system boots independently.

All interactive free-space installs check partition identities during creation
and cleanup. An uncertain write stops cleanup and reports that inspection is
needed. These checks do not cover `cidata` autoinstall, which skips the wizard.

## Testing

Run `sudo bash test/same-disk-partitioning` on Linux to check mounted-source
preservation during creation, formatting and rollback. It uses disposable
loop-backed images with 512-byte and 4096-byte sectors.

Run `sudo python3 test/bitlocker-suspension /path/to/bitlk-images` with cryptsetup
2.8.6 or newer to test the read-only probe against the upstream cryptsetup
v2.8.6 fixtures (`tests/bitlk-images.tar.xz`). It checks suspended, protected,
partially encrypted and damaged images, without changing their contents.

These tests do not replace a complete installation or a Windows/TPM round trip:
suspend protection, install, boot Windows through the new menu, resume protection,
and boot Windows again. Test cancellation and return to Windows too.
