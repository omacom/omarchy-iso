# LVM install mode

Install Omarchy into logical volumes that already exist, on a machine whose disk is already an LVM physical volume. The target case is a multi-boot workstation: one volume group holds the current distribution's root, a large shared `/home`, and swap; the owner has carved out a spare logical volume for Omarchy and wants Omarchy in it without touching anything else in the group.

Today that install is impossible. `disk_form` offers whole disks only, and both install modes write a GPT partition table. A disk fully consumed by a PV reports no free space, so `requires_full_disk_install` forces the full-disk path, whose first act is to overwrite the volume group.

## What already exists

The installer is closer to this than it looks. The free-space mode is already non-destructive to its neighbours and already hands archinstall a pre-mounted target:

- `run_partition_execute` (configurator) creates, formats and mounts everything under `/mnt` itself, then writes `"config_type": "pre_mounted_config"` with `"mode": "protected"`.
- `archinstall_adapter.py` honours that: `Pre_mount` skips `mount_ordered_layout`, because the mounts are already standing.
- `_write_pre_mounted_fstab` and `_write_pre_mounted_crypttab` (phases_impl) write the target's fstab and crypttab from an explicit `omarchy_install.storage` intent rather than from a scan.
- `create_factory_snapshot` already degrades gracefully when the root is not btrfs.

So LVM mode is a third producer of the same pre-mounted handoff. Everything downstream — Limine, the UKI build, `omarchy-apply-system` — is unchanged and untested-against only in the sense that it never sees a device-mapper path today.

## Design

### Root stays btrfs

The chosen root LV is formatted `btrfs` and given the same `@`, `@log`, `@pkg` subvolumes as every other Omarchy install. This is the single most important scoping decision in this plan.

Reusing whatever filesystem the LV already holds would sound friendlier, but it would cost snapper, the Limine snapshot menu and `omarchy-system-factory-reset`, and it would force `_write_pre_mounted_fstab` and `_validate_pre_mounted_filesystems` to be rewritten around an arbitrary filesystem. Formatting the root LV keeps both functions nearly as they are, keeps every Omarchy feature, and matches what the owner expects: they nominated a *spare* volume.

`@home` is the exception, and it is the whole point of the mode — see below.

### Reuse, never format, everything else

Only the root LV is formatted. Every other volume the owner nominates is mounted as it stands:

| Role       | Source                     | Formatted |
| ---------- | -------------------------- | --------- |
| `/`        | chosen LV                  | yes, btrfs `@` |
| `/home`    | chosen LV, or root `@home` | never     |
| swap       | chosen LV, optional        | never     |
| ESP        | existing partition         | never     |

When the owner nominates an existing `/home` volume, the `@home` subvolume is not created and its fstab line is replaced by one naming the chosen volume. When they do not, the mode behaves exactly like the free-space path.

The ESP is the sharpest edge. The free-space path always creates its own ESP and deliberately refuses to adopt the Windows one; that reasoning is about Windows reclaiming the partition, and does not carry over to an ESP that a sibling Linux owns. Limine installs under `/EFI/limine` with its own `efibootmgr` entry, so it coexists with `systemd-boot` under `/EFI/systemd` rather than displacing it. The mode therefore adopts an existing ESP and never runs `mkfs.fat` on it. **This needs verifying against limine's installer before the PR is opened** — it is the one step that can cost the owner their working system.

Measured afterwards on a completed encrypted install: the UKI is 43MB and
Omarchy's whole footprint on the adopted ESP is about 46MB. A 512MB ESP sized
for a bootloader rather than for kernel images is therefore not the constraint
it appears to be; the 2GB figure elsewhere is what the free-space mode
*creates*, not what an install needs.

### The initramfs needs the lvm2 hook

Without it the target cannot find its own root. Two parts:

- `lvm2` joins the package list for this mode.
- A drop-in adds the `lvm2` hook to `HOOKS`, before `encrypt` (LUKS-on-LV) and before `filesystems`.

