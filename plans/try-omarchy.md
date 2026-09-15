# Plan: Try Omarchy — a live desktop installed just-in-time from the bundled mirror

## Goal

Let someone boot the Omarchy ISO on the machine they are about to wipe and see the real desktop on their real hardware before committing — the x86 counterpart of the `try-omarchy` Mac app — without adding a byte to the ISO, without touching the install path, and without a second boot entry.

Not a rescue mode, not a persistent USB, not a portable Omarchy. The session is ephemeral by design and ends in "Install Omarchy".

## Context

The ISO already contains everything a live desktop needs. `omarchy-4.0.2.iso` is 6,227,752,960 bytes (5.80 GiB); `arch/x86_64/airootfs.sfs` is 5.51 GiB of that. Inside the squashfs, `/var/cache/omarchy/mirror/offline` holds **1,248 packages / 4.40 GiB** — the full closure of `omarchy-base.packages`, `omarchy-other.packages`, and `builder/archinstall.packages`, stored uncompressed (`configs/profiledef.sh:29`) so pacstrap reads it at line speed. The live root around it is 483 packages, ~1.1 GiB compressed, and boots to a TTY: `builder/build-iso.sh:121` adds only `linux-t2 git gum jq openssl plymouth ttfx tzupdate omarchy-keyring omarchy-settings lvm2 cryptsetup parted` on top of archiso's `releng` profile. No compositor, no mesa, no display manager.

So a try desktop does not need to be *shipped*. It needs to be *installed* — into the archiso copy-on-write overlay, from the mirror that is already on the stick, at the moment someone asks for it.

### Measured

Resolved against the shipped squashfs listing and the live pacman sync DB (2026-09-05):

| | packages | read from stick | lands in RAM |
|---|---|---|---|
| Try set (`builder/try.packages`: the desktop, a browser, sound, and what the default bindings and shell call) | 449 resolved, ~215 not already in the live root | 0.76 GiB | 2.5 GiB (before zram) |

Every one of them is already in the mirror. The list was audited against `omarchy-base.packages` and `omarchy-other.packages` by cost: everything the default `bindings/*.lua`, `omarchy-launch-*`, the Quickshell shell and the bash config exec is in (audio needs `pipewire-pulse`, which nothing in the desktop closure depends on — without it the session is silent); what is not is the heavy, on-demand tier — `nautilus` (+138 packages / 389 MiB, mostly gstreamer/ffmpeg/gvfs), `mpv`, `evince`, `imv`, LibreOffice, Obsidian, the dev toolchain — each one offline `pacman -S` inside the session. The only desktop-adjacent packages *not* in the mirror are `vulkan-nouveau` and `vulkan-swrast`, which `install/hardware/vulkan.sh` does not install either, so they are not part of the product and not part of the try set. Net ISO growth: the scripts in this plan.

`pacman -U` of a *larger* set (385 packages, 1.14 GiB of archives, hooks masked, into tmpfs) on a Ryzen 9800X3D: **8.7 s** with signature verification, **6.6 s** without. Peak RSS 70 MiB; libalpm is single-threaded, so a 2–3× slower laptop CPU lands at 13–26 s. The `[offline]` repo is `SigLevel = Never` (`configs/pacman-offline.conf:23`), so the lower number applies. The USB read (0.39 GiB) overlaps with the greeter wait (below).

### Why this shape and not the obvious ones

- **Prebake a desktop into the live squashfs.** `build-iso.sh:194` folds the finalized `packages.x86_64` into the offline-mirror download set, so anything added to `arch_packages` ships *twice*: once installed, once as an archive. +0.39 GiB becomes ~+0.6 GiB of ISO, at 20,000 downloads/day. Rejected on size.
- **A second `desktop.sfs` mounted on demand.** Mainline overlayfs cannot add a lower layer to a mounted root (`ovl_reconfigure` only flips ro/rw; Slax ships a patched aufs kernel for exactly this). It would need a boot-menu entry to select before the initramfs builds the overlay, and it still grows the ISO. Rejected.
- **Make the live root the full desktop and install by copying it.** Net size ≈ 0 because the copied packages leave the mirror, but it replaces `arch_install_system` (`orchestrator/phases_impl.py:216-318`) — the most safety-critical path in the product — and invalidates `manifests/`. Not a change an outside PR should carry alongside a feature.
- **Install at try-time from the mirror.** Zero ISO growth, zero installer change, reuses the mirror the install already validates. This is what Alpine's diskless ISO does on every boot (`apk add --root $sysroot --repository <on-medium repo>` into tmpfs). Chosen.

