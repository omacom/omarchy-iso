"""Unit tests for Try Omarchy initramfs hook, Try layer build, dedup, and ISO gates."""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOOK = ROOT / "configs/airootfs/etc/initcpio/hooks/omarchy_try"
TRY_LAYER = ROOT / "builder/build-try-layer.sh"
BUILD_ISO = ROOT / "builder/build-iso.sh"
DEDUP = ROOT / "builder/dedup-airootfs.sh"
SHIM = ROOT / "builder/mksquashfs-shim/mksquashfs"


class OmarchyTryHookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.bin = self.dir / "bin"
        self.bin.mkdir()
        self.log = self.dir / "calls.log"
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "LOG": str(self.log),
        }

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f"#!/bin/sh\n{body}\n")
        path.chmod(0o755)

    def run_hook_fn(self, script):
        return subprocess.run(
            ["sh", "-c", f'. "{HOOK}"\n{script}'],
            env=self.env,
            capture_output=True,
            text=True,
        )

    def test_boot_failed_quits_plymouth_before_shell(self):
        self.stub("plymouth", 'echo "plymouth $*" >>"$LOG"; exit 0')
        self.stub("reboot", 'echo "reboot $*" >>"$LOG"; exit 0')
        res = self.run_hook_fn(
            'err() { echo "err $*" >>"$LOG"; }\n'
            'launch_interactive_shell() { echo "shell" >>"$LOG"; }\n'
            'boot_failed "boom"'
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(
            calls,
            [
                "plymouth --ping",
                "plymouth --wait quit",
                "err Omarchy: boom. Nothing has been installed; the machine restarts when you leave this shell.",
                "shell",
                "reboot -f",
            ],
        )

    def test_boot_failed_skips_plymouth_quit_when_not_running(self):
        self.stub("plymouth", 'echo "plymouth $*" >>"$LOG"; [ "$1" = "--ping" ] && exit 1; exit 0')
        self.stub("reboot", 'echo "reboot $*" >>"$LOG"; exit 0')
        res = self.run_hook_fn(
            'err() { echo "err $*" >>"$LOG"; }\n'
            'launch_interactive_shell() { echo "shell" >>"$LOG"; }\n'
            'boot_failed "boom"'
        )
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log.read_text().splitlines()
        self.assertNotIn("plymouth --wait quit", calls)
        self.assertIn("shell", calls)

    def test_mount_image_falls_back_when_threads_multi_refused(self):
        self.stub("mkdir", 'echo "mkdir $*" >>"$LOG"; exit 0')
        self.stub(
            "mount",
            'echo "mount $*" >>"$LOG"\n'
            'case "$*" in *threads=multi*) exit 32 ;; esac\n'
            'exit 0',
        )
        self.stub("losetup", 'echo "losetup $*" >>"$LOG"; echo /dev/loop9')
        res = self.run_hook_fn('mount_image /medium/omarchy-root.sfs')
        self.assertEqual(res.returncode, 0, res.stderr)
        calls = self.log.read_text().splitlines()
        self.assertEqual(
            calls,
            [
                "mkdir -p /run/omarchy-root/sfs /run/omarchy-root/image",
                "mount -t squashfs -o ro,loop,threads=multi /medium/omarchy-root.sfs /run/omarchy-root/sfs",
                "mount -t squashfs -o ro,loop /medium/omarchy-root.sfs /run/omarchy-root/sfs",
                "losetup --find --show --read-only -- /run/omarchy-root/sfs/omarchy-root.img",
                "mount -t btrfs -o ro,subvol=omarchy-root /dev/loop9 /run/omarchy-root/image",
            ],
        )

    def test_mount_image_cleans_up_on_btrfs_failure(self):
        self.stub("mkdir", 'exit 0')
        self.stub(
            "mount",
            'echo "mount $*" >>"$LOG"\n'
            'case "$*" in *-t\\ btrfs*) exit 32 ;; esac\n'
            'exit 0',
        )
        self.stub(
            "losetup",
            'echo "losetup $*" >>"$LOG"\n'
            'case "$1" in -d) exit 0 ;; esac\n'
            'echo /dev/loop9',
        )
        self.stub("umount", 'echo "umount $*" >>"$LOG"; exit 0')
        res = self.run_hook_fn('mount_image /medium/omarchy-root.sfs')
        self.assertNotEqual(res.returncode, 0)
        calls = self.log.read_text().splitlines()
        self.assertIn("losetup -d /dev/loop9", calls)
        self.assertIn("umount /run/omarchy-root/sfs", calls)

    def test_try_t2_handles_empty_pci_glob_without_stderr(self):
        empty_pci = self.dir / "pci"
        empty_pci.mkdir()
        hook_text = HOOK.read_text().replace("/sys/bus/pci/devices", str(empty_pci))
        patched = self.dir / "omarchy_try"
        patched.write_text(hook_text)
        res = subprocess.run(
            ["sh", "-c", f'. "{patched}"\ntry_t2'],
            capture_output=True,
            text=True,
        )
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout, "")
        self.assertEqual(res.stderr, "")

    def test_live_overlay_sets_index_off(self):
        self.assertIn("workdir=/run/archiso/cowspace/${cow_directory}/workdir,index=off", HOOK.read_text())



if __name__ == "__main__":
    unittest.main()
