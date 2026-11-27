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
        self.t._write_workqueue_cache.clear()
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

    def test_decision_is_cached_per_resolved_device_and_override_still_wins(self):
        calls = []
        base = fake_run()

        def counting_run(cmd):
            calls.append(cmd)
            return base(cmd)

        alias = self.dev.with_name("by-uuid-alias")
        alias.symlink_to(self.dev)
        with mock.patch.object(self.t, "run", counting_run), \
             mock.patch.object(self.t, "_cpu_has_aes", lambda: True):
            self.assertTrue(self.t.bypass_write_workqueue(str(self.dev)))
            self.assertEqual(len(calls), 3)
            self.assertTrue(self.t.bypass_write_workqueue(str(alias)))
            self.assertEqual(len(calls), 3)
            os.environ[self.t.WRITE_WORKQUEUE_ENV] = "keep"
            self.assertFalse(self.t.bypass_write_workqueue(str(self.dev)))
            self.assertEqual(len(calls), 3)

    def test_repeated_with_cmdline_options_is_idempotent_without_blkid(self):
        uuid = "00000000-1111-2222-3333-444444444444"
        os.environ[self.t.WRITE_WORKQUEUE_ENV] = "bypass"
        once = self.t.with_cmdline_options(
            f"cryptdevice=UUID={uuid}:omarchy_root root=/dev/mapper/omarchy_root rw")
        with mock.patch.object(self.t, "_luks_uuid_of", side_effect=AssertionError("unexpected lookup")):
            twice = self.t.with_cmdline_options(once)
        self.assertEqual(twice, once)

    def test_probe_errors_keep_queue_without_caching(self):
        base = fake_run()

        def bad_virt(cmd):
            if cmd[0] == "systemd-detect-virt":
                raise subprocess.CalledProcessError(1, cmd, output=b"")
            return base(cmd)

        def bad_lsblk(cmd):
            if cmd[0] == "lsblk":
                raise subprocess.CalledProcessError(1, cmd, output=b"")
            return base(cmd)

        with mock.patch.object(self.t, "_cpu_has_aes", lambda: True):
            with mock.patch.object(self.t, "run", bad_virt):
                self.assertFalse(self.t.bypass_write_workqueue(str(self.dev)))
            with mock.patch.object(self.t, "run", bad_lsblk):
                self.assertFalse(self.t.bypass_write_workqueue(str(self.dev)))
            with mock.patch.object(self.t, "run", base):
                self.assertTrue(self.t.bypass_write_workqueue(str(self.dev)))

    def test_pre_mounted_writers_carry_write_workqueue_option(self):
        uuid = "00000000-1111-2222-3333-444444444444"
        btrfs_uuid = "11111111-2222-3333-4444-555555555555"
        os.environ[self.t.WRITE_WORKQUEUE_ENV] = "bypass"
        with orchestrator_module("phases_impl", {"archinstall.lib.command": {"run": run}}) as phases:
            target = Path(self.enterContext(tempfile.TemporaryDirectory()))
            (target / "etc").mkdir()
            import types
            ctx = types.SimpleNamespace(
                target=target,
                omarchy_install={"storage": {"luks_uuid": uuid, "root_mapper": "/dev/mapper/omarchy_root"}},
            )
            phases._write_pre_mounted_crypttab(ctx)
            crypttab = (target / "etc" / "crypttab.initramfs").read_text()
            self.assertIn(f"UUID={uuid}", crypttab)
            self.assertIn("luks,discard,no-read-workqueue,no-write-workqueue", crypttab)

            cmdline = phases._build_pre_mounted_cmdline(ctx, btrfs_uuid)
            self.assertIn(
                f"cryptdevice=UUID={uuid}:omarchy_root:allow-discards,no-read-workqueue,no-write-workqueue",
                cmdline,
            )
            expanded = sys.modules["orchestrator.luks_tuning"].with_cmdline_options(cmdline)
            self.assertIn(
                f"rd.luks.options={uuid}=discard,no-read-workqueue,no-write-workqueue",
                expanded,
            )


if __name__ == "__main__":
    unittest.main()
