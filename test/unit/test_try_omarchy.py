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


class BuildTryLayerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = TRY_LAYER.read_text()

    def test_enables_bluetooth_and_retires_networkd(self):
        self.assertRegex(self.text, r"sddm\.service\s+systemd-oomd\.service\s+bluetooth\.service")
        self.assertIn("systemd-networkd.service", self.text)
        self.assertIn("systemd-networkd-wait-online.service", self.text)

    def test_masks_disk_and_hibernate_units(self):
        for unit in (
            "systemd-hibernate-clear.service",
            "lvm2-monitor.service",
            "lvm2-lvmpolld.socket",
            "systemd-boot-random-seed.service",
            "snapper-timeline.timer",
            "limine-snapper-sync.service",
        ):
            self.assertIn(unit, self.text, f"{unit} should be masked in Try")

    def test_keyring_service_does_not_run_pacman_sy(self):
        m = re.search(
            r"omarchy-try-keyring\.service\" <<'EOF'\n(.*?)\nEOF",
            self.text,
            re.S,
        )
        self.assertIsNotNone(m)
        unit = m.group(1)
        self.assertIn("pacman-key --init && pacman-key --populate", unit)
        self.assertNotIn("pacman -Sy", unit)

    def test_isolates_build_host_hardware_during_user_provisioning(self):
        for stub in ("omarchy-hw-vm", "omarchy-hw-asus-rog", "omarchy-hw-match", "omarchy-hw-pci"):
            self.assertIn(stub, self.text)
        self.assertIn('for target in "$merged/usr/bin/$cmd" "$merged/usr/share/omarchy/bin/$cmd"; do', self.text)
        self.assertIn('[[ -f $target && ! -L $target ]]', self.text)
        self.assertIn("OMARCHY_PCI_DEVICES_PATH=/dev/null", self.text)
        self.assertIn("OMARCHY_NOUVEAU_DRIVER_PATH=/dev/null", self.text)

    def test_guards_nvidia_lua_when_proprietary_driver_absent(self):
        self.assertIn('io.open("/etc/modprobe.d/nvidia.conf", "r")', self.text)
        self.assertIn("no_hardware_cursors = true", self.text)

    def test_driver_layer_stubs_systemctl_on_pass_one_only(self):
        self.assertIn('printf \'#!/bin/sh\\nexit 0\\n\' >"$stubs/systemctl"', self.text)
        self.assertIn('rm -f "$stubs/systemctl"', self.text)

    def test_sets_utf8_locale_and_browser_policies(self):
        self.assertIn("LANG=en_US.UTF-8", self.text)
        self.assertIn("browser-policy.sh", self.text)
        self.assertIn("theme-system.sh", self.text)


class DedupAndBuildIsoTest(unittest.TestCase):
    def test_dedup_keeps_firmware_dbus_polkit_and_creates_missing_keep_dirs(self):
        text = DEDUP.read_text()
        for rel in ("usr/lib/firmware", "usr/share/dbus-1", "usr/share/polkit-1"):
            self.assertIn(f'"{rel}"', text)
        # Extract and run the embedded Python dedup logic on synthetic trees.
        py_src = re.search(r"python3 - .*?<<'PY'\n(.*?)\nPY", text, re.S).group(1)
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            live = tmp / "live"
            image = tmp / "image"
            pseudo = tmp / "pseudo"
            # Directory present in image and in KEEP, absent from live -> must become opaque!
            (image / "usr/lib/firmware/iwlwifi").mkdir(parents=True)
            (image / "usr/lib/firmware/iwlwifi/test.ucode").write_bytes(b"fw")
            (live / "etc").mkdir(parents=True)
            # Identical file outside KEEP -> must be deduplicated!
            (live / "usr/bin").mkdir(parents=True)
            (image / "usr/bin").mkdir(parents=True)
            (live / "usr/bin/same").write_bytes(b"hello")
            (image / "usr/bin/same").write_bytes(b"hello")
            (live / "usr/bin/diff").write_bytes(b"live-version")
            (image / "usr/bin/diff").write_bytes(b"image-version")

            res = subprocess.run(
                ["python3", "-c", py_src, str(live), str(image), str(pseudo)],
                capture_output=True,
                text=True,
                check=True,
            )
            self.assertFalse((live / "usr/bin/same").exists())
            self.assertTrue((live / "usr/bin/diff").exists())
            self.assertTrue((live / "usr/lib/firmware").is_dir())
            pseudo_lines = pseudo.read_text().splitlines()
            self.assertIn("/usr/lib/firmware x trusted.overlay.opaque=y", pseudo_lines)
            self.assertIn("/etc x trusted.overlay.opaque=y", pseudo_lines)
            self.assertTrue((live / "etc/omarchy-iso-live-over-image").is_file())

    def test_mksquashfs_shim_cleans_up_pseudo_file(self):
        shim_text = SHIM.read_text()
        self.assertIn('trap \'rm -f "$pseudo"\' EXIT', shim_text)
        self.assertNotIn('exec /usr/bin/mksquashfs "$@" -pf "$pseudo"', shim_text)


if __name__ == "__main__":
    unittest.main()