## Current State

Relevant facts about the tree this lands in:

- `configs/airootfs/root/.automated_script.sh:13` guards on tty1, starts `warm_offline_mirror` (page-cache prefetch, largest-first, half of `MemAvailable`) at `:89`, runs `./configurator` at `:102`, then hands off to the dashboard + orchestrator. The try branch belongs between the prefetch and the configurator.
- `configs/airootfs/root/configurator:102-176` `greeter()` is a single "Press Return to Start Install" modal with no state committed. Deferred provisioning (Ctrl+C on the keyboard screen, `:206`) and the encryption toggle (`:949`) are the existing precedents for "another mode, no boot entry".
- The live `/etc/pacman.conf` **is** `pacman-offline.conf` (`build-iso.sh:347`), so `pacman -S` in the live root already resolves against `[offline]` at `file:///var/cache/omarchy/mirror/offline/`. Nothing to configure.
- `orchestrator/phases_impl.py:678` `_mask_mkinitcpio_pacman_hooks` masks boot-image hooks by symlinking their names to `/dev/null` under `/etc/pacman.d/hooks`; the list is `DEFERRED_BOOT_HOOKS` (`:590`). Same technique, same list, for the try install.
- `configure_login` (`phases_impl.py:1403`) writes `etc/sddm.conf.d/autologin.conf` as `[Autologin]\nUser=…\nSession=omarchy.desktop`. The try session writes the identical file.
- `omarchy-settings` is already in the live root (`build-iso.sh:118-121`), so `/etc/skel` carries the full Omarchy dotfile payload. A new user gets the product's config for free.
- The live root runs **iwd + systemd-networkd** (releng). Omarchy's shell drives NetworkManager (`shell/plugins/panels/network/Model.js`). `networkmanager` and `wpa_supplicant` are both on the stick.
- archiso mounts the overlay upper on a tmpfs sized by `cow_spacesize`, default **256M** (`mkinitcpio-archiso` hook `:231`). The try set needs ~1.2 GiB there.
- `linux-firmware` (full, including NVIDIA GSP firmware) is in the live root, so in-kernel `nouveau` has what it needs on Turing and later.
- `bin/omarchy-iso-make:73-104` refuses to build if an executable under `configs/airootfs/usr/local/bin` or `/root` lacks a `file_permissions` entry in `profiledef.sh`.
- `bin/omarchy-iso-test:364` `session_started()` (`ls /run/user/1000/hypr`) is already the harness's "Hyprland is up" predicate.

## Approach

One new script, one new greeter choice, one branch in `.automated_script.sh`, one harness flag. The install path is not modified; Try is a blocking call *in front of* it that returns to the same place.

```
tty1 ─ .automated_script.sh
        │  prefetch: try-set first, then the rest of the mirror
        ▼
      greeter ──── "Install Omarchy" (Return, default) ──────────────┐
        │                                                            │
        └─ "Try Omarchy first" ─▶ omarchy-try                        │
                                    │ guard RAM; offer NVIDIA driver │
                                    │ ┌ omarchy-install-dashboard ──┐│
                                    │ │ omarchy-try-setup:          ││
                                    │ │  resize cowspace, install   ││
                                    │ │  <try set> [offline],       ││
                                    │ │  [nvidia], NetworkManager,  ││
                                    │ │  useradd try (skel) + theme ││
                                    │ │  → logo + progress bar + tips││
                                    │ └─────────────────────────────┘│
                                    │ systemd-run uwsm → Hyprland    │
                                    │ … session …                    │
                                    │ "Install" stops the unit       │
                                    ▼                                │
                                  return ────────────────────────────┤
                                                                     ▼
                                                             ./configurator (unchanged)
```

### Time-to-desktop budget (Try chosen)

| step | cost |
|---|---|
| ISO boot to greeter | unchanged |
| read 0.76 GiB of archives | overlapped with the greeter wait by prefetching the try set first; otherwise 2–8 s on USB 3, ~25 s on USB 2 |
| `pacman -S` the ~215 packages the live root lacks into tmpfs | ~8 s here (10 s from T to desktop in QEMU), 20–40 s on a laptop |
| kept hooks (fontconfig, gdk-pixbuf, glib schemas, mime, desktop-database, sysusers/tmpfiles, ldconfig) | ~5–10 s |
| NetworkManager start, useradd, theme set | ~2 s |
| systemd-run session → uwsm → Hyprland on VT7 | ~2–5 s |
| **Try → desktop** | **~15 s here, ~25–40 s on a laptop** |

