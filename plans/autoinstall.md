# Autoinstall Plan

## Goal

Let the standard Omarchy ISO install itself with no keyboard present, driven by config files handed to the VM on a second drive. This makes Omarchy usable as a Packer/Proxmox base image for disposable dev environments: create VM, boot, walk away, SSH in.

## Product Requirements

- No ISO rebuild. The shipped ISO autoinstalls when config is present and runs the configurator when it is not.
- No new menu entry, no new boot parameter, no separate ISO flavor.
- Config format is exactly what the configurator already writes — no second schema to maintain.
- The installed machine is reachable over SSH with a key supplied at install time.
- Interactive installs behave identically to today.

---

## Chosen Architecture

### Trigger: config presence, not a mode flag

The installer looks for a drive labeled `cidata` at startup. If it is there and carries the configurator's output files, those files are copied into `/root` and `./configurator` is skipped — the rest of the install runs the ordinary path against ordinary inputs. If it is not there, nothing changes.

This is Ryan Hughes' suggestion from PR #72 and it is what keeps the diff small: the install pipeline can be rewritten freely as long as it keeps reading its five files out of `/root`, and autoinstall follows along for free.

`cidata` is the cloud-init `NoCloud` label, so Proxmox, libvirt, and Packer all already know how to attach one.

### What the ISO already does for us

One thing that would otherwise need building is already true on a stock install: `NetworkManager.service` is enabled and active with DHCP by default, so autoinstall needs no `systemd-networkd` unit — one would contend with NetworkManager.

Remote access needs three things, all verified against a real install rather than inferred:

- `authorized_keys` for the user.
- `systemctl enable sshd.service`. Omarchy ships `openssh` but leaves the service disabled.
- `ufw allow ssh`. `install/config/firewall.sh` opens LocalSend (53317) and docker DNS and nothing else, and ufw runs default-deny incoming.

Still no loosening of `PasswordAuthentication` — key auth only.

Do not take `manifests/fresh-4-semantic.json` as the authority on any of this. It claims `sshd.service: enabled` and carries an `allow tcp 22` ufw rule; a real install of this ISO has neither. It is a snapshot of one machine's state, not a contract about stock behavior, and trusting it cost two test cycles.

### Non-interactivity belongs to the dashboard

`omarchy-install-dashboard` owns every prompt that survives to the end of an install: the reboot confirm and, on failure, the action menu. Both are `gum` calls reading from the TTY, and both hang forever on a headless VM. Autoinstall therefore sets one env var that the dashboard reads, rather than patching prompts out of scripts after the fact — which is what PR #72 did to `finished.sh`, and what everyone correctly disliked.

---

## Non-Goals

- No config generator, validator, or schema doc. The configurator is the source of truth for the format; users copy its output.
- No secret management. Whoever builds the `cidata` drive owns the password hash and the public key on it.
- No PXE, no network-fetched config, no cloud-init compatibility beyond reusing the drive label.
- No changes to disk selection, encryption, or any install phase behavior.

---

## Repo Implementation Plan

## 1) Detect the cidata drive and skip the configurator

### File
- `configs/airootfs/root/.automated_script.sh`

### Changes
- Add a `load_cidata` function above the existing `cd /root` (`:93`):
  - Look for `/dev/disk/by-label/cidata` then `/dev/disk/by-label/CIDATA`; return non-zero if neither exists.
  - Mount read-only on a temp mountpoint; return non-zero if the mount fails.
  - Require both `user_configuration.json` and `user_credentials.json` on the drive — this is the same pair `InstallContext.from_env` treats as mandatory. Missing either means the drive is not an autoinstall drive; unmount and return non-zero.
  - Copy the required pair plus, when present, `user_full_name.txt`, `user_email_address.txt`, `user_encrypt_installation.txt`, and `ssh.json` into `/root`.
  - Unmount before returning. Leave nothing mounted for the install to trip over.
