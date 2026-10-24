"""Exercise chroot against a synthetic installed tree, without touching disks.

Only the privileged command boundary is replaced. Real files, path checks,
fstab planning, mount ownership and error unwinding run normally.
"""

import contextlib
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
import chroot


def node(name, fstype="btrfs", **kw):
    return {"name": name, "type": "part", "fstype": fstype, "size": "100G",
            "label": "", "ro": False, "mountpoints": [None], **kw}


def entry(source, target, fstype="btrfs", options="defaults"):
    return dict(source=source, target=target, fstype=fstype, options=options)


class ChrootTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.target = self.base / "mnt"
        self.offline = self.base / "offline"
        self.offline.mkdir()
        (self.offline / "kernel.pkg.tar.zst").write_text("iso package")
        self.session = chroot.Chroot(self.target, offline=self.offline)
        self.nodes = [node("/dev/root-part", "crypto_LUKS"), node("/dev/boot-part", "vfat")]
        self.entries = [
            entry("UUID=root", "/", options="rw,subvol=/@"),
            entry("UUID=root", "/var/cache/pacman/pkg", options="subvol=/@pkg"),
            entry("UUID=boot", "/boot", "vfat", "umask=0077"),
            entry("UUID=root", "/var/log", options="subvol=/@log"),
            entry("UUID=root", "/home", options="subvol=/@home"),
            entry("nas:/data", "/mnt/nas", "nfs"),
        ]
        self.calls = []
        self.mount_targets = []
        self.fstype = "btrfs"
        self.fail = lambda args: False
        self.chroot_status = 0
        self.mapping_exists = False
        self.root_is_valid = True
        self.log = io.StringIO()
        patches = [
            mock.patch.object(chroot, "run", side_effect=self.run_command),
            mock.patch.object(chroot, "devices", side_effect=lambda: self.nodes),
            mock.patch.object(chroot.os, "geteuid", return_value=0),
            mock.patch.object(chroot.sys.stdin, "isatty", return_value=True),
            mock.patch.object(Path, "stat", autospec=True, side_effect=self.path_stat),
            mock.patch.object(Path, "exists", autospec=True, side_effect=self.path_exists),
        ]
        self.real_stat = Path.stat
        self.real_exists = Path.exists
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        redirect = contextlib.redirect_stderr(self.log)
        redirect.__enter__()
        self.addCleanup(redirect.__exit__, None, None, None)

    def path_stat(self, path, *args, **kwargs):
        if str(path).startswith("/dev/mapper/omarchy-chroot-") and not self.mapping_exists:
            raise FileNotFoundError(str(path))
        if str(path).startswith("/dev/"):
            result = mock.Mock(st_mode=stat.S_IFBLK | 0o600)
            return result
        return self.real_stat(path, *args, **kwargs)

    def path_exists(self, path, *args, **kwargs):
        if str(path).startswith("/dev/mapper/omarchy-chroot-"):
            return self.mapping_exists
        return self.real_exists(path, *args, **kwargs)

    def run_command(self, *args, capture=False, check=True):
        args = tuple(str(arg) for arg in args)
        self.calls.append(args)
        if self.fail(args):
            if check:
                raise chroot.ChrootError(f"Injected failure: {args}")
            return subprocess.CompletedProcess(args, 1, "", "busy")
        output = ""
        if args[0] == "findmnt":
            mounts = self.entries if "--fstab" in args else [{"target": path} for path in self.mount_targets]
            output = json.dumps({"filesystems": mounts})
        elif args[0] == "findfs":
            output = "/dev/boot-part\n"
        elif args[0] == "blkid":
            output = self.fstype + "\n"
        elif args[:2] == ("cryptsetup", "open"):
            self.mapping_exists = True
        elif args[:2] == ("cryptsetup", "close"):
            self.mapping_exists = False
        elif args[0] == "mount" and args[-1] == str(self.target) and "remount,rw" not in args:
            (self.target / "etc").mkdir()
            if self.root_is_valid:
                (self.target / "etc/fstab").write_text("fixture: findmnt provides the parsed entries")
                (self.target / "etc/pacman.conf").touch()
                (self.target / "var/lib/pacman/local").mkdir(parents=True)
        elif args[0] == "arch-chroot":
            return subprocess.CompletedProcess(args, self.chroot_status, "", "")
        return subprocess.CompletedProcess(args, 0, output, "")

    def prepare(self):
        self.session.check_target()
        self.session.open_root("/dev/root-part", self.nodes)
        self.session.mount_installation()

    def main(self, *args):
        return chroot.main(["--root", "/dev/root-part", "--mountpoint", str(self.target), "--no-offline", *args])

    def test_encrypted_root_mounts_boot_and_cache_before_chroot(self):
        self.prepare()
        self.session.shell(["/bin/bash"])
        self.assertTrue(self.session.cleanup())
        mount_calls = [c for c in self.calls if c[0] == "mount"]
        self.assertIn("ro,subvol=@", mount_calls[0])
        targets = [c[-1] for c in mount_calls]
        self.assertLess(targets.index(str(self.target / "boot")), targets.index(str(self.target / "var/cache/pacman/pkg")))
        self.assertIn(("mount", "-t", "btrfs", "-o", "rw,subvol=/@pkg", "--",
                       self.session.root_device, str(self.target / "var/cache/pacman/pkg")), self.calls)
        mirror = str(self.target) + str(chroot.OFFLINE_MIRROR)
        self.assertIn(("mount", "--bind", "--", str(self.offline), mirror), self.calls)
        self.assertIn(("mount", "-o", "remount,bind,ro", "--", mirror), self.calls)
        self.assertNotIn(str(self.target / "home"), targets)
        self.assertNotIn(str(self.target / "mnt/nas"), targets)
        self.assertEqual([c[-1] for c in self.calls if c[0] == "umount"],
                         [str(p) for p in reversed(self.session.mounts)])
        self.assertEqual(self.calls[-1], ("cryptsetup", "close", self.session.mapping))

    def test_ext4_needs_no_subvolume_or_encryption_mapping(self):
        self.nodes[0]["fstype"] = self.fstype = "ext4"
        self.entries = [entry("UUID=root", "/", "ext4"), entry("UUID=boot", "/boot", "vfat")]
        self.prepare()
        self.assertIn(("mount", "-t", "ext4", "-o", "ro", "--", "/dev/root-part", str(self.target)), self.calls)
        self.session.cleanup()
        self.assertFalse(any(c[0] == "cryptsetup" for c in self.calls))

    def test_nested_boot_and_efi_mount_in_order(self):
        self.nodes.append(node("/dev/efi-part", "vfat"))
        self.entries = [entry("UUID=root", "/"), entry("/dev/efi-part", "/boot/efi", "vfat"),
                        entry("/dev/boot-part", "/boot", "ext4")]
        self.prepare()
        targets = [c[-1] for c in self.calls if c[0] == "mount"]
        self.assertLess(targets.index(str(self.target / "boot")), targets.index(str(self.target / "boot/efi")))

    def test_existing_target_mount_is_not_touched(self):
        self.mount_targets = [str(self.target / "boot")]
        self.assertEqual(self.main(), 1)
        self.assertIn("already mounted", self.log.getvalue())
        self.assertFalse(any(c[0] in {"mount", "umount", "cryptsetup", "arch-chroot"} for c in self.calls))

    def test_nonempty_directory_is_not_hidden(self):
        self.target.mkdir()
        (self.target / "important").touch()
        self.assertEqual(self.main(), 1)
        self.assertIn("not an empty directory", self.log.getvalue())
        self.assertTrue((self.target / "important").exists())

    def test_boot_failure_prevents_chroot_and_cleans_root(self):
        self.fail = lambda c: c[0] == "mount" and c[-1] == str(self.target / "boot")
        self.assertEqual(self.main(), 1)
        self.assertFalse(any(c[0] == "arch-chroot" for c in self.calls))
        self.assertEqual([c[-1] for c in self.calls if c[0] == "umount"], [str(self.target)])
        self.assertFalse(self.mapping_exists)

    def test_wrong_password_does_not_mount(self):
        self.fail = lambda c: c[:2] == ("cryptsetup", "open")
        self.assertEqual(self.main(), 1)
        self.assertFalse(any(c[0] in {"mount", "arch-chroot"} for c in self.calls))

    def test_invalid_root_is_unmounted_and_closed(self):
        self.root_is_valid = False
        self.assertEqual(self.main(), 1)
        self.assertIn("not an Arch/Omarchy root", self.log.getvalue())
        self.assertFalse(self.mapping_exists)

    def test_interrupt_cleans_successful_mounts(self):
        def interrupt(c):
            if c[0] == "findfs":
                raise KeyboardInterrupt
            return False
        self.fail = interrupt
        self.assertEqual(self.main(), 130)
        self.assertIn(("umount", "--", str(self.target)), self.calls)
        self.assertFalse(self.mapping_exists)

    def test_busy_mount_keeps_mapping_open_with_cleanup_instructions(self):
        self.prepare()
        self.fail = lambda c: c[0] == "umount"
        self.assertFalse(self.session.cleanup())
        self.assertTrue(self.mapping_exists)
        self.assertFalse(any(c[:2] == ("cryptsetup", "close") for c in self.calls))
        self.assertIn("cryptsetup close", self.log.getvalue())

    def test_termination_cleans_mounts_and_restores_signal_handler(self):
        previous = signal.getsignal(signal.SIGTERM)
        def terminate(c):
            if c[0] == "findfs":
                os.kill(os.getpid(), signal.SIGTERM)
            return False
        self.fail = terminate
        self.assertEqual(self.main(), 130)
        self.assertFalse(self.mapping_exists)
        self.assertEqual(signal.getsignal(signal.SIGTERM), previous)

    def test_already_unlocked_mapping_is_not_closed(self):
        self.nodes[0] = node("/dev/root-part", type="crypt")
        self.prepare()
        self.assertIsNone(self.session.mapping)
        self.session.cleanup()
        self.assertFalse(any(c[0] == "cryptsetup" for c in self.calls))

    def test_boot_mounted_elsewhere_is_not_reused(self):
        self.nodes[1]["mountpoints"] = ["/somewhere-else"]
        self.assertEqual(self.main(), 1)
        self.assertIn("mounted elsewhere", self.log.getvalue())
        self.assertFalse(any(c[0] == "arch-chroot" for c in self.calls))

    def test_symlinked_mountpoint_cannot_escape_installed_root(self):
        self.session.check_target()
        self.session.open_root("/dev/root-part", self.nodes)
        outside = self.base / "outside"
        outside.mkdir()
        (self.target / "boot").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(chroot.ChrootError, "symlink"):
            self.session.mount_installation()
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse(any(c[-1] == str(outside) for c in self.calls))

    def test_missing_mirror_still_allows_chroot(self):
        self.session.offline = self.base / "absent"
        self.prepare()
        self.assertIn("No ISO package mirror", self.log.getvalue())
        self.assertFalse(any("--bind" in c for c in self.calls))

    def test_shell_exit_status_is_preserved_and_cleanup_runs(self):
        self.chroot_status = 7
        self.assertEqual(self.main("--", "/bin/false"), 7)
        self.assertFalse(self.mapping_exists)
        self.assertIn(("arch-chroot", str(self.target), "/bin/false"), self.calls)

    def test_list_json_is_read_only(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(chroot.main(["--list", "--json"]), 0)
        self.assertEqual(json.loads(output.getvalue())[0]["name"], "/dev/root-part")
        self.assertEqual(self.calls, [])

    def test_noninteractive_selection_fails_without_mounting(self):
        with mock.patch.object(chroot.sys.stdin, "isatty", return_value=False):
            self.assertEqual(chroot.main([]), 1)
        self.assertIn("--root", self.log.getvalue())
        self.assertEqual(self.calls, [])


class DiscoveryTest(unittest.TestCase):
    def test_live_disk_mounted_descendants_and_readonly_media_are_excluded(self):
        mounted = node("/dev/used", mountpoints=["/mnt/elsewhere"])
        unlocked = node("/dev/luks", "crypto_LUKS", children=[node("/dev/mapper/root", type="crypt")])
        nodes = [node("/dev/live", type="disk", children=[mounted]),
                 node("/dev/loop0", type="loop"), node("/dev/readonly", ro=True), unlocked]
        self.assertEqual([n["name"] for n in chroot.candidates(nodes)], ["/dev/mapper/root"])

    def test_fstab_options_keep_filesystem_settings_but_mount_writable(self):
        self.assertEqual(chroot.mount_options("ro,noauto,nofail,x-systemd.device-timeout=0,subvol=/@pkg,compress=zstd"),
                         "rw,subvol=/@pkg,compress=zstd")
        with self.assertRaises(chroot.ChrootError):
            chroot.mount_options("bind")

    def test_helper_is_executable_and_in_iso_profile(self):
        helper = ROOT / "configs/airootfs/usr/local/bin/omarchy-chroot"
        result = subprocess.run([str(helper), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--root", result.stdout)
        self.assertIn('["/usr/local/bin/omarchy-chroot"]="0:0:755"', (ROOT / "configs/profiledef.sh").read_text())


if __name__ == "__main__":
    unittest.main()