The two things that would blow it are `mkinitcpio` and `limine` hooks, which are masked, and `copytoram`, which is never set.

### RAM

2.5 GiB in the cowspace tmpfs plus the running session (~0.8 GiB with a browser closed). archiso caps that tmpfs at a fraction of physical RAM, so the cap is what decides whether a small machine can play, and `omarchy-try-setup` raises it to 100%. tmpfs is demand-allocated, so this reserves nothing on a large machine; on a small one it lets compressed swap do the work. `zram-generator` (1 MiB) is installed first and `omarchy-settings`, already in the live root, ships the `zram-size = ram, zstd` config an installed system runs, so a `daemon-reload` and `systemctl start systemd-zram-setup@zram0` bring swap up **before** the install fills the overlay.

Only then is the overlay worth judging. The setup compares its free space against the installed size of the packages the set still has to add (each package's size is a column of the build-time list, and `pacman -Qq` says what a second try in the same boot already has, plus 25% headroom) and refuses with real numbers rather than letting pacman fail mid-transaction.

Measured on a nominal 4 GiB machine (`MemTotal` 3.81 GiB): desktop up **10 s** after T, Chromium opens and the session survives it, zram holding 1.1 GiB, 0 OOM kills. So `omarchy-try` gates on `MemTotal >= 3.5 GiB` and leaves the real decision to that capacity check. An earlier draft used an 8 GiB floor derived from a 50% cap; it was arithmetic rather than measurement, and it locked out machines that work.

### GPU

AMD and Intel get full hardware acceleration from `mesa` + `vulkan-radeon` + `vulkan-intel` in the try set. The interesting case is a machine whose only display is on a GPU the session has no driver for — above all NVIDIA, whose proprietary driver the try session deliberately doesn't ship.

The answer is **software rendering on the firmware framebuffer**, and it covers every GPU including the newest, at zero cost. The kernel's `simpledrm` already lights the panel for the greeter via the EFI framebuffer; aquamarine (Hyprland's backend) requires GBM, and Mesa's `kms_swrast` provides GBM on `simpledrm` backed by llvmpipe — so Hyprland comes up software-rendered on any GPU. Verified against aquamarine's source and confirmed running in the wild. It needs two things:

- **`nouveau` blacklisted in the live root** (`etc/modprobe.d/omarchy-try-nouveau.conf`). Otherwise nouveau binds the NVIDIA card and *evicts* `simpledrm` while being unable to modeset newer cards (Blackwell), leaving no display at all. `modconf` runs before `kms` in the live HOOKS, so the blacklist applies from early boot.
- **Keeping nouveau off the card**, on UEFI boots only. `modprobe.blacklist=nouveau` rides the two `linux` lines in each of `configs/grub/grub.cfg` and `configs/grub/loopback.cfg` (the same ISO loop-mounted, as Ventoy does) rather than a file in `/etc/modprobe.d`, because the blacklist is only wanted where there is a firmware framebuffer to fall back to, and both of those set `gfxpayload=keep`. A BIOS boot has none (`bootmodes` includes `bios.syslinux`, and the installer supports `!has_uefi`), so suppressing nouveau there would drop an NVIDIA-only machine's installer to an 80x25 vgacon for nothing; the syslinux config is untouched.
- **Steering aquamarine to the panel's node.** `omarchy-try`'s `select_display_gpu` finds the DRM card actually driving a connected display and passes it as `AQ_DRM_DEVICES`, forcing `LIBGL_ALWAYS_SOFTWARE` only when that node is the firmware framebuffer. This matters on a hybrid box (an AMD iGPU with no monitor alongside an NVIDIA card whose panel is on `simpledrm`): without steering, aquamarine can pick the display-less iGPU and render to nowhere.