- Replace the bare `./configurator` call (`:94`) with: run `load_cidata`; on success export `OMARCHY_UI_INTERACTIVE=no`, on failure run `./configurator`.
- Pass `--ssh-keys-file /root/ssh.json` to `omarchy-iso-install` in the dashboard invocation (`:101`–`:110`), alongside the existing five flags. Always pass it; the orchestrator no-ops when the file is absent, which keeps the interactive path on the identical command line.

### Notes
- The three text files are optional by construction: `_read_text` in `context.py` returns `""` for a missing path and `encrypt` falls back to false. Do not add stricter checks here than the orchestrator itself applies.
- `load_cidata` must not run before `warm_offline_mirror` is backgrounded — the mirror warm should keep its head start.

### Acceptance criteria
- ISO with no `cidata` drive attached: configurator runs, byte-identical UX to today.
- ISO with a `cidata` drive carrying the five files: configurator never appears; install starts within seconds of boot.
- ISO with a drive labeled `cidata` that is empty or carries only one of the two required files: falls back to the configurator rather than failing the boot.
- Nothing remains mounted from `/dev/disk/by-label/cidata` once the install begins.

---

## 2) Non-interactive dashboard

### File
- `configs/airootfs/usr/local/bin/omarchy-install-dashboard`

### Changes
- Read `OMARCHY_UI_INTERACTIVE` once near the other env reads at the top.
- In `reboot_prompt()` (`:474`): when non-interactive, return 0 immediately instead of calling `gum confirm`. The existing `OMARCHY_UI_AUTO_REBOOT=no` check at `:737` stays in front of the actual `reboot`, so a debug run can set both and stop on the finish screen without a keyboard.
- In `failure_menu()` (`:597`): treat non-interactive as equivalent to the existing `OMARCHY_UI_FAILURE_ACTION=exit` early return (`:600`), so a failed autoinstall exits with the installer's status instead of blocking on `gum choose` forever. The failure screen and log tail still render, and the serial console still captures them.

### Why here and not in the caller
The dashboard is the only process that owns the visible UI. Suppressing its prompts anywhere else means editing scripts it invokes — the `finished.sh` `sed` from PR #72 — which breaks the moment those scripts move.

### Acceptance criteria
- Autoinstall run reaches the finish screen and reboots with no input.
- Autoinstall run whose install fails renders the failure screen, exits non-zero, and does not hang.
- Interactive run still prompts for reboot and still offers the failure menu.
- `OMARCHY_UI_INTERACTIVE=no` plus `OMARCHY_UI_AUTO_REBOOT=no` stops at the finish screen without prompting.

---

## 3) SSH keys as an orchestrator phase

### Files
- `configs/airootfs/usr/local/bin/omarchy-iso-install`
- `configs/airootfs/usr/share/omarchy-iso/orchestrator/context.py`
- `configs/airootfs/usr/share/omarchy-iso/orchestrator/main.py`
- `configs/airootfs/usr/share/omarchy-iso/orchestrator/phases_impl.py`

### Changes
- `omarchy-iso-install`: add `--ssh-keys-file` to the arg loop, exporting `OMARCHY_INSTALL_SSH_KEYS_FILE`. Same shape as the five existing flags, ahead of the `unknown arg` catch-all (`:19`).
- `context.py`: add an `ssh_keys_path: Path | None` field populated from that variable in `from_env`, `None` when unset or when the file does not exist.
- `phases_impl.py`: add `configure_ssh_access(ctx)`:
  - Return immediately when `ctx.ssh_keys_path` is `None`.
  - Parse the file as a JSON array of public key strings; write them one per line to `<target>/home/<user>/.ssh/authorized_keys`.
  - `.ssh` at `0700`, `authorized_keys` at `0600`, both owned by the user via `arch-chroot <target> chown -R <user>:<user>`. Do not hardcode uid 1000 as PR #72 did — ask the target for it.
  - `arch-chroot <target> systemctl enable sshd.service`. Works cleanly in the chroot.
  - `arch-chroot <target> ufw allow ssh` when the target has ufw. This one exits **non-zero** in a chroot (`ERROR: problem running`) because ufw cannot reach netfilter, but it writes the rule to `/etc/ufw/user.rules` before failing, and that file is what `ufw.service` loads on first boot. So ignore the exit status and assert the rule landed in the file instead.
  - A malformed or empty `ssh.json` must fail the phase loudly. A machine that installs "successfully" and is then unreachable is worse than one that stops with an error on screen.
