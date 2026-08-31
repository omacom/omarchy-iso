# Omarchy ISO — Changes from the original project

This document records every change implemented on top of the original Omarchy ISO
project, focused on turning the ISO's default boot into a full **live Omarchy
desktop** (Hyprland + Quickshell for a dedicated `live` user) while preserving the
classic TTY installer path, and on fixing the live-environment gaps the rebuilt ISO
surfaced.

All paths are relative to the repo root. The final build artifact is
`release/omarchy-2026.08.29-quattro.iso` (6.5 GB, valid bootable hybrid ISO).

---

## 1. Overview of the change set

| Area | File(s) | What changed |
|------|---------|--------------|
| Live desktop bootstrap | `configs/airootfs/usr/local/bin/omarchy-live-desktop` (new) | Brings up the desktop; user/password, theme provisioning, Install entry |
| Live boot unit | `configs/airootfs/usr/lib/systemd/system/omarchy-live-boot.service` (new) | Runs the bootstrap on `omarchy.live` boot |
| Live installer launch | `configs/airootfs/usr/local/bin/omarchy-live-install` (new) | Launches the installer wizard from the desktop |
| Live installer wizard | `configs/airootfs/usr/local/bin/omarchy-live-install-wizard` (new) | Desktop-side copy of the TTY install flow |
| Boot menu (GRUB + syslinux) | `configs/grub/grub.cfg`, `configs/syslinux/archiso_sys*.cfg` | Live desktop = default + `nomodeset` fallback + kept TTY entry |
| Live packages | `builder/build-iso.sh` | Added the missing live apps to `arch_packages` |
| File permissions | `configs/profiledef.sh` | New live scripts pinned to 0755 |
| TTY gate | `configs/airootfs/root/.automated_script.sh` | Exits early on `omarchy.live` so the desktop owns tty1 |
| Initramfs fix | `configs/airootfs/root/customize_airootfs.sh` | Removes the Limine hook/wrapper that blocked the live initramfs |
| Installer fix | `configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py` | Calls `omarchy-iso-cleanup-disk` by absolute path |
| Acceptance harness | `bin/omarchy-iso-test`, `test/integration.d/base-test.sh` | Selects the TTY installer entry from the new boot menu |
| Docs | `README.md` | Documented the live desktop + install entries |

---

## 2. Live desktop bootstrap — `omarchy-live-desktop` (new file)

Path: `configs/airootfs/usr/local/bin/omarchy-live-desktop`

A bash script run by `omarchy-live-boot.service` on boot. Gated on
`omarchy.live` on the kernel cmdline (`grep -qw omarchy.live /proc/cmdline || exit 0`),
so it is completely inert on the classic TTY install boot. It performs, in order:

1. **Create the `live` user** from `/etc/skel` if absent
   (`useradd --create-home --user-group --shell /bin/bash live`) so the desktop
   session carries the same Omarchy config as an installed user.
2. **Set the password** to `omarchy` idempotently on every boot
   (`echo "live:omarchy" | chpasswd`) so the account can never be password-less
   and SDDM/polkit prompts have a working answer.
3. **Re-stage `/etc/skel`** into the live user's home and fix ownership
   (`cp -aT /etc/skel/ "$HOMEDIR"`, `chown`, `chmod 700`).
4. **Provision the live theme headlessly** as the `live` user:
   - `OMARCHY_THEME_HEADLESS=1 omarchy-theme-set "Tokyo Night"` when no theme is
     active yet (`~/.local/state/omarchy/current/theme.name` absent).
   - `OMARCHY_THEME_HEADLESS=1 omarchy-theme-set-pi --activate` always.
   This is what materializes `~/.local/state/omarchy/current/theme/` — the foot.ini
   include target, colors.toml etc. — and sets the `current/background` link that
   `omarchy-shell`'s `Background.qml` renders as the desktop wallpaper. It is the
   headless equivalent of `install/user/theme.sh`; the network-heavy `mise` dev-tool
   steps of the full provisioning are deliberately skipped.
5. **Register the Omarchy Wayland session** for SDDM by copying
   `/usr/share/omarchy/default/wayland-sessions/omarchy.desktop` to
   `/usr/share/wayland-sessions/omarchy.desktop` (provisioning normally defers this
   to first boot on an installed system).
6. **Configure SDDM autologin** into the live session via
   `/etc/sddm.conf.d/20-live-autologin.conf` (`User=live`, `Session=omarchy.desktop`).