The trade-off is that an unsupported-GPU preview runs on llvmpipe — slow, but "Try" is about look, feel and hardware compatibility (wifi, trackpad, display), not GPU speed; the accelerated experience is exactly what installing delivers, where Omarchy sets up the proprietary driver on disk (`install/hardware/nvidia.sh`). Software rendering also can't fill a panel `simpledrm` has no mode for — a 32:9 ultrawide, say — and llvmpipe at that size would crawl regardless. So the software fallback is the universal floor (nothing dead-loops), and on an NVIDIA-driven panel the session **offers** the real driver: `omarchy-try` detects the case (firmware-fb panel + an NVIDIA GPU per Omarchy's own `omarchy-hw-nvidia-gsp` check) and, if the user accepts, `omarchy-try-nvidia` installs `nvidia-open-dkms`/`nvidia-utils` (or the 580xx branch) from the bundled mirror — the driver, its utils and the whole DKMS toolchain are on the stick, so this works with no network, and `build-iso.sh` resolves both generations plus the running kernel's headers at build time and warns by name if either is missing, so a mirror change cannot turn the offer into a silent software fallback. It warns rather than failing: those packages come from `omarchy-other.packages`, so retiring a driver branch upstream must not break the nightly ISO build over an opt-in extra — reusing Omarchy's exact generation selection so live and installed never disagree — sets `nvidia_drm modeset=1`, loads the modules, and `select_display_gpu` re-runs to find the now-hardware NVIDIA node for a native, accelerated session. The boot hooks are already masked, so the DKMS module builds without touching the initramfs. It's opt-in and only appears on NVIDIA-panel machines; the mirror already carries the packages (zero ISO growth), and it costs ~886 MiB of overlay RAM plus the couple-minute build. Secure Boot would block the unsigned module — the notice says so. Proprietary NVIDIA is offered, not forced: it stays an opt-in behind the always-working software floor, so the default path never depends on it. If even software rendering can't bring up a display, the session shows a GPU-named notice pointing to install or an iGPU port rather than looping.

### Apps on demand

The live `pacman.conf` already points at `[offline]`, so inside the session `omarchy-install-app`, `omarchy-webapp-install` and `pacman -S` resolve against the stick with no network. Chromium is a 133 MiB archive on the stick: a few seconds. This is the reason the try set is deliberately small — everything else Omarchy ships is one command away, offline. Packages *not* in the mirror need the real repos and a network; the try session does not add them (out of scope, see below).

## Concrete changes

### 1. `configs/airootfs/usr/local/bin/omarchy-try` (new, ~150 lines bash)

Runs as root on tty1, called from `.automated_script.sh`. Returns 0 when the user chose Install from the session, non-zero (with a one-line reason already shown) on any failure. Never touches a block device.

1. **Guard.** `MemTotal ≥ 3.5 GiB` (a nominal 4 GiB machine) or bail with a message. Kill the mirror prefetch (`warm_pid` is exported by the caller; see §3).
2. **Grow the overlay.** `mount -o remount,size=100% /run/archiso/cowspace`. tmpfs resizes live and allocates on demand; the mount point is the one archiso created. Then install `zram-generator` and start zram, and only then check the overlay's free space against the installed size of the packages not yet present (+25%), refusing with numbers if it cannot hold them.
3. **Mask boot hooks.** Symlink each name in `DEFERRED_BOOT_HOOKS` (`60-mkinitcpio-remove.hook`, `60-limine-mkinitcpio-remove-pre.hook`, `80-limine-efi-deploy.hook`, `90-limine-mkinitcpio-remove-post.hook`, `90-mkinitcpio-install.hook`) to `/dev/null` under `/etc/pacman.d/hooks`. Mirrors `_mask_mkinitcpio_pacman_hooks`; the live root is discarded at reboot so no unmask is needed.
4. **Install.** `pacman -Sy --needed --noconfirm --assume-installed limine --assume-installed limine-mkinitcpio-hook --assume-installed limine-snapper-sync --assume-installed snapper <builder/try.packages, resolved at build time>`. `--assume-installed` keeps the four bootloader/snapshot packages (17 MiB, and the source of the dangerous hooks) out of a root that has no ESP and no btrfs. `-Sy` rather than `-S` because mkarchiso empties `/var/lib/pacman/sync` in the live root; the sync reads `offline.db` off the medium and touches no network. Progress goes to the TTY under the Tokyo Night palette the script already sets.
5. **Network and daemons.** `systemctl stop iwd systemd-networkd`; `systemctl start NetworkManager`. `systemd-resolved` stays (NM uses it). This is the installed product's stack. Then the daemons the shell talks to and an installed system enables (`bluetooth`, `power-profiles-daemon`), the zram swap (RAM, above), and — only if `nm-online` already reports a connection, bounded to 4 s — `tzupdate`, so the bar's clock reads local time the way the installer's setup form would have set it.
6. **User.** `useradd -m -G wheel,video,input,audio -s /bin/bash try`; empty password; `/etc/sudoers.d/try` NOPASSWD. `/etc/skel` seeds the dotfiles. Then as `try`: `OMARCHY_THEME_HEADLESS=1 omarchy-theme-set "Tokyo Night"` and `xdg-user-dirs-update`. Not `omarchy-provision-user`: `install/user/mise.sh` and `chromium.sh` reach for the network and have no guards, and none of what they do matters for a look-and-feel session.
7. **Session.** `chvt 7`, then start the desktop as a transient unit on that VT: `systemd-run --unit=omarchy-try-session --uid=try -p PAMName=login -p TTYPath=/dev/tty7 … uwsm start … Hyprland`. The VT switch must come *before* the compositor starts: libseat's logind backend only gives input devices to the session owning the active VT, so starting Hyprland while the greeter still holds VT1 leaves it with a rendered desktop and no input (verified: input fds 0 → 5 when the VT is switched first). Not SDDM: it claims VT1, where the configurator that called us lives, so starting it kills the greeter and stopping it leaves VT1 blank. A logind session on VT7 leaves the configurator running on VT1 the whole time. Then wait until the unit goes inactive and `chvt 1`. Also mask `omarchy-fcitx5.service` for the try user — its binary is outside the try set and it would otherwise crash-loop.
8. **Return.** When the session unit goes inactive (the in-session Install action stops it), `chvt 1` to bring the greeter forward, restore the installer's network (`systemctl start systemd-networkd.socket systemd-networkd.service iwd.service`, stop NetworkManager), and return 0. Optionally `pacman -Rns` the try set to give the RAM back; the installer is disk-bound so this is not required and is left out of the first cut.

