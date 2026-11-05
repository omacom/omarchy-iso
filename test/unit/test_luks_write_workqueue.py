"""The installed system bypasses dm-crypt's write workqueue only on an NVMe SSD,
with AES instructions, outside a VM, and the override wins over the checks.

Every condition is answered by a stubbed command or file, so the decision is
tested without real disks; the cmdline and crypttab writers then carry the same
options in their own spellings.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path
from unittest import mock
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from archinstall_fakes import orchestrator_module  # noqa: E402


def run(cmd):
    return subprocess.run(cmd, capture_output=True, check=True)


def fake_run(virt="none", pkname="nvme0n1", tran_rota="nvme 0"):
    """archinstall's run, answering the three commands the check uses."""
    def answer(cmd):
        if cmd[0] == "systemd-detect-virt":
            if virt == "none":
                raise subprocess.CalledProcessError(1, cmd, output=b"none\n")
            return subprocess.CompletedProcess(cmd, 0, stdout=f"{virt}\n".encode())
        if cmd[:3] == ["lsblk", "-ndo", "PKNAME"]:
            return subprocess.CompletedProcess(cmd, 0, stdout=f"{pkname}\n".encode())
        if cmd[:3] == ["lsblk", "-ndo", "TRAN,ROTA"]:
            return subprocess.CompletedProcess(cmd, 0, stdout=f"{tran_rota}\n".encode())
        raise AssertionError(f"unexpected command {cmd}")
    return answer


class WriteWorkqueueTest(unittest.TestCase):
    def setUp(self):
        self.t = self.enterContext(
            orchestrator_module("luks_tuning", {"archinstall.lib.command": {"run": run}}))
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.dev = tmp / "nvme0n1p2"  # stands in for the LUKS partition: it exists
        self.dev.write_text("")
        self.enterContext(mock.patch.dict(os.environ, {}, clear=False))
        os.environ.pop(self.t.WRITE_WORKQUEUE_ENV, None)

    def decide(self, aes=True, **answers):
        with mock.patch.object(self.t, "run", fake_run(**answers)), \
             mock.patch.object(self.t, "_cpu_has_aes", lambda: aes):
            return self.t.bypass_write_workqueue(str(self.dev))

    def test_nvme_ssd_with_aes_on_hardware_bypasses(self):
        self.assertTrue(self.decide())

    def test_a_vm_keeps_the_queue(self):
        self.assertFalse(self.decide(virt="kvm"))

    def test_no_aes_instructions_keeps_the_queue(self):
        self.assertFalse(self.decide(aes=False))

    def test_sata_and_usb_keep_the_queue(self):
        self.assertFalse(self.decide(tran_rota="sata 0"))
        self.assertFalse(self.decide(tran_rota="usb 0"))

    def test_a_rotating_disk_keeps_the_queue(self):
        self.assertFalse(self.decide(tran_rota="nvme 1"))

    def test_a_missing_device_keeps_the_queue(self):
        self.dev.unlink()
        self.assertFalse(self.decide())

    def test_the_override_wins_both_ways(self):
        os.environ[self.t.WRITE_WORKQUEUE_ENV] = "keep"
        self.assertFalse(self.decide())
        os.environ[self.t.WRITE_WORKQUEUE_ENV] = "bypass"
        self.assertTrue(self.decide(virt="kvm", aes=False, tran_rota="sata 1"))

    def test_cpuinfo_flags_and_arm_features(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        x86 = tmp / "x86"
        x86.write_text("processor\t: 0\nflags\t\t: fpu sse2 aes avx2\n")
        arm = tmp / "arm"
        arm.write_text("processor\t: 0\nFeatures\t: fp asimd aes pmull sha1\n")
        none = tmp / "none"
        none.write_text("processor\t: 0\nflags\t\t: fpu sse2 aesx\n")
        self.assertTrue(self.t._cpu_has_aes(x86))
        self.assertTrue(self.t._cpu_has_aes(arm))
        self.assertFalse(self.t._cpu_has_aes(none))

    def test_both_spellings_carry_the_option(self):
        os.environ[self.t.WRITE_WORKQUEUE_ENV] = "bypass"
        options = self.t.cmdline_options(str(self.dev))
        self.assertEqual(options, "allow-discards,no-read-workqueue,no-write-workqueue")
        self.assertEqual(self.t.crypttab_options(options),
                         "discard,no-read-workqueue,no-write-workqueue")

    def test_the_cmdline_gets_the_same_options_for_both_initramfs_flavours(self):
        uuid = "00000000-1111-2222-3333-444444444444"
        os.environ[self.t.WRITE_WORKQUEUE_ENV] = "bypass"
        cmdline = self.t.with_cmdline_options(
            f"cryptdevice=UUID={uuid}:omarchy_root root=/dev/mapper/omarchy_root rw")
        # A UUID= spec with no device present: the override still applies.
        self.assertIn(f"cryptdevice=UUID={uuid}:omarchy_root:"
                      "allow-discards,no-read-workqueue,no-write-workqueue", cmdline)
        self.assertIn(f"rd.luks.options={uuid}=discard,no-read-workqueue,no-write-workqueue",
                      cmdline)

    def test_without_the_bypass_the_cmdline_is_unchanged(self):
        uuid = "00000000-1111-2222-3333-444444444444"
        os.environ[self.t.WRITE_WORKQUEUE_ENV] = "keep"
        cmdline = self.t.with_cmdline_options(
            f"cryptdevice=UUID={uuid}:omarchy_root root=/dev/mapper/omarchy_root rw")
        self.assertIn(f"cryptdevice=UUID={uuid}:omarchy_root:allow-discards,no-read-workqueue ",
                      cmdline)
        self.assertIn(f"rd.luks.options={uuid}=discard,no-read-workqueue", cmdline)
        self.assertNotIn("no-write-workqueue", cmdline)


if __name__ == "__main__":
    unittest.main()
