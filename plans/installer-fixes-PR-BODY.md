# Installer fixes: dual-boot free-space + full-disk installers

Closes #3, #115, #127, #130, #137.

Seven installer defects across both install workflows, each fixed so a failure
*degrades* to the next mechanism instead of aborting the install, and none
changes the standard (non-broken) path.

## Dual-boot free-space (`[NTFS][free space]`)

- **Different-disk messaging.** The free-space flow already creates its own FAT32
  ESP + root in the selected gap (it never touches Windows' ESP/ext4). The disk
  configurator now says so on-screen, removing the mis-targeting that aborted
  installs on a second disk.
- **Stale btrfs/LUKS signature on reinstall (#3).** A single one-shot
  `wipefs -af` raced udev and aborted the reinstall. New retried,
  error-tolerant `clear_stale_signatures()` (up to 3×, returns 0 on failure)
  replaces it in `run_partition_execute`.
- **Full NVRAM blocks the Limine entry (#127).** `efibootmgr --create` failure
  used to discard the real error and either roll back or abort. Now the reason is
  captured, dangling entries are purged (Windows/live untouched), the create is
  retried once, and on final failure Omarchy installs the
  `\EFI\BOOT\BOOTX64.EFI` fallback, enables Limine's fallback, keeps the pacman
  hook in sync, and `validate_boot` accepts the missing entry only when the
  fallback exists.

## Full-disk

- **Stale LUKS header aborts archinstall's wipe (#137).**
  `omarchy-iso-cleanup-disk` now wipes partition + disk signatures itself
  (retried, best-effort) after releasing holders, so archinstall's fragile
  per-partition wipe is replaced by a clean create.
- **`cryptsetup close` "Device root is still in use" race (#130).** The adapter's
  existing udev-race retry now also recognizes the busy-device close message,
  force-closes stray `crypt` mappings, and retries — scoped to that exact message
  so genuine failures are still not looped.
- **archinstall scans a LUKS partition as btrfs and crashes (#115).**
  `get_btrfs_info()` is wrapped (try/finally-restored) to skip `crypto_LUKS`
  devices during the partitioning operation, suppressing the bogus
  "wrong fs type, bad superblock" mount. If the archinstall symbol can't be
  found the patch self-disables and behaves as before.

## Tests

- `test/unit/test_nvram_fallback.py` — #127 (uuid parsing, dangling-vs-live
  reclaim, `_NvramWriteError` with "No space left on device").
- `test/unit/cleanup-disk-wipe-test.sh` — #137 (stale signature wiped on image,
  clean no-op, busy device tolerated by the call site).

All Python and shell unit tests pass.

## Notes for reviewers

- The #115 monkeypatch is deliberately version-tolerant and scope-limited to the
  partitioning operation (restored in `finally`). Open to alternatives if you'd
  rather pin a specific archinstall version.
- #137/#3 wiping is deliberately best-effort: a busy device must never trade
  archinstall's old abort for a new one.