### 2. In-session affordances (shipped inside the same script, written at try-time)

- `/etc/xdg/autostart`-style hook or a `hyprctl notify` on session start: "Try session — running from the USB stick, nothing has been written to your disk. Press Super+Shift+I to install." Kept to one notification.
- `/usr/local/bin/omarchy-try-install`: `sudo systemctl stop omarchy-try-session.service`. Bound via the `try` user's `~/.config/hypr/bindings.lua`, so the shipped `default/hypr` is untouched.
- Nothing else. No wallpaper packs, no welcome app.

### 3. `configs/airootfs/root/.automated_script.sh`

- Export `warm_pid` so §1 can stop the prefetch.
- Reorder `warm_offline_mirror` to read the try set's archives first (list from §5), then continue largest-first as today.

That is the whole change here. The greeter owns the Try loop (§4), so the call sequence `./configurator` → dashboard → orchestrator is untouched, and the autoinstall branch (`:97-102`) never sees a greeter.

### 4. `configs/airootfs/root/configurator`

`greeter()` (`:102-176`): replace the single Return hint with a two-item `gum choose` — `Install Omarchy` (default) / `Try Omarchy first`. Return selects the default, so the muscle memory of every existing user and the OCR waits in the harness are preserved. On "try", `greeter()` calls `/usr/local/bin/omarchy-try` and, when it returns, redraws itself; the function only returns to the configurator's main flow once "Install Omarchy" is chosen. Esc keeps its meaning. The `ttfx colorshift` animation and `wait_for_stable_terminal` are unchanged.

While here: the tagline changed to "Beautiful, Fun & Agentic" in `2673c61` but `bin/omarchy-iso-test:617,734,809` and `test/integration.d/factory-reset-test.sh:168,178` still `wait_for_screen "Opinionated"`. Fix in the same series (own commit) or the `--try` scenario cannot pass either.

### 5. `builder/build-iso.sh`

One addition next to `expected-packages` (`:292-344`): resolve the try set against the same offline DB and write the resulting **archive filenames** to `airootfs/usr/share/omarchy-iso/try-packages`. The build already resolves the mirror this way; this makes the try set a build-time fact (so a package leaving the mirror fails the build, not the user) and gives §3 its prefetch list. No change to `arch_packages`, `packages.x86_64`, or the mirror.

### 6. `configs/profiledef.sh`

`["/usr/local/bin/omarchy-try"]="0:0:755"` and `["/usr/local/bin/omarchy-try-install"]="0:0:755"` in `file_permissions`, or `omarchy-iso-make` refuses to build.

