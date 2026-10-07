"""The filesystem-step wrapper in archinstall_adapter.

It runs against stand-ins that record what it does to them: mkfs.btrfs gets -K
only when the filesystem is a throwaway, every other filesystem and every
other case is left alone, each piece is timed, and the patched names are put
back exactly, also when the step raises.
"""

import os
import sys
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


class FilesystemStepTweaks(unittest.TestCase):
    def load(self, steps):
        """The adapter's wrapper, with a device handler that records its
        calls and a step timer that records its labels in steps."""
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
            "archinstall.lib.disk.device_handler": {"device_handler": handler, "udev_sync": _udev_sync},
            "archinstall.lib.disk.filesystem": {"udev_sync": _udev_sync},
            "archinstall.lib.disk.luks": {"Luks2": Luks2},
            "archinstall.lib.models.device": {"FilesystemType": FilesystemType},
        }))
        phases = types.ModuleType("orchestrator.phases_impl")
        phases._time_step = time_step
        self.enterContext(mock.patch.dict(sys.modules, {"orchestrator.phases_impl": phases}))
        self.enterContext(mock.patch.object(arch, "info", steps.append))
        return (arch._filesystem_step_tweaks, handler,
                sys.modules["archinstall.lib.disk.device_handler"], sys.modules["archinstall.lib.disk.filesystem"])

    def run_step(self, throwaway, body=None):
        steps = []
        tweaks, handler, dh_module, fs_module = self.load(steps)
        settle_before = (dh_module.udev_sync, fs_module.udev_sync)
        luks_before = (Luks2.__dict__["encrypt"], Luks2.__dict__["unlock"])
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


if __name__ == "__main__":
    unittest.main()
