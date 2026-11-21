"""The filesystem-step wrapper in archinstall_adapter.

It runs against stand-ins that record what it does to them: mkfs.btrfs gets -K
only when the filesystem is a throwaway, every other filesystem and every
other case is left alone, each piece is timed, and the patched names are put
back exactly, also when the step raises. parted's commit is followed by a
settle and a wait for the disk's partition nodes, which udevd's re-read of
the new table removes and adds back while archinstall is about to wipefs them.
"""

import os
import re
import sys
import tempfile
import threading
import types
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

# The helper sits next to this file; unittest discovery does not always put
# this directory on the path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from archinstall_fakes import adapter  # noqa: E402


class FsType:
    def __init__(self, value): self.value = value
    def __eq__(self, other): return isinstance(other, FsType) and other.value == self.value
    def __hash__(self): return hash(self.value)


class FilesystemType:
    BTRFS = FsType("btrfs")
    FAT32 = FsType("fat32")


class DeviceHandler:
    def __init__(self): self.calls = []
    def partition(self, mod): self.calls.append(("partition", mod))
    def create_btrfs_volumes(self, part, enc_conf=None): self.calls.append(("subvolumes", part))
    def format(self, fs_type, path, additional_parted_options=[]):
        self.calls.append(("format", fs_type.value, str(path), list(additional_parted_options)))


class Luks2:
    def encrypt(self, iter_time=0): return "key"
    def unlock(self, key_file=None): return None
    def lock(self): return None


def _udev_sync():
    return None


class Disk:
    """parted.Disk: commit() writes the table, and the re-read it sets off
    removes the partition nodes and creates them again reread seconds
    later (never, with None)."""

    def __init__(self, device, nodes, reread=0.3):
        self.device = types.SimpleNamespace(path=device)
        self.partitions = [types.SimpleNamespace(path=str(node)) for node in nodes]
        self.reread, self.rereads = reread, []

    def commit(self):
        for partition in self.partitions:
            Path(partition.path).unlink(missing_ok=True)
        if self.reread is not None:
            timer = threading.Timer(self.reread, lambda: [Path(p.path).touch() for p in self.partitions])
            timer.start()
            self.rereads.append(timer)
        return True


def archinstall_partition(disk):
    """The end of archinstall's device_handler.partition(): commit, then
    wipefs every new partition."""
    disk.commit()
    for partition in disk.partitions:
        if not Path(partition.path).exists():
            raise RuntimeError(f"wipefs: error: {partition.path}: probing initialization failed: No such file or directory")


class StepTest(unittest.TestCase):
    def load(self, steps, udev_sync=_udev_sync):
        """The adapter's wrapper, with a device handler that records its
        calls, a step timer that records its labels in steps, and udev_sync
        as archinstall's udevadm settle."""
        handler = DeviceHandler()
        # luks_tuning replaces Luks2's methods when the adapter loads; here
        # Luks2 is the stand-in the wrapper is observed on.
        self.enterContext(mock.patch.dict(os.environ, {"OMARCHY_LUKS_TUNING": "0"}))

        @contextmanager
        def time_step(label):
            try:
                yield
            finally:
                steps.append(label)

        arch = self.enterContext(adapter({
            "archinstall.lib.disk.device_handler": {"device_handler": handler, "udev_sync": udev_sync},
            "archinstall.lib.disk.filesystem": {"udev_sync": udev_sync},
            "archinstall.lib.disk.luks": {"Luks2": Luks2},
            "archinstall.lib.models.device": {"FilesystemType": FilesystemType},
        }))
        phases = types.ModuleType("orchestrator.phases_impl")
        phases._time_step = time_step
        self.enterContext(mock.patch.dict(sys.modules, {
            "orchestrator.phases_impl": phases,
            "parted": types.SimpleNamespace(Disk=Disk),
        }))
        self.enterContext(mock.patch.object(arch, "info", steps.append))
        self.arch = arch
        return (arch._filesystem_step_tweaks, handler,
                sys.modules["archinstall.lib.disk.device_handler"], sys.modules["archinstall.lib.disk.filesystem"])


class FilesystemStepTweaks(StepTest):

    def run_step(self, throwaway, body=None):
        steps = []
        tweaks, handler, dh_module, fs_module = self.load(steps)
        settle_before = (dh_module.udev_sync, fs_module.udev_sync)
        luks_before = (Luks2.__dict__["encrypt"], Luks2.__dict__["unlock"])
        commit_before = Disk.__dict__["commit"]
        try:
            with tweaks(throwaway):
                handler.partition("disk")
                handler.format(FilesystemType.FAT32, Path("/dev/x1"))
                Luks2().encrypt(); Luks2().unlock()
                handler.format(FilesystemType.BTRFS, Path("/dev/mapper/root"))
                handler.create_btrfs_volumes("root")
                dh_module.udev_sync(); fs_module.udev_sync()
                if body:
                    body()
        finally:
            self.assertNotIn("format", vars(handler), "the patched format was left on the device handler")
            self.assertNotIn("partition", vars(handler))
            self.assertEqual(settle_before, (dh_module.udev_sync, fs_module.udev_sync))
            self.assertEqual(luks_before, (Luks2.__dict__["encrypt"], Luks2.__dict__["unlock"]))
            self.assertIs(commit_before, Disk.__dict__["commit"], "parted.Disk.commit was left wrapped")
        return steps, handler.calls

    def test_throwaway_btrfs_is_made_without_the_whole_device_trim(self):
        steps, calls = self.run_step(True)
        formats = [c for c in calls if c[0] == "format"]
        self.assertEqual(formats[0][3], [], "the ESP's mkfs must not change")
        self.assertEqual(formats[1][3], ["-K"])
        self.assertTrue(any("mkfs.btrfs -K" in s for s in steps))

    def test_a_filesystem_that_stays_keeps_its_trim(self):
        steps, calls = self.run_step(False)
        self.assertEqual([c[3] for c in calls if c[0] == "format"], [[], []])

    def test_every_piece_is_timed(self):
        steps, _ = self.run_step(True)
        for label in ("FS.partition", "FS.mkfs.fat32", "FS.luksFormat", "FS.luks_open", "FS.create_btrfs_subvolumes"):
            self.assertTrue(any(s.startswith(label) for s in steps), f"{label} missing from {steps}")

    def test_names_are_restored_when_the_step_raises(self):
        def boom():
            raise RuntimeError("parted lost a race")
        with self.assertRaises(RuntimeError):
            self.run_step(True, boom)