- `main.py`: register `("Configuring SSH access", configure_ssh_access)` in `build_phases` after `configure_login` (`:52`) and before `validate_boot`.

### Model to follow
`configure_login` (`phases_impl.py:1251`) — direct writes against `ctx.target`, `arch-chroot` reserved for ownership and `systemctl`. Match its structure.

### Acceptance criteria
- Install with `ssh.json`: `ssh <user>@<vm>` works with the corresponding private key on first boot, no password.
- Install without `ssh.json`: phase runs, does nothing, install unaffected; `~/.ssh` is not created.
- `authorized_keys` is `0600` and owned by the install user, not root.
- Port 22 is open in ufw on the installed system. Test this by connecting, not by reading the phase log — the rule is written from a chroot that cannot verify it.
- Password SSH auth is left at the distro default — autoinstall does not enable it.
- Interactive installs are unaffected: the flag is passed but the file never exists.

---

## 4) Documentation

### File
- `README.md`

### Changes
- New "Autoinstall" section covering: what the `cidata` drive is, the file table, how to produce the drive, and a Proxmox `qm create` example with disk-first boot order so the empty disk falls through to the ISO on the first boot and boots the installed system afterward.
- Show `openssl passwd -6` for the credential hash and the `ssh.json` array format.
- State plainly that the config files are the configurator's own output — the documented way to get a starting `user_configuration.json` is to run one interactive install and copy what it wrote.
- Do not repeat PR #72's networking claims. Say that sshd and NetworkManager come enabled on a stock install and that autoinstall only adds the key.

---

## 5) Validation

### Manual matrix
1. Build the ISO from this branch.
2. Interactive control run: boot with no `cidata` drive, install normally, confirm nothing changed.
3. Autoinstall run on Proxmox: attach ISO + `cidata` drive, boot, no input; confirm the configurator never renders, the install completes, the machine reboots on its own, and SSH with the key works against the booted system.
4. Encrypted autoinstall: `user_encrypt_installation.txt` set true; confirm the LUKS prompt appears on boot (this is the one autoinstall case that still needs a human at first boot — document it).
5. Full Packer cycle: build, destroy, rebuild from the same `cidata` drive; confirm reproducibility.

### Negative tests
- Drive labeled `cidata` with no files → configurator runs.
- Drive with `user_configuration.json` only → configurator runs.
- Malformed `ssh.json` → install stops in the remote-access phase with a visible error, does not reboot into an unreachable machine.
- Install failure under autoinstall (e.g. a disk target that does not exist) → failure screen renders, process exits non-zero, no hang.

### Regression surface
The interactive path shares every line of this change except the `load_cidata` branch, so run the standard acceptance harness (`./bin/omarchy-iso-test`) on the built ISO before proposing the PR.

---

## Relationship to PR #72

PR #72 targeted the pre-`quattro` tree and cannot be rebased: `use_omarchy_helpers`, `run_configurator`, `install_arch`, `install_omarchy`, and `chroot_bash` no longer exist. This plan reimplements the same feature against the current tree and drops three things that PR deliberately flagged as questionable:

- The `finished.sh` `sed` — replaced by section 2. The dashboard renders the reboot prompt now.
- The `systemd-networkd` DHCP unit — unnecessary; NetworkManager is already enabled and would contend with it.
- The `PasswordAuthentication yes` rewrite — unnecessary and a security downgrade.

`load_cidata` is the one piece that carries over close to intact. PR #72's `ufw allow ssh` also carries over: it was dropped from the first draft of this plan on the reasoning that an enabled sshd is a reachable sshd, and a test install proved otherwise. That PR was right to include it.
