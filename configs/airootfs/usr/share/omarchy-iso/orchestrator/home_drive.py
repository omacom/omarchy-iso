"""Home on another drive: the orchestrator's side of the configurator's Home
step (omarchy_install.home).

The configurator scanned the machine and the user chose an existing home to
adopt or a disk to erase for a fresh one. Nothing about that choice is taken on
trust: the drive is scanned again with the same shared helper (omarchy's
install/provisioning/home-drive.sh, vendored into the ISO like the setup form)
before any disk is erased, and once more against the accounts of the image
that was just written, and a choice that no longer matches is refused. An
autoinstall config reaches the orchestrator without the configurator, so these
checks are the ones every install path passes.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

from .ui import error, info

HELPER_CANDIDATES = (
    Path("/usr/share/omarchy-iso/home-drive.sh"),
    Path("/usr/share/omarchy/install/provisioning/home-drive.sh"),
)

# dir: the folder holding the user's home inside the filesystem (or
# subvolume) when it is another system's root ("home", for home/<user>), else
# "" for a filesystem that is itself a /home.
ADOPT_FIELDS = {"device": str, "uuid": str, "fstype": str, "subvol": str, "luks_uuid": str, "uid": int, "gid": int,
                "dir": str}


def parse_home(home: Any, defer_provisioning: bool) -> dict | None:
    """The validated omarchy_install.home, or None for home on the install disk."""
    if home is None:
        return None
    if defer_provisioning:
        raise RuntimeError("home drive: a deferred-provisioning install chooses home at first boot, not here")
    if not isinstance(home, dict):
        raise RuntimeError(f"home drive: expected an object, got {home!r}")
    mode = home.get("mode")
    if mode == "adopt":
        # A hand-written autoinstall config may spell "none" as null, and one
        # written before homes inside another system leaves dir out.
        for key in ("subvol", "luks_uuid", "dir"):
            if home.get(key) is None:
                home[key] = ""
        for key, kind in ADOPT_FIELDS.items():
            if not isinstance(home.get(key), kind) or isinstance(home.get(key), bool):
                raise RuntimeError(f"home drive: adopt needs {key} ({kind.__name__})")
        if not home["device"].startswith("/dev/") or not home["uuid"]:
            raise RuntimeError("home drive: adopt needs a device and a filesystem uuid")
    elif mode == "fresh":
        if not isinstance(home.get("disk"), str) or not home["disk"].startswith("/dev/"):
            raise RuntimeError("home drive: fresh needs a disk")
    else:
        raise RuntimeError(f"home drive: unknown mode {mode!r}")
    return home


def helper_path() -> Path:
    for candidate in HELPER_CANDIDATES:
        if candidate.is_file():
            return candidate
    raise RuntimeError("home drive: home-drive.sh is not on this ISO")


def _disks_under(path: Path) -> list[str]:
    """The disks holding whatever is mounted at path (none when nothing is)."""
    source = subprocess.run(["findmnt", "-nro", "SOURCE", str(path)], capture_output=True, text=True).stdout.strip()
    if not source:
        return []
    source = source.split("[", 1)[0]
    tree = subprocess.run(["lsblk", "-nsrpo", "NAME,TYPE", source], capture_output=True, text=True).stdout
    return [name for name, kind in (line.split()[:2] for line in tree.splitlines() if line.strip()) if kind == "disk"]


def scan_cleanup() -> None:
    """Let go of what an interrupted scan left behind: a scan killed midway
    (the configurator's spinner interrupted, or an earlier attempt) leaves a
    drive mounted read-only or an omarchy-home-scan mapping open, which holds
    the drive and makes the next scan find it locked."""
    _run(["bash", "-c", 'source "$0"; home_drive_scan_cleanup', str(helper_path())])


def scan(username: str, password: str, target: Path | None, excluded: list[str | None] = ()) -> str:
    """home_drive_scan's rows for this machine, leaving out the disks the
    install is on and the boot medium, and checking owners against the
    accounts of the image written to target. Before the image is written
    there is no target: the caller names the install disks (nothing is
    mounted there yet) and only the helper's static rules apply, since
    whatever account files sit under the target are not the image's."""
    scan_cleanup()
    # lsblk's names, which the helper compares against: a config may name a
    # disk by a /dev/disk/by-id link.
    excluded = [os.path.realpath(d) for d in excluded if d]
    if target is not None:
        excluded += _disks_under(target)
    excluded += _disks_under(Path("/run/archiso/bootmnt"))
    # The password goes through the environment, never on a command line.
    env = dict(os.environ,
               HOME_DRIVE_SECRET=password,
               HOME_DRIVE_PASSWD=str(target / "etc/passwd") if target is not None else "",
               HOME_DRIVE_GROUP=str(target / "etc/group") if target is not None else "")
    result = subprocess.run(
        ["bash", "-c", 'source "$0"; home_drive_scan "$1" "$HOME_DRIVE_SECRET" "${@:2}"', str(helper_path()),
         username, *excluded],
        capture_output=True, text=True, env=env,
    )
    if result.returncode != 0:
        raise RuntimeError(f"home drive: scanning failed: {result.stderr.strip()}")
    return result.stdout


def _rows(output: str) -> list[list[str]]:
    # Fifteen fields per row; trailing empty ones are padded back (an older
    # helper prints fourteen, without dir).
    return [(line.split("\t") + [""] * 15)[:15] for line in output.splitlines() if line.strip()]


def validate_home(home: dict, target: Path | None, username: str, password: str, home_password: str | None,
                  excluded: list[str | None] = ()) -> None:
    """Refuse a home choice the drive no longer supports. With no target
    (before the image is written) the owner is held to the static rules
    only; scan says why."""
    # Both: a passphrase typed for this drive, and the user's password.
    passwords = "\n".join(p for p in (home_password, password) if p)
    rows = _rows(scan(username, passwords, target=target, excluded=excluded))
    if home["mode"] == "fresh":
        disk = os.path.realpath(home["disk"])
        if not any(r[0] == "erasable" and r[2] == disk for r in rows):
            raise RuntimeError(f"home drive: {home['disk']} cannot be erased for a fresh home")
        return

    device = os.path.realpath(home["device"])
    for r in rows:
        if r[0] == "locked" and r[2] == device:
            raise RuntimeError(f"home drive: no passphrase given opens the home on {home['device']}")
        if r[1] != "home" or r[2] != device or r[6] != home["subvol"] or r[14] != home["dir"]:
            continue
        if r[0] == "refused":
            raise RuntimeError(f"home drive: the home on {home['device']} can no longer be adopted: {r[13]}")
        if (r[0] == "adoptable" and r[3] == home["fstype"] and r[4] == home["uuid"] and r[5] == home["luks_uuid"]
                and r[7] == str(home["uid"]) and r[8] == str(home["gid"])):
            return
    raise RuntimeError(f"home drive: the home on {home['device']} changed since it was chosen")


MAPPER = "home"


def chosen(ctx) -> dict | None:
    """omarchy_install.home as parsed into the context, or None."""
    omarchy_install = getattr(ctx, "omarchy_install", None)
    home = omarchy_install.get("home") if isinstance(omarchy_install, dict) else None
    return home if isinstance(home, dict) else None


def _run(cmd: list[str], **kwargs) -> str:
    result = subprocess.run(cmd, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        # The program and its error only: arguments and input may hold a passphrase.
        raise RuntimeError(f"home drive: {cmd[0]} {cmd[1] if len(cmd) > 1 else ''} failed: "
                           f"{(result.stderr or '').strip()}")
    return result.stdout or ""


def _query(cmd: list[str]) -> str:
    return (subprocess.run(cmd, capture_output=True, text=True).stdout or "").strip()


def _passwords(ctx) -> tuple[str, str]:
    """The install's LUKS passphrase (the user's password on encrypted
    installs; an autoinstall config may carry it in disk_config instead) and
    the home drive's own, if one was recorded."""
    creds = ctx.user_credentials
    disk_encryption = ((getattr(ctx, "user_configuration", None) or {}).get("disk_config") or {}).get("disk_encryption") or {}
    password = creds.get("encryption_password") or disk_encryption.get("encryption_password") or ""
    return password, creds.get("home_encryption_password") or ""


def install_disks(user_configuration: dict) -> list[str]:
    """The disks the configurator JSON lays the install out on."""
    return [m.get("device") for m in (user_configuration.get("disk_config") or {}).get("device_modifications") or []
            if m.get("device")]


def check_not_on_install_disks(home: dict, install_disks: list[str]) -> None:
    """Refuse, before anything is erased, a home on a disk the install
    overwrites: an autoinstall config could ask for one. Compared by
    canonical path, so a /dev/disk/by-id link on either side cannot slip a
    disk past it."""
    if home["mode"] == "fresh":
        disks = [os.path.realpath(home["disk"])]
    else:
        tree = subprocess.run(["lsblk", "-nsrpo", "NAME,TYPE", home["device"]], capture_output=True, text=True).stdout
        disks = [line.split()[0] for line in tree.splitlines() if line.split()[1:2] == ["disk"]]
    if set(disks) & set(os.path.realpath(d) for d in install_disks if d):
        raise RuntimeError(f"home drive: {', '.join(disks)} is the install disk, which the install erases")


def check_before_erase(ctx) -> None:
    """The checks that need no written image, run before any disk is erased
    (prepare_live): the drive still holds the chosen home with the same ids
    and a regular owner, and a typed passphrase or the password opens it; or
    the disk for a fresh home is still erasable (internal, and neither the
    install disk nor the boot medium). prepare_home checks the owner against
    the image's accounts once it is written; failing there costs a wiped
    install disk, so all that can fail without the image fails here."""
    home = chosen(ctx)
    if not home:
        return
    password, home_password = _passwords(ctx)
    username = ctx.user_credentials["users"][0]["username"]
    validate_home(home, None, username, password, home_password or None,
                  excluded=install_disks(getattr(ctx, "user_configuration", None) or {}))


def _claim_mapper(home: dict) -> bool:
    """Whether MAPPER is already open for the chosen home (a failed install
    before this one may have left it open). A mapping of any other drive by
    that name is never taken for the home: one nothing uses is a leftover and
    is closed, one in use is someone else's and stops the install."""
    status = subprocess.run(["cryptsetup", "status", MAPPER], capture_output=True, text=True)
    if status.returncode != 0:
        return False
    lines = status.stdout.splitlines()
    open_device = next((line.split()[1] for line in lines if line.split()[:1] == ["device:"]), "")
    # By device, not by LUKS UUID: a cloned drive carries the same one.
    if (home["mode"] == "adopt" and home["luks_uuid"] and open_device
            and os.path.realpath(open_device) == os.path.realpath(home["device"])):
        return True
    if lines and "in use" in lines[0]:
        raise RuntimeError(f"home drive: {MAPPER} is already open for {open_device}, not the chosen home")
    _run(["cryptsetup", "close", MAPPER])
    return False


def _adopt(ctx, home: dict, home_password: str, password: str, already_open: bool) -> None:
    device = home["device"]
    if home["luks_uuid"]:
        # The device the scan validated is the LUKS volume itself, and it is
        # opened as that, never as UUID=: a cloned drive carries the same LUKS
        # UUID, and opening by it could open the clone instead.
        if _query(["blkid", "-o", "value", "-s", "TYPE", device]) != "crypto_LUKS":
            raise RuntimeError(f"home drive: {device} is not the encrypted home that was chosen")
        if not already_open:
            _run(["cryptsetup", "open", "--key-file=-", device, MAPPER], input=home_password or password)
        device = f"/dev/mapper/{MAPPER}"
    options = []
    if home["subvol"]:
        options.append(f"subvol={home['subvol']}")
    elif home["fstype"] == "btrfs":
        # The top level itself, not whatever the default subvolume is.
        options.append("subvolid=5")
    if home["dir"]:
        # A home inside another system: only its home folder becomes /home,
        # and the rest of that system stays out of reach.
        options.append(f"X-mount.subdir={home['dir']}")
    _run(["mount", *(["-o", ",".join(options)] if options else []), device, str(ctx.target / "home")])


def _partitions(disk: str) -> list[str]:
    return [line.split()[0] for line in _query(["lsblk", "-nrpo", "NAME,TYPE", disk]).splitlines()
            if line.split()[1:2] == ["part"]]


def _fresh(ctx, home: dict, password: str, encrypted: bool) -> None:
    disk = home["disk"]
    if encrypted and not password:
        # Never an unencrypted home on an encrypted install.
        raise RuntimeError("home drive: the install is encrypted but there is no passphrase for the home disk")
    top = ctx.state_dir / "home-top"
    opened = mounted = False
    try:
        # Every old partition's signatures go before the table does: an md
        # superblock or LVM label left on one is all udev needs to assemble it
        # again when the new table is read (prepare_live released the holders).
        for part in _partitions(disk):
            _run(["wipefs", "--all", "--force", part])
        _run(["wipefs", "--all", "--force", disk])
        _run(["parted", "-s", disk, "mklabel", "gpt", "mkpart", "home", "1MiB", "100%"])
        _run(["partprobe", disk])
        _run(["udevadm", "settle"])
        parts = _partitions(disk)
        if not parts:
            raise RuntimeError(f"home drive: no partition appeared on {disk}")
        device = parts[0]
        luks_uuid = ""
        if encrypted:
            _run(["cryptsetup", "luksFormat", "--type", "luks2", "--batch-mode", "--key-file=-", device],
                 input=password)
            _run(["cryptsetup", "open", "--key-file=-", device, MAPPER], input=password)
            opened = True
            luks_uuid = _query(["blkid", "-o", "value", "-s", "UUID", device])
            device = f"/dev/mapper/{MAPPER}"
        _run(["mkfs.btrfs", "-f", "-L", "OMARCHY_HOME", device])
        top.mkdir(parents=True, exist_ok=True)
        _run(["mount", device, str(top)])
        mounted = True
        _run(["btrfs", "subvolume", "create", str(top / "@home")])
        _run(["umount", str(top)])
        mounted = False
        _run(["mount", "-o", "noatime,compress=zstd,subvol=@home", device, str(ctx.target / "home")])
    except BaseException:
        # Let go of what this opened, or the next attempt finds home-top
        # mounted and the mapping held. The failure itself is what is raised.
        if mounted:
            subprocess.run(["umount", str(top)], capture_output=True)
        if opened:
            subprocess.run(["cryptsetup", "close", MAPPER], capture_output=True)
        raise
    home.update(uuid=_query(["blkid", "-o", "value", "-s", "UUID", device]), fstype="btrfs",
                subvol="@home", luks_uuid=luks_uuid, dir="")


def prepare_home(ctx, encrypted: bool) -> None:
    """Check the chosen home drive again, then mount it at the target's /home:
    an adopted home as it is, or a disk erased and made into a fresh one
    (btrfs with an @home subvolume, LUKS when the install is encrypted, as the
    root is). Runs after the root image is written, so the image's own @home
    stays underneath and the image's accounts are what the owner is checked
    against. encrypted is whether the install is, as the caller works it out
    from the disk config and not only the optional encrypt flag file."""
    home = chosen(ctx)
    if not home:
        return
    password, home_password = _passwords(ctx)
    username = ctx.user_credentials["users"][0]["username"]
    validate_home(home, ctx.target, username, password, home_password or None)
    already_open = _claim_mapper(home)
    if home["mode"] == "adopt":
        _adopt(ctx, home, home_password, password, already_open)
    else:
        _fresh(ctx, home, password, encrypted)


def home_fstab_entries(ctx, root_encrypted: bool) -> None:
    """Point the target's fstab (and crypttab, for an encrypted home) at the
    home drive, through the shared helper first-boot setup and factory reset
    also use."""
    home = chosen(ctx)
    if not home:
        return
    password, home_password = _passwords(ctx)
    _run(["bash", "-c", 'source "$0"; home_drive_mount_entries "$@" "$HOME_DRIVE_SECRET"', str(helper_path()),
          str(ctx.target), home["uuid"], home["fstype"], home["subvol"], home["luks_uuid"],
          "true" if root_encrypted else "false", home["dir"]],
         env=dict(os.environ, HOME_DRIVE_SECRET=home_password or password))


def _adopted(ctx) -> dict | None:
    home = chosen(ctx)
    return home if home and home["mode"] == "adopt" else None


class AdoptedUserPlugin:
    """archinstall plugin: creates the user of an adopted home with the uid and
    gid that already own it, and without copying the skel over it.
    archinstall's own useradd -m would take the next free uid; returning True
    from on_user_create replaces only that step, so the password, groups and
    sudo are still archinstall's."""

    def __init__(self, target: Path, username: str, uid: int, gid: int):
        self.target, self.username, self.uid, self.gid = target, username, uid, gid

    def on_user_create(self, installer, user) -> bool:
        if user.username != self.username:
            return False
        group = "users"
        if self.gid != 100:
            _run(["arch-chroot", str(self.target), "groupadd", "-g", str(self.gid), self.username])
            group = str(self.gid)
        cmd = ["arch-chroot", str(self.target), "useradd", "-M", "-u", str(self.uid), "-g", group]
        if user.sudo:
            cmd += ["-G", "wheel"]
        _run(cmd + ["-s", "/bin/bash", "--", self.username])
        return True


def register_adopted_user(ctx, plugins: dict | None = None) -> None:
    """Hand the adopted home's user to AdoptedUserPlugin before archinstall
    creates users."""
    home = _adopted(ctx)
    if not home:
        return
    if plugins is None:
        from archinstall.lib.plugins import plugins
    plugins["omarchy-adopted-home"] = AdoptedUserPlugin(
        ctx.target, ctx.user_credentials["users"][0]["username"], home["uid"], home["gid"])


# home_drive_merge's exit status when it completed but could not copy some
# defaults (recorded as failed-copy lines in the home's adopted-home record).
MERGE_INCOMPLETE = 3


def merge_home(ctx) -> None:
    """Bring Omarchy's defaults into the adopted home as its owner: the
    user's files win (home-drive.sh's home_drive_merge). Run inside the
    target, so every absolute link in the home (a symlinked ~/.config too)
    resolves there and not on the live ISO; the helper's code goes in on
    stdin, so the target need not carry it."""
    home = _adopted(ctx)
    if not home:
        return
    username = ctx.user_credentials["users"][0]["username"]
    script = helper_path().read_text() + '\nhome_drive_merge "$1" "$2"\n'
    cmd = ["arch-chroot", str(ctx.target), "setpriv", f"--reuid={home['uid']}", f"--regid={home['gid']}",
           "--clear-groups", "bash", "-s", "--", "/etc/skel", f"/home/{username}"]
    result = subprocess.run(cmd, input=script, capture_output=True, text=True)
    if result.returncode == MERGE_INCOMPLETE:
        # The merge finished, but some defaults are not in the home (a file
        # of the user's in the way, a folder it cannot write). The home is
        # the user's and works without them, so this is no reason to fail the
        # install; the log and the home's own record say which.
        error("home drive: some of Omarchy's defaults could not be copied into the adopted home "
              "(failed-copy lines in ~/.local/state/omarchy/adopted-home)")
        for line in (result.stderr or "").splitlines():
            info(f"  {line}")
    elif result.returncode != 0:
        # The program and its error only, as _run reports it.
        raise RuntimeError(f"home drive: {cmd[0]} {cmd[1]} failed: {(result.stderr or '').strip()}")


def setup_env(ctx) -> list[str]:
    """Environment for Omarchy's user setup: an adopted home keeps what its
    owner set up (omarchy-provision-user's OMARCHY_ADOPTED_HOME)."""
    return ["OMARCHY_ADOPTED_HOME=1"] if _adopted(ctx) else []