7. **Add an "Install Omarchy" desktop entry** so it appears in the omarchy apps
   provider (which lists DesktopEntries) and the launcher grid:
   - `/usr/share/applications/omarchy-install.desktop` (Exec `pkexec omarchy-live-install`).
   - A root-level `install-omarchy` entry in
     `~/.config/omarchy/extensions/omarchy-menu.jsonc` for the command-menu extension.
8. **Refresh the desktop-file index** with `update-desktop-database
   /usr/share/applications` — deliberately **not** `omarchy-refresh-applications`,
   which would also trigger the heavy mise/dev-tool installer.
9. **Start the display manager**: symlink `display-manager.service` -> `sddm.service`
   (if not already) and `systemctl restart display-manager.service`.

Notes on the code/design:
- The password (`omarchy`) and the headless theme provisioning are idempotent;
  running the bootstrap on every boot cannot damage a later install.
- The script is documented with the reasoning for each choice (why theme
  provisioning is re-run, why mise is skipped, why `update-desktop-database` is used
  instead of the refresh helper).

---

## 3. Boot unit — `omarchy-live-boot.service` (new file)

Path: `configs/airootfs/usr/lib/systemd/system/omarchy-live-boot.service`

A `Type=oneshot` unit that runs `/usr/local/bin/omarchy-live-desktop`:

```ini
[Unit]
Description=Omarchy live desktop bootstrap
After=systemd-user-sessions.service dbus.service
Wants=dbus.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/omarchy-live-desktop
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
```

- `After=systemd-user-sessions.service dbus.service` ensures the session/user
  manager and D-Bus are up so SDDM can bring up the user session.
- `WantedBy=multi-user.target` starts it on the graphical boot.
- It is effectively no-op unless `omarchy.live` is on the kernel cmdline (the
  script self-gates).

---

## 4. Live installer launcher — `omarchy-live-install` (new file)

Path: `configs/airootfs/usr/local/bin/omarchy-live-install`

Entry point for the "Install Omarchy" launcher row. Run as root via
`pkexec omarchy-live-install`. Because `pkexec` strips the environment, it recovers
the live user's Wayland session environment:
- Scans processes owned by `live` for one carrying `WAYLAND_DISPLAY` and
  `XDG_RUNTIME_DIR` (`pgrep -u live`, reading `/proc/<pid>/environ`).
- Then `exec`s `foot` (the live terminal) running
  `/usr/local/bin/omarchy-live-install-wizard` with that environment, so the
  installer wizard opens in a graphical terminal on the desktop.

---

## 5. Live installer wizard — `omarchy-live-install-wizard` (new file)

Path: `configs/airootfs/usr/local/bin/omarchy-live-install-wizard`

The desktop-side equivalent of `/root/.automated_script.sh` (which owns the TTY
install path). It:
- Exports the same env the TTY path uses (`OMARCHY_MIRROR`, `OMARCHY_ISO_REF`,
  `OMARCHY_RUNTIME_PACKAGE`/`SETTINGS`/`NVIM`, `OMARCHY_PATH`, `OMARCHY_INSTALL`,
  `OMARCHY_INSTALL_LOG_FILE`, `OMARCHY_INSTALL_DEBUG`).
- Runs the configurator (`./configurator`) unless a `cidata` autoinstall config is
  present (`/usr/local/bin/omarchy-cidata-load`).
- Detects deferred-provisioning installs and sets `OMARCHY_UI_DEFER_PROVISIONING=yes`.
- Hands off to the same install dashboard + orchestrator
  (`omarchy-install-dashboard ... omarchy-iso-install ...`) with identical args to
  the TTY flow, writing to `/run/omarchy-install/state.json`.

---

## 6. Boot menu (GRUB + syslinux)

### `configs/grub/grub.cfg`
- The default entry is now the **live desktop**
  (`set default=omarchy-live`, `usb timeout=15`).
- The live desktop entry: `omarchy.live` on the kernel line, boots
  `vmlinuz-linux-t2` + `initramfs-linux-t2.img`.
- **New** `omarchy-live-nomodeset` entry (`nomodeset` added to the kernel line) as a
  fallback for GPUs that misbehave with kernel modesetting.
- The classic **TTY installer** entry (`omarchy.install`) is retained so headless /
  automated installs (the acceptance harness) still work.
- The accessibility / memtest / UEFI shell entries are unchanged.

