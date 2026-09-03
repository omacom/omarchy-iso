"""Unit tests for retaining freshly-created LUKS mappings during setup."""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator.luks_lifecycle import defer_mapper_locks  # noqa: E402


class FakeLuks:
    calls = []

    def __init__(self, mapper_name, unlocked=True):
        self.mapper_name = mapper_name
        self.unlocked = unlocked

    def is_unlocked(self):
        return self.unlocked

    def lock(self):
        self.calls.append(self.mapper_name)


class DeferMapperLocksTest(unittest.TestCase):
    def setUp(self):
        FakeLuks.calls = []

    def test_selected_open_mapper_stays_open(self):
        with defer_mapper_locks(FakeLuks, {"omarchy-root"}):
            FakeLuks("omarchy-root").lock()
            FakeLuks("old-root").lock()

        self.assertEqual(FakeLuks.calls, ["old-root"])

    def test_selected_closed_mapper_uses_normal_lock(self):
        with defer_mapper_locks(FakeLuks, {"omarchy-root"}):
            FakeLuks("omarchy-root", unlocked=False).lock()

        self.assertEqual(FakeLuks.calls, ["omarchy-root"])

    def test_original_method_is_restored_after_exception(self):
        original_lock = FakeLuks.lock
        selected = FakeLuks("omarchy-root")

        with self.assertRaisesRegex(RuntimeError, "setup failed"):
            with defer_mapper_locks(FakeLuks, {"omarchy-root"}):
                selected.lock()
                raise RuntimeError("setup failed")

        self.assertIs(FakeLuks.lock, original_lock)
        self.assertEqual(FakeLuks.calls, ["omarchy-root"])
        FakeLuks("omarchy-root").lock()
        self.assertEqual(FakeLuks.calls, ["omarchy-root", "omarchy-root"])


if __name__ == "__main__":
    unittest.main()
