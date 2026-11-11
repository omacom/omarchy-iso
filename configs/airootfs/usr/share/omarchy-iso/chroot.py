"""Mount an existing installation for a chroot, owning only our mounts and mapping.

No installation or package operations happen here. arch-chroot supplies the API
filesystems and DNS; the installed fstab supplies boot and system data mounts.
"""

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import signal
import stat
import subprocess
import sys


OFFLINE_MIRROR = Path("/var/cache/omarchy/mirror/offline")
ROOT_FILESYSTEMS = {"btrfs", "ext4", "xfs"}
CHROOT_MOUNTS = {
    "/boot", "/boot/efi", "/efi", "/usr", "/var", "/var/log",
    "/var/cache", "/var/cache/pacman", "/var/cache/pacman/pkg",
    "/var/lib", "/var/lib/pacman", "/.snapshots",
}
LOCAL_FILESYSTEMS = ROOT_FILESYSTEMS | {"vfat", "fat", "msdos", "ext2", "ext3"}


class ChrootError(Exception):
    pass


def say(message):
    print(message, file=sys.stderr, flush=True)


def cancel(_signum, _frame):
    raise KeyboardInterrupt


def run(*args, capture=False, check=True):
    result = subprocess.run(
        [str(arg) for arg in args], text=True, check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if check and result.returncode:
        detail = f": {result.stderr.strip()}" if capture and result.stderr else ""
        raise ChrootError(f"{shlex.join(str(arg) for arg in args)} failed{detail}")
    return result


def devices():
    # Rescue environments may have no udev database yet, especially for the
    # mapper we just opened. Root can probe the actual filesystem signatures.
    probe = ["--properties-by", "blkid"] if os.geteuid() == 0 else []
    result = run("lsblk", *probe, "--json", "--paths", "--output",
                 "NAME,TYPE,FSTYPE,SIZE,LABEL,MOUNTPOINTS,RO", capture=True)
    return json.loads(result.stdout)["blockdevices"]


def walk_devices(nodes):
    for node in nodes:
        yield node
        yield from walk_devices(node.get("children", []))


def in_use(node):
    return any(any(child.get("mountpoints") or []) for child in walk_devices([node]))


def candidates(nodes):
    # Keep the installation and live medium apart. An unlocked but unmounted
    # LUKS container is offered through its mapper, not unlocked a second time.
    return [node for node in walk_devices(nodes)
            if node.get("fstype") in ROOT_FILESYSTEMS | {"crypto_LUKS"}
            and node.get("type") in {"part", "disk", "crypt", "lvm"}
            and not node.get("ro") and not in_use(node)
            and not (node.get("fstype") == "crypto_LUKS" and node.get("children"))]


def device_label(node):
    label = str(node.get("label") or "")
    label = "".join(c for c in label if c.isprintable())
    return f"{node['name']}  {node['size']}  {node['fstype']}  {label}".rstrip()


def choose_root(available):
    if not available:
        raise ChrootError("No unmounted Linux partitions found. Check lsblk -f; unmount any manually mounted installation first.")
    if not sys.stdin.isatty():
        raise ChrootError("Choose a partition with --root /dev/DEVICE (see omarchy-chroot --list).")
    say("Choose the root partition of the installation to chroot into:")
    for number, node in enumerate(available, 1):
        say(f"  {number}. {device_label(node)}")
    while True:
        say("Partition number (q to cancel):")
        answer = input().strip()
        if answer.lower() == "q":
            return None
        if answer.isdecimal() and 1 <= int(answer) <= len(available):
            return available[int(answer) - 1]["name"]
        say("Enter one of the listed numbers, or q.")


def mount_options(options):
    opts = options.split(",")
    if any(opt in {"bind", "rbind", "move", "remount", "loop", "_netdev"}
           or opt.startswith("loop=") for opt in opts):
        raise ChrootError("A chroot filesystem uses a bind, loop, or network mount. Mount this layout manually.")
    # Ignore boot-time policy while keeping filesystem options such as subvol,
    # compress and umask. Chroot mounts need to be writable for package hooks.
    opts = [opt for opt in opts if opt and opt not in {"ro", "rw", "noauto", "nofail"}
            and not opt.startswith(("x-", "x-systemd.", "comment="))]
    return ",".join(["rw", *opts])


class Chroot:
    def __init__(self, target, subvolume="@", offline=OFFLINE_MIRROR):
        self.target = Path(target).absolute()
        self.subvolume = subvolume
        self.offline = offline
        self.mounts = []
        self.mapping = None
        self.root_device = None

    def target_path(self, name):
        relative = PurePosixPath(name)
        if not relative.is_absolute() or ".." in relative.parts:
            raise ChrootError(f"Unsafe mount path {name!r}; inspect the installed fstab.")
        path = self.target
        for part in relative.parts[1:]:
            path /= part
            if path.is_symlink():
                raise ChrootError(f"{path} is a symlink; mount this layout manually.")
        return path

    def check_target(self):
        if self.target == Path("/") or self.target.resolve() != self.target:
            raise ChrootError("Use a separate mount directory without symlinks, such as --mountpoint /mnt.")
        mounts = json.loads(run("findmnt", "--json", "--list", "--output", "TARGET", capture=True).stdout)
        for mount in mounts["filesystems"]:
            path = Path(mount["target"])
            if path == self.target or self.target in path.parents:
                raise ChrootError(f"{path} is already mounted. Exit existing chroots and unmount it, or choose another --mountpoint.")
        if self.target.exists() and (not self.target.is_dir() or any(self.target.iterdir())):
            raise ChrootError(f"{self.target} is not an empty directory. Choose another --mountpoint.")
        self.target.mkdir(parents=True, exist_ok=True)

    def mount(self, source, destination, *options):
        destination.mkdir(parents=True, exist_ok=True)
        run("mount", *options, "--", source, destination)
        self.mounts.append(destination)

    def open_root(self, device, nodes):
        device = str(Path(device).resolve())
        node = next((node for node in candidates(nodes)
                     if str(Path(node["name"]).resolve()) == device), None)
        if node is None:
            raise ChrootError(f"{device} is not an available root partition. Run omarchy-chroot --list; mounted or read-only devices cannot be used.")
        if node["fstype"] == "crypto_LUKS":
            name = f"omarchy-chroot-{os.getpid()}"
            if Path(f"/dev/mapper/{name}").exists():
                raise ChrootError(f"Mapping {name} already exists; close it after unmounting its filesystems, then retry.")
            self.mapping = name
            say(f"Unlocking {device}. Enter the disk password at the cryptsetup prompt.")
            # cryptsetup owns the password prompt; no password reaches Python,
            # arguments, logs or a temporary key file.
            try:
                run("cryptsetup", "open", "--type", "luks", device, name)
            except ChrootError as error:
                raise ChrootError(f"{error}\nCheck the disk password and retry omarchy-chroot.") from error
            device = f"/dev/mapper/{name}"
        self.root_device = device
        fstype = run("blkid", "-s", "TYPE", "-o", "value", device, capture=True).stdout.strip()
        if fstype not in ROOT_FILESYSTEMS:
            raise ChrootError(f"Unlocked filesystem is {fstype or 'unknown'}, not Btrfs/ext4/XFS. For LVM inside LUKS, activate the volume group and rerun with --root pointing at its root logical volume.")
        opts = "ro"
        if fstype == "btrfs":
            if not self.subvolume or any(c in self.subvolume for c in ",\n\r"):
                raise ChrootError("Use --subvolume with a Btrfs subvolume name (normally @).")
            opts += f",subvol={self.subvolume}"
        say(f"Inspecting {device} at {self.target}…")
        try:
            self.mount(device, self.target, "-t", fstype, "-o", opts)
        except ChrootError as error:
            raise ChrootError(f"{error}\nCheck the root partition and Btrfs --subvolume (default: @).") from error
        if not self.target_path("/etc/fstab").is_file() or not self.target_path("/etc/pacman.conf").is_file():
            raise ChrootError("This is not an Arch/Omarchy root with /etc/fstab and /etc/pacman.conf. Check --root and --subvolume.")

    def mount_installation(self):
        result = run("findmnt", "--fstab", "--tab-file", self.target / "etc/fstab",
                     "--json", "--list", "--output", "SOURCE,TARGET,FSTYPE,OPTIONS", capture=True)
        entries = json.loads(result.stdout).get("filesystems", [])
        root = next((entry for entry in entries if entry["target"] == "/"), None)
        if root is None:
            raise ChrootError("The installed fstab has no root entry. Inspect it before entering the chroot.")
        plan = []
        seen = set()
        nodes = list(walk_devices(devices()))
        for entry in sorted(entries, key=lambda e: (e["target"].count("/"), e["target"])):
            name = entry["target"]
            if name not in CHROOT_MOUNTS:
                continue
            if name in seen:
                raise ChrootError(f"Duplicate {name} entries in fstab; resolve them before entering the chroot.")
            seen.add(name)
            if entry["fstype"] not in LOCAL_FILESYSTEMS:
                raise ChrootError(f"{name} uses {entry['fstype']}, which needs manual mounting before entering the chroot.")
            source = entry["source"]
            if source == root["source"]:
                source = self.root_device
            elif source.startswith(("UUID=", "PARTUUID=", "LABEL=", "PARTLABEL=")):
                source = run("findfs", source, capture=True).stdout.strip()
            if not source.startswith("/dev/") or not stat.S_ISBLK(Path(source).stat().st_mode):
                raise ChrootError(f"Cannot resolve {entry['source']} for {name}. Check lsblk -f and the installed fstab.")
            if Path(source).resolve() != Path(self.root_device).resolve():
                node = next((node for node in nodes if Path(node["name"]).resolve() == Path(source).resolve()), None)
                if node is None or node.get("ro") or in_use(node):
                    raise ChrootError(f"{source} for {name} is mounted elsewhere or unavailable. Unmount it first; existing mounts are left alone.")
            plan.append((source, name, entry["fstype"], mount_options(entry.get("options") or "defaults")))
        run("mount", "-o", "remount,rw", "--", self.target)
        for source, name, fstype, options in plan:
            say(f"Mounting {name} from {source}…")
            self.mount(source, self.target_path(name), "-t", fstype, "-o", options)
        if not self.target_path("/var/lib/pacman/local").is_dir():
            raise ChrootError("The installed pacman database is missing. Check that this is the installed root and that /var is mounted.")
        if self.offline is not None:
            if self.offline.is_dir():
                destination = self.target_path(str(OFFLINE_MIRROR))
                self.mount(self.offline, destination, "--bind")
                run("mount", "-o", "remount,bind,ro", "--", destination)
                say(f"ISO packages are available at {OFFLINE_MIRROR} (read-only).")
            else:
                say(f"No ISO package mirror found at {self.offline}; the installed package cache is still available.")

    def shell(self, command):
        say("\nChroot shell ready. Commands now operate on the installed system.")
        say("Installed kernel packages: pacman -Q | grep '^linux'")
        say("Cached packages: /var/cache/pacman/pkg")
        say("uname -r still reports the live ISO kernel. Choose packages for the installed hardware.")
        say("Type exit when finished; chroot mounts will be unmounted automatically.\n")
        # Ctrl-C belongs to the chroot shell, not our cleanup handler. A caught
        # handler is reset to the default by exec in the arch-chroot child.
        previous = signal.signal(signal.SIGINT, lambda *_: None)
        try:
            code = run("arch-chroot", self.target, *command, check=False).returncode
            return code if code >= 0 else 128 - code
        finally:
            signal.signal(signal.SIGINT, previous)

    def cleanup(self):
        success = True
        for path in reversed(self.mounts):
            if run("umount", "--", path, check=False).returncode:
                say(f"Could not unmount {path}. Exit any shell using it, then run: umount {shlex.quote(str(path))}")
                success = False
        if self.mapping and Path(f"/dev/mapper/{self.mapping}").exists():
            if success:
                success = run("cryptsetup", "close", self.mapping, check=False).returncode == 0
            if not success:
                say(f"The disk remains unlocked. After unmounting it, run: cryptsetup close {self.mapping}")
        return success


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="omarchy-chroot",
        description="Unlock and mount an installed Omarchy system, make the ISO's offline packages available, and open a chroot shell. Clean up mounts on exit.",
        epilog="Use an ISO that boots on this hardware. No packages are installed automatically. Exit codes: 0 success, 1 chroot failure, 2 usage error, 130 cancelled; otherwise the chroot command's exit code.",
    )
    parser.add_argument("--root", metavar="DEVICE", help="installed root partition; otherwise choose interactively")
    parser.add_argument("--mountpoint", default="/mnt", metavar="PATH", help="empty directory for the installed system (default: /mnt)")
    parser.add_argument("--subvolume", default="@", metavar="NAME", help="Btrfs root subvolume (default: @; use / for the top level)")
    parser.add_argument("--no-offline", action="store_true", help="do not expose the live ISO's offline packages")
    parser.add_argument("--list", action="store_true", help="list available root partitions without mounting anything")
    parser.add_argument("--json", action="store_true", help="output --list as JSON")
    parser.add_argument("command", nargs=argparse.REMAINDER, help="command after -- to run instead of a chroot shell")
    args = parser.parse_args(argv)
    if args.json and not args.list:
        parser.error("--json requires --list")
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    session = None
    status = 1
    handlers = {sig: signal.signal(sig, cancel) for sig in (signal.SIGTERM, signal.SIGHUP)}
    try:
        nodes = devices()
        available = candidates(nodes)
        if args.list:
            if args.json:
                print(json.dumps(available))
            else:
                print("\n".join(device_label(node) for node in available) or "No unmounted Linux partitions found.")
            return 0
        if os.geteuid() != 0:
            raise ChrootError("Run as root from the live ISO: sudo omarchy-chroot")
        device = args.root or choose_root(available)
        if device is None:
            return 0
        if not command and not sys.stdin.isatty():
            raise ChrootError("A chroot shell needs a terminal. For scripting, supply --root DEVICE -- COMMAND.")
        session = Chroot(args.mountpoint, args.subvolume, None if args.no_offline else OFFLINE_MIRROR)
        session.check_target()
        session.open_root(device, nodes)
        session.mount_installation()
        status = session.shell(command or ["/bin/bash"])
    except (KeyboardInterrupt, EOFError):
        say("\nChroot cancelled.")
        status = 130
    except (ChrootError, OSError, ValueError) as error:
        say(f"Chroot failed: {error}")
    finally:
        try:
            if session is not None and not session.cleanup():
                status = 1
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
    return status
