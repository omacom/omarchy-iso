"""Unit tests for orchestrator.disk_udev (whole-disk resolution, flock_whole_disk,
nudge_if_disk_unlocked, and settle_disk watchdog)."""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import disk_udev  # noqa: E402


class WholeDiskBlockDeviceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.dev_root = self.tmp / "dev"
        self.dev_root.mkdir()
        self.sys_block = self.tmp / "sys_block"
        self.sys_block.mkdir()
        self.sys_devices = self.tmp / "sys_devices"
        self.sys_devices.mkdir()

    def test_returns_none_for_missing_or_non_block_paths(self):
        missing = self.dev_root / "nope"
        regular = self.dev_root / "regular"
        regular.write_bytes(b"")
        self.assertIsNone(disk_udev.whole_disk_block_device(missing, sys_block=self.sys_block, dev_root=self.dev_root))
        self.assertIsNone(disk_udev.whole_disk_block_device(regular, sys_block=self.sys_block, dev_root=self.dev_root))
        self.assertIsNone(disk_udev.whole_disk_block_device("/dev/null"))

    def test_resolves_whole_disk_and_symlink(self):
        disk = self.dev_root / "nvme0n1"
        disk.write_bytes(b"")
        link = self.dev_root / "by-id-disk"
        link.symlink_to(disk)

        with mock.patch.object(disk_udev.stat, "S_ISBLK", return_value=True):
            self.assertEqual(
                disk_udev.whole_disk_block_device(disk, sys_block=self.sys_block, dev_root=self.dev_root),
                disk.resolve(),
            )
            self.assertEqual(
                disk_udev.whole_disk_block_device(link, sys_block=self.sys_block, dev_root=self.dev_root),
                disk.resolve(),
            )

    def test_resolves_partition_to_parent_whole_disk(self):
        parent_dev = self.dev_root / "nvme0n1"
        part_dev = self.dev_root / "nvme0n1p2"
        parent_dev.write_bytes(b"")
        part_dev.write_bytes(b"")

        part_sys = self.sys_devices / "nvme0n1" / "nvme0n1p2"
        part_sys.mkdir(parents=True)
        (part_sys / "partition").write_text("2\n")
        (self.sys_block / "nvme0n1p2").symlink_to(part_sys)

        with mock.patch.object(disk_udev.stat, "S_ISBLK", return_value=True):
            resolved = disk_udev.whole_disk_block_device(
                part_dev, sys_block=self.sys_block, dev_root=self.dev_root,
            )
        self.assertEqual(resolved, parent_dev)

    def test_partition_falls_back_to_self_when_parent_missing(self):
        part_dev = self.dev_root / "vda1"
        part_dev.write_bytes(b"")

        part_sys = self.sys_devices / "vda" / "vda1"
        part_sys.mkdir(parents=True)
        (part_sys / "partition").write_text("1\n")
        (self.sys_block / "vda1").symlink_to(part_sys)

        with mock.patch.object(disk_udev.stat, "S_ISBLK", return_value=True):
            resolved = disk_udev.whole_disk_block_device(
                part_dev, sys_block=self.sys_block, dev_root=self.dev_root,
            )
        self.assertEqual(resolved, part_dev.resolve())


class NudgeIfDiskUnlockedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.fake_dev = self.tmp / "nvme0n1"
        self.fake_dev.write_bytes(b"")
        self.sys_block = self.tmp / "sys_block"
        (self.sys_block / "nvme0n1").mkdir(parents=True)
        self.uevent = self.sys_block / "nvme0n1" / "uevent"

    def test_writes_change_when_unlocked_using_o_rdonly(self):
        seen_flags = []
        real_open = os.open

        def record_open(path, flags, *args, **kwargs):
            seen_flags.append(flags)
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(disk_udev.os, "open", side_effect=record_open):
            nudged = disk_udev.nudge_if_disk_unlocked(
                self.fake_dev,
                whole_disk_fn=lambda _: self.fake_dev,
                sys_block=self.sys_block,
            )
        self.assertTrue(nudged)
        self.assertEqual(self.uevent.read_text(), "change\n")
        self.assertEqual(len(seen_flags), 1)
        self.assertEqual(seen_flags[0] & os.O_ACCMODE, os.O_RDONLY)
        self.assertTrue(seen_flags[0] & os.O_CLOEXEC)
        self.assertTrue(seen_flags[0] & os.O_NONBLOCK)

    def test_skips_when_shared_or_exclusive_locked(self):
        for lock_mode in (fcntl.LOCK_SH, fcntl.LOCK_EX):
            with self.subTest(lock_mode=lock_mode):
                self.uevent.unlink(missing_ok=True)
                holder = os.open(str(self.fake_dev), os.O_RDONLY)
                try:
                    fcntl.flock(holder, lock_mode)
                    nudged = disk_udev.nudge_if_disk_unlocked(
                        self.fake_dev,
                        whole_disk_fn=lambda _: self.fake_dev,
                        sys_block=self.sys_block,
                    )
                    self.assertFalse(nudged)
                    self.assertFalse(self.uevent.exists())
                finally:
                    os.close(holder)

    def test_skips_when_done_event_is_already_set(self):
        done = threading.Event()
        done.set()
        nudged = disk_udev.nudge_if_disk_unlocked(
            self.fake_dev,
            done,
            whole_disk_fn=lambda _: self.fake_dev,
            sys_block=self.sys_block,
        )
        self.assertFalse(nudged)
        self.assertFalse(self.uevent.exists())

    def test_returns_false_when_not_block_device_or_uevent_unwritable(self):
        self.assertFalse(
            disk_udev.nudge_if_disk_unlocked(
                self.fake_dev,
                whole_disk_fn=lambda _: None,
                sys_block=self.sys_block,
            )
        )
        missing_sys = self.tmp / "no_sys_block"
        self.assertFalse(
            disk_udev.nudge_if_disk_unlocked(
                self.fake_dev,
                whole_disk_fn=lambda _: self.fake_dev,
                sys_block=missing_sys,
            )
        )