### 7. `bin/omarchy-iso-test`

`--try`: boot the ISO, `wait_for_screen` for the greeter, `press down; press ret`, wait for the desktop, then `press` the install binding and continue into the **existing** install assertions. The try path is exercised in front of the install test rather than beside it, so it cannot regress silently.

Desktop assertion: the harness talks to guests over SSH after a typed console bootstrap (`:874-926`); in the try session use the same bootstrap on tty3 and reuse `session_started()`, or have `omarchy-try` echo `OMARCHY_TRY_SESSION_UP` to `/dev/ttyS0` when `/run/user/$(id -u try)/hypr` appears and grep the serial log. The serial marker is simpler and needs no key material in a live root.

The harness runs `-device virtio-vga` without GL (`:220`), so Hyprland renders on llvmpipe. Expect it to start; expect it to be slow. `WLR_RENDERER_ALLOW_SOFTWARE=1` may be needed in the try user's environment — a spike item.

### Not changed

`configs/grub/*`, `configs/syslinux/*`, `configs/efiboot/*` (no boot entry, no timeout), `orchestrator/*` (no installer change), `arch_packages`, the mirror, `manifests/`.

## Testing

- `test/all` gains a unit test for the try-set resolution in §5 (same shape as `test_offline_mirror_pruning.py`).
- `bin/omarchy-iso-test --try` (§7) in QEMU.
- Real hardware, before the PR: an Intel iGPU laptop, an AMD laptop, a hybrid NVIDIA laptop, and a desktop with a discrete NVIDIA card as its only output. Record time-to-desktop from the Try keypress and `MemAvailable` after the session is up. Land those numbers in the PR body.

## Spike results (stock omarchy-4.0.2 ISO, QEMU, virtio-vga/llvmpipe, 8 GiB)

Run against the shipped ISO with the exact sequence this design uses:

1. **Overlay resize** — `mount -o remount,size=50% /run/archiso/cowspace` took the upper from 256M to 3.9G live. Works.
2. **Install** — `pacman -Sy --needed --assume-installed {limine,limine-mkinitcpio-hook,limine-snapper-sync,snapper} omarchy mesa vulkan-radeon vulkan-intel networkmanager noto-fonts noto-fonts-emoji foot` resolved 146 packages, 1126 MiB installed, in **3.5 s** on this host. All 17 post-transaction hooks ran (ldconfig, sysusers, tmpfiles, fontconfig, gio, gsettings, gtk3 im, icon caches, desktop/mime) and **no `limine`/`mkinitcpio` hook fired** — the five `/dev/null` masks held. Overlay used 1.6 GiB after.
3. **Network** — stopping iwd/networkd and starting NetworkManager left `nmcli device` reporting the wired link `connected`.
4. **User + theme** — `useradd` + `omarchy-theme-set "Tokyo Night"` (headless) succeeded; `/home/try/.local/state/omarchy/current/` was populated and the Quickshell bar rendered the theme. Two harmless warnings under `runuser`: the theme-set flock lives at `${XDG_RUNTIME_DIR}/…` which is root's under `runuser` (the lock is best-effort; theme still applied), and `xdg-user-dirs-update` needs a real user session (skipped, `|| true`). omarchy-try runs both with `env HOME=…` and tolerates their failure.
5. **Session / VT handoff — the design-changing result.** SDDM autologin brought the desktop up in ~1 s, **but SDDM claims VT1**: starting it deallocated the getty there and killed the configurator that had launched the try session, and stopping SDDM left VT1 blank — the greeter never came back. Relaunching needed `systemctl start getty@tty1`, which re-runs the whole `.automated_script.sh` (prefetch included), not the waiting configurator. Switching to a transient logind session — `systemd-run --unit=omarchy-try-session --uid=try -p PAMName=login -p TTYPath=/dev/tty7 … uwsm start … Hyprland` — brought Hyprland + Quickshell up in ~2 s on **VT7** and left the configurator alive on VT1 the entire time (`ps -t tty1` still showed it). This is why the design starts the session as a unit rather than through SDDM. `uwsm` found the `omarchy.desktop` session and started Hyprland with no extra environment beyond `XDG_SESSION_TYPE`/`XDG_SESSION_CLASS`.
   A second, deeper pass found the transient session needs one more thing: its **VT must be the active VT before the compositor starts**, or libseat's logind backend reports the session inactive and libinput refuses every device — a rendered desktop with a dead mouse and keyboard. Switching to VT7 before `systemd-run` (not after the socket appears) fixed it; verified input file descriptors go 0 → 5 and an injected Super+Shift+I tears the session down and returns to the greeter. Separately, `omarchy-fcitx5.service` (enabled for every Omarchy user, binary not in the try set) crash-looped 100+ times per visit and is now masked for the try user; a clean session logs zero fcitx failures.

