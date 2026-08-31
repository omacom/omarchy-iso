# Installer Fix Guide: Dual-Boot Free-Space + Full-Disk Installer Issues

## Goal

Close seven installer defects in one pass, covering both install workflows:

- **Dual-boot / free-space install** on a second disk (`[NTFS][free space]`), UEFI:
  - different-disk ESP & root handling,
  - stale LUKS/btrfs signature on reinstall (#3),
  - a full NVRAM that blocks the Limine boot entry (#127).
- **Full-disk install** (`wipe: true`):
  - a stale LUKS header that aborts archinstall's wipe (#137),
  - the `cryptsetup close` "Device root is still in use" race (#130),
  - archinstall scanning a LUKS partition as btrfs and crashing (#115).

Each fix is written so a *fail* degrades to the next mechanism instead of
aborting the install, and none of them changes the standard (non-broken) path.

---

## 1. Dual-boot on a different disk (`[NTFS][free space]`)

### What was wrong

The free-space flow already creates its own FAT32 ESP **and** root partition in
the free space (it never picks the disk's existing Windows ESP or ext4), but the
configurator did not *say* so. Users partitioning a second disk for Linux saw
only the freed gap and assumed Omarchy was meant to hook into the Windows ESP /
filesystem, which led to aborted or mis-targeted installs.

### The change

`configs/airootfs/root/configurator`, `open_partition_tool` (the disk
configuration screen): the on-screen hint now states explicitly that the
installer **always creates its own EFI system partition and root partition** in
the selected free space — it never modifies or reuses a Windows-owned ESP or
root on the other disk.

```text
The installer creates its own EFI System Partition and root partition inside the
free space selected below. It will not touch the Windows EFI partition or any
existing OS filesystem.
```

### Why

The different-disk case (`misaligned_partition_sizes` / the disk with
`[NTFS][free space]`) is gated in `run_partition_decide`/`run_partition_execute`,
which always carve a fresh FAT32 ESP + btrfs root. The failure was informational,
not structural — so the fix is informational too.

---

## 2. Stale btrfs/LUKS signature on reinstalling into free space (#3)

### What was wrong

When a user reinstalls into an existing free-space layout, the leftover
partition carried an old filesystem signature. The code called a single
`wipefs -af "$efi_dev"` / `wipefs -af "$root_partition_device"`. If udev's
auto-scan was still holding a reference (the exact race that #130/#137 describe),
that one-shot `wipefs` failed and **aborted the install** — even though the
device was otherwise perfectly wipeable on retry.

### The change

New `clear_stale_signatures()` in the configurator, replacing the fragile
single-shot wipe in `run_partition_execute`:

```bash
# configs/airootfs/root/configurator (near line 447)
clear_stale_signatures() {
  local dev="$1" i
  for i in 1 2 3; do
    if wipefs -af "$dev" >/dev/null 2>&1; then
      sync
      return 0
    fi
    sleep 1
  done
  return 0   # non-fatal: archinstall/format will wipe over it anyway
}
```

Called on both the ESP and the root partition before formatting
(`configurator:755-756`). The retry absorbs the udev race; returning `0` on
failure means a genuinely busy device cannot turn into a second aborted install.

---

## 3. Full NVRAM blocks the Limine boot entry (#127)

### What was wrong

With a full NVRAM (`efibootmgr` → "No space left on device"), the single
`efibootmgr --create` failed, `check=True` discarded the actual error, and the
install rolled back or aborted — even though a **fallback boot path**
(`\EFI\BOOT\BOOTX64.EFI`, which UEFI firmware tries after NVRAM entries) would
have booted fine.

### The changes

All in `configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py`.

1. `_register_limine_efi_entry` now deletes stale Limine entries first, and
   `_write_entry()` runs `efibootmgr` with `check=False` +
   `capture_output=True, text=True`, capturing the stderr into
   `failure["reason"]` (it used to be thrown away by `check=True`).
2. On the first entry-write failure it calls `_purge_dangling_boot_entries(...)`
   once, then retries. `_purge_dangling_boot_entries` deletes only entries whose
   GPT partition UUID (`_entry_partition_uuid`) is **not** in
   `_live_partition_uuids()` (from `lsblk -nro PARTUUID`) — Windows and live-ISO
   entries are left strictly alone.
3. If the retry also fails, it raises `_NvramWriteError` **including the
   efibootmgr reason** (the NVRAM-full message).
4. `_install_limine_efi` catches `_NvramWriteError`:
   - logs the reason via `info()`,
   - copies the Limine loader to the fallback binary
     `<esp_mount>/EFI/BOOT/BOOTX64.EFI`,
   - rewrites the pacman hook so kernel updates keep the fallback binary in sync,
   - sets `ctx.state["limine"]["boot_entry_failed"] = True` and
     `ctx.state["limine"]["fallback_binary"]`.
5. `_write_pre_mounted_limine_defaults` and `_write_limine_defaults_from_config`
   now force `enable_fallback=True` whenever `boot_entry_failed` is set, so the
   installed Limine config enables the `\EFI\BOOT\BOOTX64.EFI` fallback.
6. `validate_boot` accepts a missing NVRAM entry **only** when
   `boot_entry_failed` is set **and** the fallback binary exists; otherwise it
   still hard-fails.
7. Boot-order filtering in `_register_limine_efi_entry` now checks
   `num in post_state["entries"]` (was `pre_state`), so the freshly-created
   entry is not wrongly treated as a dangling one.

### Control flow

```text
efibootmgr --create
  ├─ success .................... done
  └─ FAIL (captured reason)
       └─ purge dangling entries (skips Windows/live)
            └─ retry --create
                 ├─ success ..... done
                 └─ FAIL ........ raise _NvramWriteError(reason)
                                      └─ install fallback \EFI\BOOT\BOOTX64.EFI
                                         + enable_limine_fallback=yes
                                         + boot_entry_failed=True
```

---

## 4. Full-disk: stale LUKS header aborts archinstall's wipe (#137)

### What was wrong

On a full install over a previous encrypted install, the old LUKS header survived
the holder-release pass. archinstall's first filesystem operation is a
per-partition `wipefs --all`, which fails on the busy LUKS partition and aborts
mid-install. All partitions were created fine — it was purely the wipe that
choked on stale signatures (the manual `wipefs -a /dev/sda` recovery proved it).

### The change

`configs/airootfs/usr/local/bin/omarchy-iso-cleanup-disk` — a new
`clear_signatures()` helper plus a call to it in the whole-disk path. Because the
user has explicitly chosen to **erase this disk**, it is safe (and correct) to
clear signatures here *before* archinstall re-partitions:

```bash
clear_signatures() {
  local dev="$1" i
  for i in 1 2 3; do
    if wipefs -af "$dev" >/dev/null 2>&1; then
      sync; return 0
    fi
    sleep 1
  done
  return 1
}

# partitions first, then the whole disk (clears GPT/PMBR + any gap signatures)
while read -r dev; do
  [[ -b $dev ]] || continue
  clear_signatures "$dev" || true     # busy device must never abort the install
done < <(lsblk -rnpo PATH "$disk" | awk '$1 != ""')
clear_signatures "$disk" || true
```

Placed **after** the holder-release loops (unmount / swapoff / lvm / crypt close)
and before `blockdev --flushbufs`. Wiping partitions first, then the disk, mirrors
the manual recovery that worked and turns archinstall's re-partition into a clean
create. Best-effort (`|| true`) so a busy device still cannot abort.

---

## 5. Full-disk: `cryptsetup close` "Device root is still in use" race (#130)

### What was wrong

Intermittently, `cryptsetup close root` during archinstall's
`perform_filesystem_operations` fails with `Device or resource busy` /
"Device root is still in use" even though `findmnt` shows no mount and "Open
count: 0". It is a race where something briefly holds a reference; it clears
once udev settles and the close is retried.

### The change

`configs/airootfs/usr/share/omarchy-iso/orchestrator/archinstall_adapter.py`,
`perform_filesystem_operations`:

- The existing udev-race retry loop now also recognizes this failure via
  `_is_luks_close_race()`, which matches only the specific busy-message tokens —
  a generic error is still *not* retried (so we never loop on a genuine failure).
- On that match it calls `_close_stray_crypt_mappings()`, which enumerates live
  `crypt` devices (`lsblk -rnpo PATH,TYPE`), runs `cryptsetup close` on each,
  then `udev_sync()` + a short settle, and retries.

```python
elif _is_luks_close_race(exc_str):
    _close_stray_crypt_mappings()
    info(f"› LUKS close lost a device race (attempt {attempt}/{attempts}); retrying")
```

The wipe/partition/format sequence is idempotent (same reason the existing retry
is safe), so a retry after force-closing strays is safe.

---

## 6. Full-disk: archinstall scans LUKS as btrfs and crashes (#115)

### What was wrong

After formatting the LUKS mapper as btrfs, archinstall's `DeviceHandler`
re-scans devices and `get_btrfs_info()` tries to mount the **raw** LUKS
partition as btrfs → "wrong fs type, bad superblock". The btrfs info scan has no
business opening a LUKS container.

### The change

`archinstall_adapter.py`, a scoped, best-effort monkeypatch around the
`perform_filesystem_operations` call:

- `_guard_get_btrfs_info()` locates `DeviceHandler.get_btrfs_info` and wraps it
  so any `crypto_LUKS`/`crypt` device (checked via `_device_is_luks` +
  `lsblk -ndo TYPE`) returns an empty info dict instead of trying to mount it.
  Non-LUKS behavior is untouched.
- The wrap is installed before the operation and restored in a `finally`, so it
  can never leak into later phases or other installs.
- It is intentionally best-effort: if the class/method can't be located (an
  archinstall version/rename change), it returns `None`, disables itself, and the
  install proceeds exactly as before — a patch-guard, never a new crash site.

### Why a monkeypatch

The crashing code lives inside archinstall itself; the adapter is the sanctioned
wall between Omarchy and archinstall. A targeted, try/finally-restored patch is
contained, version-tolerant, and cannot affect the non-encrypted full-disk path
(no LUKS → every device defers to the original).

---

## How each failure degrades safely

| Issue | Failure path | Fallback |
|---|---|---|
| #3  | a busy device won't wipe in 3 tries | return 0; format wipes over it later |
| #127 | NVRAM is truly full | `\EFI\BOOT\BOOTX64.EFI` fallback + enabled Limine fallback |
| #137 | a busy device won't wipe | `\|\| true`; archinstall still proceeds |
| #130 | close race stays stuck | retry after force-closing strays; only this message is retried |
| #115 | can't locate archinstall symbol | patch self-disables, unchanged behavior |

## Files touched

- `configs/airootfs/root/configurator` — #1 messaging, #3 `clear_stale_signatures`
- `configs/airootfs/usr/local/bin/omarchy-iso-cleanup-disk` — #137 `clear_signatures`
- `configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py` — #127 NVRAM/full + fallback
- `configs/airootfs/usr/share/omarchy-iso/orchestrator/archinstall_adapter.py` — #130 close race, #115 btrfs-scan guard
- `test/unit/test_nvram_fallback.py` — #127 unit tests
- `test/unit/cleanup-disk-wipe-test.sh` — #137 wipe unit tests

## Verification

- `python3 test/unit/*.py` — all pass (incl. new `test_nvram_fallback.py`).
- `bash test/unit/*.sh` — all pass (incl. new `cleanup-disk-wipe-test.sh`).
- Manual repro for each issue should now fall back cleanly instead of aborting.