class SettleDiskTests(unittest.TestCase):
    def test_empty_disk_runs_settle_directly_without_nudging(self):
        nudge = mock.Mock()
        result = disk_udev.settle_disk(None, lambda: "ok", nudge_fn=nudge)
        self.assertEqual(result, "ok")
        nudge.assert_not_called()

        result2 = disk_udev.settle_disk("", lambda: "ok2", nudge_fn=nudge)
        self.assertEqual(result2, "ok2")
        nudge.assert_not_called()

    def test_fast_settle_returns_value_with_zero_nudges(self):
        nudge = mock.Mock()
        result = disk_udev.settle_disk("/dev/nvme0n1", lambda: 42, delays=(0.5,), nudge_fn=nudge)
        self.assertEqual(result, 42)
        nudge.assert_not_called()

    def test_stranded_settle_nudges_once_unlocked_and_unblocks(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        fake_dev = tmp / "vda"
        fake_dev.write_bytes(b"")
        sys_block = tmp / "sys_block"
        (sys_block / "vda").mkdir(parents=True)
        uevent = sys_block / "vda" / "uevent"

        holder = os.open(str(fake_dev), os.O_RDONLY)
        try:
            fcntl.flock(holder, fcntl.LOCK_SH)
            attempts = []

            def track_nudge(path, done):
                res = disk_udev.nudge_if_disk_unlocked(
                    path,
                    done,
                    whole_disk_fn=lambda _: fake_dev,
                    sys_block=sys_block,
                )
                attempts.append(res)
                if len(attempts) == 1:
                    # Release lock after first probe saw LOCK_SH contention.
                    fcntl.flock(holder, fcntl.LOCK_UN)
                return res

            def stuck_settle():
                deadline = threading.Event()
                for _ in range(100):
                    if uevent.exists() and uevent.read_text() == "change\n":
                        return "unblocked"
                    deadline.wait(0.01)
                raise AssertionError("settle was never nudged")

            result = disk_udev.settle_disk(
                fake_dev,
                stuck_settle,
                delays=(0.01, 0.01, 0.05),
                nudge_fn=track_nudge,
            )
        finally:
            os.close(holder)

        self.assertEqual(result, "unblocked")
        self.assertEqual(attempts, [False, True])

    def test_settle_exception_propagates_and_stops_watchdog(self):
        nudges = []

        def fail_settle():
            raise RuntimeError("settle failed")

        with self.assertRaisesRegex(RuntimeError, "settle failed"):
            disk_udev.settle_disk(
                "/dev/nvme0n1",
                fail_settle,
                delays=(0.5,),
                nudge_fn=lambda p, d: nudges.append(p) or True,
            )
        self.assertEqual(nudges, [])


class FlockWholeDiskTests(unittest.TestCase):
    def test_holds_exclusive_lock_on_o_rdonly_fd_and_releases_on_exit(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        fake_dev = tmp / "nvme0n1"
        fake_dev.write_bytes(b"")

        seen_flags = []
        real_open = os.open

        def record_open(path, flags, *args, **kwargs):
            seen_flags.append(flags)
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(disk_udev.os, "open", side_effect=record_open):
            with disk_udev.flock_whole_disk(fake_dev, whole_disk_fn=lambda _: fake_dev):
                probe = real_open(str(fake_dev), os.O_RDONLY)
                try:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
                finally:
                    os.close(probe)

        # Lock is released after exiting the context manager.
        probe = real_open(str(fake_dev), os.O_RDONLY)
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(probe)

        self.assertEqual(len(seen_flags), 1)
        self.assertEqual(seen_flags[0] & os.O_ACCMODE, os.O_RDONLY)
        self.assertTrue(seen_flags[0] & os.O_CLOEXEC)

    def test_releases_lock_when_body_raises(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        fake_dev = tmp / "vda"
        fake_dev.write_bytes(b"")

        with self.assertRaisesRegex(RuntimeError, "boom"):
            with disk_udev.flock_whole_disk(fake_dev, whole_disk_fn=lambda _: fake_dev):
                raise RuntimeError("boom")

        probe = os.open(str(fake_dev), os.O_RDONLY)
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(probe)

    def test_noops_on_non_block_device_and_phases_impl_delegates(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        regular = tmp / "not-a-block"
        regular.write_bytes(b"")
        entered = False
        with disk_udev.flock_whole_disk(regular):
            entered = True
        self.assertTrue(entered)

        sys.modules.setdefault(
            "orchestrator.archinstall_adapter",
            types.ModuleType("orchestrator.archinstall_adapter"),
        )
        from orchestrator import phases_impl

        with mock.patch.object(disk_udev, "flock_whole_disk", wraps=disk_udev.flock_whole_disk) as wrapped:
            with phases_impl._flock_whole_disk(str(regular)):
                pass
        wrapped.assert_called_once_with(str(regular))


if __name__ == "__main__":
    unittest.main()