6. **Apps on demand** — `pacman -Sy chromium` from inside the live root pulled from `[offline]` in **0.66 s** (already in page cache). Confirms in-session installs are offline and instant.
8. **Package audit** — resolving the try set against the mirror's `offline.db` and diffing it against `omarchy-base.packages` + `omarchy-other.packages` found 123 + 54 packages outside the closure. Costed one at a time (marginal packages / MiB on top of the closure) and cross-referenced with what the default bindings, `omarchy-launch-*`, the shell and the bash config exec, the cut was: in — `pipewire-pulse`/`-alsa` (sound was silent without them), `xdg-terminal-exec` (Super+Return was dead without it), the portal/GTK/bluetooth/power-profile plumbing, the keybinding tools (`wl-clipboard grim slurp hyprpicker hyprsunset brightnessctl wtype omacalc`), `omarchy-nvim` (93 MiB, the editor binding), the terminal tools the bash config is written for (~40 MiB); out — everything over ~100 MiB that is one binding or none (`nautilus` 389 MiB, `mpv` 206, `evince` 134, `imv` 40), all preinstalled desktop apps, DKMS/toolchains, `udiskie` (needs the udisks stack, and there is no file manager to show a mount). Net: 449 packages / 0.76 GiB of archives / 2.51 GiB installed, 14 of them already in the live root.
9. **No network at all** — an air-gapped boot (QEMU `-netdev user,restrict=on`: no host, no internet, nothing the guest does can restore it) reaches the desktop **24 s** after T. The install needs no network by construction — the only repo is the `file://` mirror — and the two steps that touch it are bounded (`nm-online -q -t 4`, then `timeout 15 tzupdate`, skipped when that fails). This found the one bug that made "try it before you wipe the disk" impossible on a laptop that had not joined wifi yet: `power-profiles-daemon` orders after `time-sync.target`, `systemd-time-wait-sync` never finishes without a clock source, and a blocking `systemctl start` on it never returned — the install sat at the progress bar indefinitely. Both convenience daemons are now started with `--no-block`, as is the network restore on the way back to the installer.
9. **Real hardware (hybrid AMD Granite Ridge iGPU + RTX 5080, 5120×1440 panel on the NVIDIA card)** — T at the greeter, the centered NVIDIA offer, "Set up the NVIDIA driver now": DKMS built `nvidia-open-dkms 610.57.04` against `linux-t2 7.2.3` from the stick, `nvidia_drm` loaded, and the session came up on the NVIDIA node at native 5120×1440 with the monitor's EDID description; Super+Return, Super+Shift+Return and sound all worked. The one bug this pass found was in the handover, not the design: `modprobe nvidia nvidia_modeset nvidia_uvm nvidia_drm` loads only the first name and passes the rest as its parameters (dmesg: `unknown parameter 'nvidia_drm' ignored`), so no NVIDIA DRM device ever appeared and the connector wait fell back to software. Fixed with `modprobe -a`; the unit test now asserts the exact argv, since a stub cannot catch that semantics.
7. **llvmpipe** — Hyprland and Quickshell rendered under plain `virtio-vga` (software GL) without extra environment; no `WLR_RENDERER_ALLOW_SOFTWARE` needed on this QEMU. Real hardware with a GPU will be faster.

## Out of scope

Persistence, a persistent home, portable installs, rescue tooling (declined in omacom/omarchy#1355), proprietary NVIDIA in the session, online repos in the session, a Try boot-menu entry, changes to the deferred-provisioning or cidata paths.

## Framing for the PR

"Try Omarchy" — a taste of Omarchy on the hardware you are about to install it on, the way the Mac app is a taste of it on a Mac. No rebuild, no extra boot entry, no extra bytes: the ISO already carries every package; Try installs about 435 of them into RAM when asked, and ends in Install. One change per PR: the greeter choice, the script, the harness flag, the tagline OCR fix.