The drop-in's **name is load-bearing**. `omarchy-settings` ships `/etc/mkinitcpio.conf.d/omarchy_hooks.conf`, which *assigns* `HOOKS=(...)` outright. mkinitcpio sources drop-ins in lexical order, so a `99-` prefix — the convention the provisioning-key drop-in uses — is sourced *before* `omarchy_hooks.conf` and silently discarded. That drop-in survives only because it uses `FILES+=`. The LVM drop-in must sort after, hence `zz-omarchy-lvm.conf`.

### Encryption

LUKS on the root LV is supported and is the default, matching every other mode. The `cryptsetup luksFormat` call is identical to the free-space path's; only the device differs. Hook order becomes `... block lvm2 encrypt filesystems ...`, since the PV is not itself encrypted and the volume group must be assembled before the mapper device exists.

An already-encrypted PV (LUKS containing the VG) is out of scope. The installer would have to unlock a container it did not create, and the owner is better served booting the existing system and running the install from there.

## Changes

### `configs/airootfs/usr/share/omarchy-iso/lvm.sh` (new)

Pure discovery helpers, sourced by the configurator and by the unit tests, mirroring how `disk-partitioning.sh` is structured. No side effects, so they are testable without a disk:

- `disk_has_lvm <disk>` — does this disk carry a PV with a volume group
- `volume_groups_on_disk <disk>`
- `logical_volumes <vg>` — name, size, current filesystem, current label
- `device_is_busy <device>` — the guard that keeps the running system's own root off the candidate list. Takes any block device, not only a logical volume: the ESP is checked through it too
- `describe_lv <lv>` — the display string for the picker

### `configs/airootfs/root/configurator`

- `install_mode_form` gains "Use existing LVM volumes" when `disk_has_lvm "$disk"`.
- `run_lvm_decide` — pick the VG, then root / `/home` / swap / ESP; refuse any device that is currently mounted or that backs the live system; refuse an adopted `/home` or swap volume that carries no filesystem, since this mode mounts them rather than creating them; confirm; set the same globals `run_lvm_execute` reads. Every one of those refusals happens here, before `run_lvm_execute` formats anything — a check deferred to mount time fires after the root volume is already erased.
- `run_lvm_execute` — format and mount root, mount the rest, emit `user_configuration.json` with `mode: protected`, `config_type: pre_mounted_config`, and a `storage` block carrying `home_device` and `swap_device`.
- `select_installation` and the `install_target` dispatch gain the `lvm` branch.

### `configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py`

- `_write_pre_mounted_fstab` — emit the `/home` line from `storage.home_device` when set, otherwise the `@home` subvolume line as today; append a swap line when `storage.swap_device` is set.
- `_validate_pre_mounted_filesystems` — assert the `/home` and swap UUIDs when those devices are set.
- A `_write_lvm_mkinitcpio_dropin` step writing `zz-omarchy-lvm.conf`.

### `test/unit/lvm-discovery-test.sh` (new)

The discovery helpers against fixture output, following `partition-numbering-test.sh`. The mount guard is the case that matters: nominating a volume the live system is using must be refused, not merely warned about.

## Open questions for review

1. **ESP adoption.** Verified assumption pending: that `limine-install` writes only `/EFI/limine` and its own NVRAM entry, leaving a sibling bootloader's directory and entries intact.
2. **Volumes outside the group.** Should the mode allow a `/home` on a plain partition, or only on an LV in the same VG? Only-in-VG is simpler to explain and to validate.
3. **`swap: true`** in the emitted config. With a real swap volume the archinstall-level swap flag likely wants to be `false`, but its exact effect on a pre-mounted target is unconfirmed. This is an open question shipped inside the code rather than beside it, and it should be settled before the PR is opened.

## Adversarial review

Two rounds, each by a reviewer with no access to the author's reasoning, bound to `2673c61...HEAD`.

### Round 2