### `configs/syslinux/archiso_sys.cfg` / `archiso_sys-linux.cfg`
- `arch64` (default) boots the live desktop (`omarchy.live`).
- **New** `arch64-nomodeset` label mirrors the grub fallback (`nomodeset omarchy.live`).
- `arch64-install` TTY entry retained (`omarchy.install`).
- `archiso_sys.cfg` default/labels wired to include the updated `archiso_sys-linux.cfg`.

---

## 7. Live packages — `builder/build-iso.sh`

The `arch_packages` array (packages installed into the **live ISO environment**,
not the target) gained the apps a stock Omarchy install ships, so the "try Omarchy"
session has the same desktop apps:

```
xdg-terminal-exec nautilus nautilus-python chromium fastfetch gnome-disk-utility
```

Final `arch_packages`:

```text
linux-t2 git gum jq openssl plymouth ttfx tzupdate omarchy-keyring
"$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted
polkit foot
xdg-terminal-exec nautilus nautilus-python chromium fastfetch gnome-disk-utility
```

Rationale (from the script's comment block): `foot` is the on-desktop installer
terminal; the remaining entries mirror `omarchy-base.packages` so a live session has
the file manager, default browser, system-info row and disk tool. Also note the
existing removal of stock `linux`/`broadcom-wl` from `packages.x86_64` (only
`linux-t2` is booted) is retained.

---

## 8. File permissions — `configs/profiledef.sh`

Added 0755 entries for the new live scripts so they land executable in the ISO:

```bash
["/usr/local/bin/omarchy-live-desktop"]="0:0:755"
["/usr/local/bin/omarchy-live-install"]="0:0:755"
["/usr/local/bin/omarchy-live-install-wizard"]="0:0:755"
```

`omarchy-iso-cleanup-disk` (already `0:0:755`) is unchanged.

---

## 9. TTY gate — `configs/airootfs/root/.automated_script.sh`

The TTY installer entry point now **exits early** (before setting up tty1 / running
the configurator) when the medium booted into the live desktop:

```bash
if grep -qw omarchy.live /proc/cmdline; then
  exit 0
fi
```

Otherwise the classic TTY install flow (Tokyo Night VT palette, offline-mirror
warm-up, configurator, dashboard, orchestrator) runs completely unchanged. This is
what lets the desktop and TTY install paths coexist.

---

## 10. Initramfs fix — `configs/airootfs/root/customize_airootfs.sh`

Fixes a build-time failure caused by the Omarchy runtime hard-depending on
`limine-mkinitcpio-hook`, whose hook lands in `/etc/pacman.d/hooks/` — the exact
directory archiso hooks at. That hook replaces the standard mkinitcpio run with a
Limine/UKI install into an ESP; the ISO has no ESP, so it aborted pacstrap and left
`/boot` without the initramfs that `mkarchiso` expects
(`install: cannot stat '/boot/initramfs-*.img'`).

The script:
1. Removes the Limine kernel/wrapper hooks:
   `90-mkinitcpio-install.hook`, `/usr/local/bin/mkinitcpio`, and the
   `60/80/90-limine-mkinitcpio-*` + `10-limine-snapper-lock.hook` alpm hooks.
2. Stages the kernel at the path the `linux-t2` preset expects
   (`ALL_kver=/boot/vmlinuz-linux-t2`).
3. Builds the live initramfs via the **real** `/usr/bin/mkinitcpio --preset linux-t2`
   (the Limine wrapper at `/usr/local/bin/mkinitcpio` shadows it).

Limine remains the installer's bootloader on an installed system; this only stops it
from breaking the ISO build.

---

## 11. Installer fix — `omarchy-iso-cleanup-disk` absolute path

Path: `configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py` (line 185)

**Change:**

```python
# before
subprocess.run(["omarchy-iso-cleanup-disk", disk], check=True)
# after
subprocess.run(["/usr/local/bin/omarchy-iso-cleanup-disk", disk], check=True)
```

**Why:** a real install log showed the very first install phase failing with
`FileNotFoundError: [Errno 2] No such file or directory: 'omarchy-iso-cleanup-disk'`
when launched from the live desktop. The script **is** present in the ISO at
`/usr/local/bin/omarchy-iso-cleanup-disk` (0755); the orchestrator process simply did
not have `/usr/local/bin` on PATH, so the bare-name lookup failed. Every other
`omarchy-iso-install`-family script already invokes `/usr/local/bin/*` by absolute
path; this was the single outlier. Using the absolute path removes the PATH
dependency entirely. This affects both the desktop and TTY installer paths (they share
the orchestrator). The script itself
(`configs/airootfs/usr/local/bin/omarchy-iso-cleanup-disk`) is unchanged.

Verified: `python3 -m py_compile` passes; all unit tests (
`./test/all`, 63 Python tests) pass. The rebuilt ISO contains the absolute-path call.

---

## 12. Acceptance harness — `bin/omarchy-iso-test` and `test/integration.d/base-test.sh`

Because the ISO's default boot entry is now the live desktop, the headless QEMU
acceptance harness (`bin/omarchy-iso-test`) must select the **TTY installer entry**
from the (graphical) boot menu before it can drive the install wizard:

- `boot_installer_entry()` OCRs the boot menu for the "Install" item, then sends a
  `down` + `Return` to pick the installer entry (with a timed fallback to beat grub's
  15s auto-boot).
- `drive_configurator()` and the rest of the install flow are otherwise unchanged;
  the README notes the acceptance harness selects the TTY entry before driving the
  wizard.

`test/integration.d/base-test.sh` was updated in the same pass so the integration
baseline also boots into the installer entry rather than the default live desktop,
keeping the TTY install path covered by tests.

---

## 13. Documentation — `README.md`

The README's "Live desktop" section documents:
- The ISO's default boot entry lands in a live Omarchy desktop (Hyprland +
  Quickshell) started by SDDM from `/etc/skel`, so a user can try Omarchy before
  installing.
