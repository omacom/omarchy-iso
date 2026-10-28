"""Unit tests for _medium_bytes_read, which lets the install log say how much
of the root image the write read off the install medium rather than the page
cache: sectors read from the boot medium's /sys/class/block/<dev>/stat."""

import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


class MediumBytesReadTest(unittest.TestCase):
    def read(self, source, stat=None):
        with tempfile.TemporaryDirectory() as tmp:
            if stat is not None:
                (Path(tmp) / "sda1").mkdir()
                (Path(tmp) / "sda1" / "stat").write_text(stat)
            with mock.patch.object(phases_impl, "SYSFS_BLOCK", Path(tmp)), \
                 mock.patch.object(phases_impl, "_findmnt_value", return_value=source):
                return phases_impl._medium_bytes_read()

    def test_sectors_read_become_bytes(self):
        stat = "  1520  0  8388608  9000  0  0  0  0  0  4000  9000  0 0 0 0 0 0\n"
        self.assertEqual(self.read("/dev/sda1", stat), 8388608 * 512)

    def test_no_block_device_answers_none(self):
        self.assertIsNone(self.read(None))
        self.assertIsNone(self.read("10.0.2.2:/srv/omarchy"))
        self.assertIsNone(self.read("/dev/sda1"))  # no stat file
        self.assertIsNone(self.read("/dev/sda1", "garbage\n"))


if __name__ == "__main__":
    unittest.main()