- **The in-use check was inert in the actual deployment scenario.** Booted from the ISO, nothing on the target disk is mounted, so `device_is_busy` proved only "not in use by the installer" — the sibling's root volume was offered as a format target on exactly the same footing as the spare. The guard closed the generator's "in use by" half and left "needed by a system the owner intends to keep" wide open. A volume that already carries a filesystem now takes a separate confirmation naming that filesystem and its label.
- **The check could not see a device-mapper stack.** An LV holding an unlocked LUKS container is not itself mounted — its child mapping is, under a different dm node — so `findmnt` never named the LV and `mkfs` would have run underneath a live filesystem. `device_and_holders` now walks `holders/` transitively.
- **The adopted-`/home` refusal tested "the type is not empty",** which `crypto_LUKS` and `LVM2_member` both pass. Both name a container, not a filesystem, so the mount failed in `run_lvm_execute` — after the root volume was already erased. Replaced with an allow-list of mountable filesystems.
- **`vgchange -ay` ran through `disk_step`,** which aborts through `disk_abort_hook` and exits, contradicting `run_lvm_decide`'s documented contract of returning 1 to the install-mode picker. A group that will not activate is a reason to choose another, not to end the installer.

Resolved by reading source, not by inference:

- **`useradd -m` does not touch an existing home.** shadow's `create_home()` returns immediately when the directory already exists (`useradd.c`, `access(prefix_user_home, F_OK) == 0`), before any `mkdir`, `chown` or skel copy. Adopting a populated `/home` therefore cannot rewrite ownership — round 2's hunch is disproven. Two real consequences remain, neither destructive: the target's `/etc/skel` is **not** seeded into an adopted home, so Omarchy's shipped dotfiles arrive only via `omarchy-reinstall-configs`; and `useradd` allocates the next free UID in the fresh target, so a sibling whose user is not UID 1000 ends up with files owned by a UID the new system does not know. Both are recoverable; both should be said out loud in the mode's confirm screen.
- **`swap: true` is not a disk operation.** archinstall 4.4's `setup_swap` configures zram only — it pacstraps `zram-generator` and writes `/etc/systemd/zram-generator.conf`, and never writes to a block device. `phases_impl` already strips that file afterwards. So the emitted flag is a preference, not a hazard: `false` when a swap volume is adopted, `true` for zram when none is, which is what the mode emits. Round 1's open question is closed.

Still open from round 2, not fixed:

- **The encrypted default mounts the adopted ESP at `/boot`,** where the kernel package writes `vmlinuz-linux` and its initramfs to the ESP root. An Arch-family sibling whose own boot entry points at those same paths would boot Omarchy's kernel instead. The author's ESP assumption covers only what `limine-install` writes; pacman's kernel files are outside it. Unencrypted installs mount at `/efi` and do not have this. Needs settling with the ESP question above.
- **No runtime check that the sibling's NVRAM entry survived.** `_install_pre_mounted_limine` already verifies a *Windows* entry survives and has no equivalent for the sibling Linux entry this mode exists to protect.

### Round 1

Reviewed against `2673c61...HEAD` by a reviewer with no access to the author's reasoning. Findings acted on:

- **The ESP was the one runtime-chosen device with no in-use check.** Every logical volume went through `choose_lv`, which refuses a busy selection; the ESP picker did not. This was the site missing from the mode's own stated invariant.
- **An adopted `/home` or swap volume with no filesystem was accepted**, and failed at mount time — which is after `run_lvm_execute` has already formatted the root volume. Both are now refused during the decide half.
- **`_lvm_on_disk` matched by bare prefix.** `/dev/nvme0n10p1`, and the whole disk `/dev/nvme0n10`, both matched disk `/dev/nvme0n1`, so the mode could offer to install into a volume group living on a different disk. The original test covered `sdaa1` against `sda`, which does not catch it.

Checked and found closed, recorded so the next reader does not re-derive them:

- `builder/build-iso.sh:66` copies `configs/` wholesale, so `lvm.sh` reaches the ISO. The merge gate builds the ISO and never runs `./test/all`, so this needed confirming separately.
- `builder/build-iso.sh:121` already installs `lvm2` in the live environment, so `pvs`, `lvs` and `vgchange` exist when the configurator calls them. Without it the mode would never appear, silently.

## Testing status

The mode has been installed end to end in QEMU against the fixture disk and
audited afterwards, three times, each exiting 0 with every marker intact:

| Run | What it exercises that the others do not |
| --- | --- |
| unencrypted | the ESP adopted at `/efi` |
| encrypted | LUKS on the logical volume, the ESP adopted at `/boot`, and `lvm2` ahead of `encrypt` in the hook order |
| `--nvme` | nvme device naming, so the disk matcher takes its `p`-separator branch in a real install rather than only in unit tests |

The NVMe run matters more than it sounds: device naming is logic, not
cosmetics, and every earlier run presented the disk as virtio-blk — the one
shape no target machine uses. It booted from
LVM — the guest's serial console shows the initramfs assembled the volume group
and the adopted swap volume in use by the running system — and the generated
fstab mounts `/home` from the adopted ext4 volume with no `@home` subvolume
line, while the sibling root's UUID appears nowhere in it.

Four layers now exist, and they are not equally strong:

1. **Unit tests**, 77 checks under `./test/all`. Three guards are
   mutation-verified: the device-alias canonicalization, the transitive
   `holders/` walk, and the partition-suffix anchoring each fail their test when
   the guard is removed.
2. **Two adversarial review rounds**, each by a reviewer with no access to the
   author's reasoning. 13 findings.
3. **The fixture disk and its damage oracle**, `test/lvm-fixture-disk`, proven
   in both directions before being trusted — see the table above.
4. **The end-to-end install**, `omarchy-iso-test --lvm`.

### What the first three layers missed

Recorded because it calibrates how much the green numbers are worth.

`lvm2` was listed in the `packages` array of the emitted
`user_configuration.json`, which nothing reads: the orchestrator builds its
package set from its own constants. The target came up without `lvm2`,
mkinitcpio could not resolve the `lvm2` hook, and the install died in its last
phase reporting a missing UKI — a symptom naming a kernel image and saying
nothing about LVM.

All 77 unit tests passed throughout, because they covered the fstab and the
drop-in and never the package set. Both adversarial rounds read the diff and saw
a plausible config key. Only running a real install found it.

The lesson for whoever extends this mode: the unit tests cover the pure helpers
and the generated text, and they cannot see whether the install works. Changes
to what the target installs, mounts or boots need layer 4.

### The sibling is booted, not just inspected

Reading the sibling's bootloader back byte-identical says the install did not
corrupt it. It does not say firmware can still reach and execute it once limine
sits beside it on the same ESP — a different claim, and the one that decides
whether the owner keeps their other system.

So the fixture carries a real `systemd-bootx64.efi` at the vendor path and at
the UEFI fallback path, with a loader entry titled SiblingOS, and the harness
reboots the installed disk with pristine firmware variables. No NVRAM entry
matches, so firmware falls back to `EFI/BOOT/BOOTX64.EFI`. After a completed
install that yields:

```
Sibling0S
Reboot Into Firmware Interface
Boot in 26s.
```

systemd-boot executed from the fallback path, read the sibling's `loader.conf`
— the countdown is the fixture's own `timeout 30` — and listed the sibling's
entry. Binaries are checked by sha256 rather than content, and the check
degrades to a string stand-in on a host without systemd-boot.

Validating the check against the fixture before trusting it caught two defects a
reasoned version would have shipped: systemd-boot drops an entry naming no
kernel, so a title-only file leaves an empty menu and the check fails against a
healthy install; and OCR reads the capital O of "OS" as a zero, so the obvious
matcher times out on a passing system. Neither was visible without running it.

### Still unproven

- **That the sibling's NVRAM entry survived.** No runtime check exists;
  `_install_pre_mounted_limine` verifies a *Windows* entry survives and has no
  equivalent for the sibling Linux entry this mode exists to protect. The boot
  check below deliberately sidesteps NVRAM by using the fallback path, so it
  proves the sibling is still bootable, not that its boot *entry* is still
  listed. QEMU's OVMF variables are also not a real firmware's NVRAM.
- **Multiple volume groups** on one disk, and a group spanning several disks.
  The picker handles both by construction and neither has been exercised.
- **SSH bootstrap timed out** in all three runs, while console login, the
  bootstrap command and a clean shutdown succeeded every time. Consistent across
  unencrypted, encrypted and NVMe, which points at the harness rather than this
  mode. Unexplained; it does not affect the audit.