class PartitionNodesAfterCommit(StepTest):
    """udevd re-reads the table parted just wrote, dropping and adding back
    every partition; archinstall must not wipefs into that gap."""

    def setUp(self):
        self.dev = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.nodes = [self.dev / "vda1", self.dev / "vda2"]
        for node in self.nodes:
            node.touch()

    def partition(self, disk, udev_sync=_udev_sync):
        steps = []
        tweaks = self.load(steps, udev_sync)[0]
        try:
            with tweaks(False):
                archinstall_partition(disk)
        finally:
            for timer in disk.rereads:
                timer.cancel()
        return steps

    def test_wipefs_waits_for_the_nodes_the_reread_adds_back(self):
        disk = Disk(str(self.dev), self.nodes, reread=0.3)
        self.partition(disk)
        self.assertTrue(all(node.exists() for node in self.nodes))

    def test_udevadm_settle_runs_after_the_commit(self):
        disk = Disk(str(self.dev), self.nodes, reread=0.3)
        settled = []

        def settle():
            # The real settle returns once udevd's re-read is done.
            for timer in disk.rereads:
                timer.join()
            settled.append(all(node.exists() for node in self.nodes))

        self.partition(disk, settle)
        self.assertEqual(settled, [True])

    def test_nodes_that_never_appear_fail_the_step_by_name(self):
        disk = Disk(str(self.dev), self.nodes, reread=None)
        commit = Disk.__dict__["commit"]
        tweaks = self.load([])[0]
        message = f"{self.dev}/vda1, {self.dev}/vda2 did not appear within 0.2s"
        with self.assertRaisesRegex(RuntimeError, re.escape(message)):
            with mock.patch("orchestrator.archinstall_adapter.PARTITION_NODES_TIMEOUT", 0.2), tweaks(False):
                archinstall_partition(disk)
        self.assertIs(Disk.__dict__["commit"], commit, "parted.Disk.commit was left wrapped")

    def test_commit_is_restored_after_the_step(self):
        commit = Disk.__dict__["commit"]
        self.partition(Disk(str(self.dev), self.nodes, reread=0.05))
        self.assertIs(Disk.__dict__["commit"], commit)


class Part:
    """archinstall's PartitionModification, as far as the discard reads it."""

    def __init__(self, status, dev_path, root=False, efi=False):
        self.status = types.SimpleNamespace(value=status)
        self.dev_path = Path(dev_path) if dev_path else None
        self._root, self._efi = root, efi

    def is_root(self): return self._root
    def is_efi(self): return self._efi


class RootPartitionDiscard(StepTest):
    """Once archinstall has created and wiped the partitions, the new root
    partition is discarded before format() can write to it, and nothing
    else is."""

    def partition(self, partitions):
        steps, events = [], []
        tweaks, handler, _, _ = self.load(steps)
        original = handler.partition
        handler.partition = lambda mod: (original(mod), events.append("partitioned"))
        self.enterContext(mock.patch.object(self.arch, "discard_partition",
                                            lambda path: events.append(("discard", str(path)))))
        with tweaks(True):
            handler.partition(types.SimpleNamespace(partitions=partitions))
            handler.format(FilesystemType.BTRFS, Path("/dev/mapper/root"))
            events.append("formatted")
        return steps, events

    def test_the_new_root_is_discarded_after_partitioning_and_before_format(self):
        steps, events = self.partition([
            Part("create", "/dev/vda1", efi=True),
            Part("create", "/dev/vda2", root=True),
        ])
        self.assertEqual(events, ["partitioned", ("discard", "/dev/vda2"), "formatted"])
        self.assertIn("FS.discard_root", steps)

    def test_the_esp_and_partitions_that_existed_are_never_discarded(self):
        _, events = self.partition([
            Part("create", "/dev/vda1", root=True, efi=True),
            Part("existing", "/dev/vda3", root=True),
            Part("modify", "/dev/vda4", root=True),
            Part("create", None, root=True),
            Part("create", "/dev/vda5"),
        ])
        self.assertEqual(events, ["partitioned", "formatted"])

    def test_a_missing_helper_is_logged_and_never_raises(self):
        steps = []
        self.load(steps)
        with mock.patch.dict(os.environ, {"PATH": str(self.enterContext(tempfile.TemporaryDirectory()))}):
            self.arch.discard_partition(Path("/dev/vda2"))
        self.assertTrue(any("could not run for /dev/vda2" in s for s in steps), steps)


if __name__ == "__main__":
    unittest.main()