- An **Install Omarchy** launcher row opens the installer wizard in a terminal on
  the desktop.
- The classic TTY installer remains available as a separate boot entry ("Omarchy -
  Install (TTY wizard)", cmdline `omarchy.install`); the desktop and TTY boots are
  distinguished by `omarchy.live`; the TTY path (incl. the cidata autoinstall used by
  the acceptance harness) is unchanged.

---

## 14. Verification performed

- `bash -n` on all modified/new shell scripts (`omarchy-live-desktop`,
  `customize_airootfs.sh`, `build-iso.sh`, etc.) passes.
- `python3 -m py_compile` on `phases_impl.py` passes.
- Unit suite passed: `./test/all` (9 shell tests + 63 Python tests) plus the
  project's permission lint.
- Rebuilt ISO(s) verified structurally inside the mounted squashfs:
  - `omarchy-iso-cleanup-disk` present at `/usr/local/bin` (0755); orchestrator calls
    it by absolute path.
  - Live packages present: `xdg-terminal-exec`, `nautilus`, `chromium`, `fastfetch`,
    `gnome-disks`.
  - `omarchy-live-desktop` carries `LIVE_PASSWORD="omarchy"` + `chpasswd`, and the
    headless `omarchy-theme-set` / `-pi --activate` provisioning.
  - `omarchy-install.desktop` and the menu-extension entry present in the script.
  - grub `omarchy-live-nomodeset` entry and syslinux `arch64-nomodeset` label both
    carry `nomodeset omarchy.live`.
  - Theme source and `foot.ini.tpl` present under `/usr/share/omarchy/`.
  - Final ISO is a valid bootable hybrid (`ISO 9660 ... 'OMARCHY_202608'`, `file`),
    owned by `mihai:mihai`.
- **Not runtime-tested:** a QEMU boot of the live desktop itself (no display in the
  build environment), so the wallpaper/foot.ini/Install-entry behavior is
  structurally verified but not boot-verified in the GUI.

---

## 15. Files added vs. modified (summary)

**Added:**
- `configs/airootfs/usr/local/bin/omarchy-live-desktop`
- `configs/airootfs/usr/local/bin/omarchy-live-install`
- `configs/airootfs/usr/local/bin/omarchy-live-install-wizard`
- `configs/airootfs/usr/lib/systemd/system/omarchy-live-boot.service`

**Modified:**
- `builder/build-iso.sh` (live packages)
- `configs/profiledef.sh` (live script perms)
- `configs/grub/grub.cfg` (live default + nomodeset + TTY entry)
- `configs/syslinux/archiso_sys.cfg`, `configs/syslinux/archiso_sys-linux.cfg`
  (live default + nomodeset + TTY entry)
- `configs/airootfs/root/.automated_script.sh` (TTY gate on `omarchy.live`)
- `configs/airootfs/root/customize_airootfs.sh` (initramfs/Limine fix)
- `configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py`
  (`omarchy-iso-cleanup-disk` absolute path)
- `bin/omarchy-iso-test`, `test/integration.d/base-test.sh` (boot-menu entry selection)
- `README.md` (live desktop docs)
