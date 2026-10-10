"""Run the live DSP guard against disposable mount and device-tree fixtures."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class LiveDspTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.env = dict(os.environ, PATH=f"{self.tools}:{os.environ['PATH']}",
                        DSP_TEST_ROOT=str(self.root))
        script = (ROOT / "configs/aarch64/omarchy-live-dsp").read_text()
        # Redirect only filesystem paths, not the guard logic, into the fixture.
        for prefix in ("/proc/", "/sys/", "/run/"):
            script = script.replace(prefix, f"{self.root}{prefix}")
        self.script = self.root / "live-dsp"
        self.script.write_text(script)
        self.write("proc/device-tree/compatible", "lenovo,yoga-slim7x\0qcom,x1e80100\0")
        self.write("proc/cmdline", "archisobasedir=arch modprobe.blacklist=qcom_q6v5_pas\n")
        self.write("proc/swaps", "Filename\tType\tSize\tUsed\tPriority\n")
        self.ram = self.root / "run/archiso/copytoram"
        self.cow = self.root / "run/archiso/cowspace"
        self.lower = self.root / "run/archiso/airootfs"
        self.upper = self.cow / "persistent_/aarch64/upperdir"
        self.work = self.cow / "persistent_/aarch64/workdir"
        for directory in (self.ram, self.lower, self.upper, self.work):
            directory.mkdir(parents=True, exist_ok=True)
        self.image = self.ram / "airootfs.sfs"
        self.image.touch()
        self.write("sys/class/block/loop7/loop/backing_file", str(self.image) + "\n")
        self.mounts = {
            "-rn -M / -o SOURCE,FSTYPE": "airootfs overlay",
            "-rn -M / -o FS-OPTIONS": f"rw,lowerdir={self.lower},upperdir={self.upper},workdir={self.work}",
            f"-rn -M {self.ram} -o FSTYPE": "tmpfs",
            f"-rn -M {self.cow} -o FSTYPE": "tmpfs",
            f"-rn -M {self.lower} -o FSTYPE": "squashfs",
            f"-rn -M {self.lower} -o SOURCE": "/dev/loop7",
            f"-rn -T {self.image} -o TARGET,FSTYPE": f"{self.ram} tmpfs",
            f"-rn -T {self.upper} -o TARGET,FSTYPE": f"{self.cow} tmpfs",
            f"-rn -T {self.work} -o TARGET,FSTYPE": f"{self.cow} tmpfs",
            "-ern -o SOURCE": "proc\nsys\n/dev/loop7\nairootfs\ncowspace\ncopytoram",
        }
        self.stub("uname", '#!/bin/sh\necho "${DSP_TEST_ARCH:-aarch64}"\n')
        self.stub("findmnt", '''#!/usr/bin/env python3
import json, os, pathlib, sys
data = json.loads((pathlib.Path(os.environ["DSP_TEST_ROOT"]) / "mounts.json").read_text())
key = " ".join(sys.argv[1:])
if key not in data:
    sys.exit(1)
print(data[key])
''')
        self.stub("mountpoint", '#!/bin/sh\ntest "$2" = "${DSP_TEST_MOUNTED:-}"\n')
        self.stub("modprobe", '''#!/bin/sh
printf '%s\n' "$*" >> "$DSP_TEST_ROOT/modprobe.calls"
exit "${DSP_TEST_MODPROBE_STATUS:-0}"
''')

    def write(self, name, contents):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)
        return path

    def stub(self, name, contents):
        self.write(f"tools/{name}", contents).chmod(0o755)

    def run_guard(self, *args):
        self.write("mounts.json", json.dumps(self.mounts))
        return subprocess.run(["bash", str(self.script), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def assert_skipped(self, reason):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(reason, result.stdout)
        self.assertFalse((self.root / "modprobe.calls").exists())

    def test_ram_backed_live_root_loads_driver_once(self):
        result = self.run_guard()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "modprobe.calls").read_text(), "-v qcom_q6v5_pas\n")

    def test_check_mode_never_loads_driver(self):
        result = self.run_guard("--check")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.root / "modprobe.calls").exists())
        self.mounts["-rn -M / -o SOURCE,FSTYPE"] = "/dev/nvme0n1p2 btrfs"
        self.assertEqual(self.run_guard("--check").returncode, 1)
        self.assertFalse((self.root / "modprobe.calls").exists())

    def test_other_architecture_and_unvalidated_hardware_are_untouched(self):
        self.env["DSP_TEST_ARCH"] = "x86_64"
        self.assert_skipped("not ARM64")
        self.env["DSP_TEST_ARCH"] = "aarch64"
        self.write("proc/device-tree/compatible", "other,board\0qcom,x1e80100\0")
        self.assert_skipped("hardware has not been validated")
        (self.root / "proc/device-tree/compatible").unlink()
        self.assert_skipped("no device tree")

    def test_command_line_can_disable_startup(self):
        self.write("proc/cmdline", "archisobasedir=arch omarchy.live_dsp=0\n")
        self.assert_skipped("disabled on the kernel command line")

    def test_installed_root_and_disk_backed_layers_are_rejected(self):
        cases = [
            ("-rn -M / -o SOURCE,FSTYPE", "/dev/nvme0n1p2 btrfs", "not an archiso"),
            (f"-rn -M {self.ram} -o FSTYPE", "ext4", "no RAM copy"),
            (f"-rn -M {self.cow} -o FSTYPE", "ext4", "writable layer is not in RAM"),
            (f"-rn -M {self.lower} -o SOURCE", "/dev/sda1", "not a loop device"),
            (f"-rn -T {self.image} -o TARGET,FSTYPE", f"{self.image} ext4", "backed by storage"),
            (f"-rn -T {self.upper} -o TARGET,FSTYPE", f"{self.upper} ext4", "writable directory is not in RAM"),
            (f"-rn -T {self.work} -o TARGET,FSTYPE", f"{self.work} ext4", "writable directory is not in RAM"),
            ("-ern -o SOURCE", "/dev/loop7\n/dev/sda1", "another block device is mounted"),
        ]
        for key, value, reason in cases:
            with self.subTest(reason=reason, key=key):
                original = self.mounts[key]
                self.mounts[key] = value
                self.assert_skipped(reason)
                self.mounts[key] = original

    def test_absent_mounts_do_not_pass_as_ram(self):
        del self.mounts[f"-rn -M {self.ram} -o FSTYPE"]
        self.assert_skipped("no RAM copy")

    def test_extra_overlay_lower_layer_is_rejected(self):
        self.mounts["-rn -M / -o FS-OPTIONS"] = f"lowerdir={self.lower}:/media/usb,upperdir={self.upper},workdir={self.work}"
        self.assert_skipped("unexpected overlay lower layer")

    def test_disk_backed_loop_and_missing_image_are_rejected(self):
        disk_image = self.write("run/archiso/bootmnt/airootfs.sfs", "image")
        self.write("sys/class/block/loop7/loop/backing_file", str(disk_image))
        self.assert_skipped("backed by storage")
        disk_image.unlink()
        self.assert_skipped("unavailable loop backing file")

    def test_cow_symlink_cannot_escape_ram(self):
        self.upper.rmdir()
        disk_dir = self.root / "media/usb/upperdir"
        disk_dir.mkdir(parents=True)
        self.upper.symlink_to(disk_dir)
        self.assert_skipped("writable directory is not in RAM")

    def test_mounted_media_and_active_swap_are_rejected(self):
        for name in ("bootmnt", "img_dev"):
            self.env["DSP_TEST_MOUNTED"] = str(self.root / "run/archiso" / name)
            self.assert_skipped("installation media is still mounted")
        del self.env["DSP_TEST_MOUNTED"]
        self.write("proc/swaps", "Filename Type Size Used Priority\n/dev/sda3 partition 10 0 -2\n")
        self.assert_skipped("swap is active")

    def test_already_loaded_driver_is_not_reloaded(self):
        (self.root / "sys/module/qcom_q6v5_pas").mkdir(parents=True)
        self.assert_skipped("driver already loaded")

    def test_module_failure_is_not_hidden(self):
        self.env["DSP_TEST_MODPROBE_STATUS"] = "1"
        result = self.run_guard()
        self.assertEqual(result.returncode, 1)
        self.assertEqual((self.root / "modprobe.calls").read_text(), "-v qcom_q6v5_pas\n")


if __name__ == "__main__":
    unittest.main()
