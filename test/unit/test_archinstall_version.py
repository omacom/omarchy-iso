"""Unit tests for the archinstall version check in archinstall_adapter.

The adapter replaces archinstall internals, so it refuses to start on an
archinstall other than the ones it is tested against, unless told to try.
"""

import os
import sys
import unittest
from pathlib import Path
from unittest import mock

# The helper sits next to this file; unittest discovery does not always put
# this directory on the path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from archinstall_fakes import adapter  # noqa: E402


class ArchinstallVersionTest(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.dict(os.environ)
        patcher.start()
        self.addCleanup(patcher.stop)
        os.environ.pop("OMARCHY_ARCHINSTALL_UNTESTED", None)

    def load(self):
        arch = self.enterContext(adapter())
        said = []
        self.enterContext(mock.patch.object(arch, "info", said.append))
        return arch, said

    def test_the_tested_versions_pass(self):
        arch, said = self.load()
        for tested in arch.TESTED_ARCHINSTALL:
            arch.check_archinstall_version(tested)
            arch.check_archinstall_version(tested + ".1")  # a patch release
        self.assertEqual(arch.TESTED_ARCHINSTALL, ("4.4", "4.5"))
        self.assertEqual(said, [])

    def test_another_version_stops_the_install(self):
        arch, _ = self.load()
        with self.assertRaises(RuntimeError) as caught:
            arch.check_archinstall_version("4.6")
        self.assertIn("archinstall 4.6 is installed", str(caught.exception))
        self.assertIn("tested against archinstall 4.4 and 4.5", str(caught.exception))
        self.assertIn("OMARCHY_ARCHINSTALL_UNTESTED=1", str(caught.exception))

    def test_an_unknown_version_stops_the_install(self):
        arch, _ = self.load()
        with self.assertRaises(RuntimeError):
            arch.check_archinstall_version("unknown")

    def test_the_override_runs_anyway_and_says_so(self):
        arch, said = self.load()
        os.environ["OMARCHY_ARCHINSTALL_UNTESTED"] = "1"
        arch.check_archinstall_version("4.6")
        self.assertEqual(len(said), 1)
        self.assertIn("running anyway", said[0])

    def test_the_check_runs_before_the_patches(self):
        class Luks2:
            def unlock(self, key_file=None): return None
            def lock(self): return None

        untouched = dict(vars(Luks2))
        with self.assertRaises(RuntimeError):
            with adapter({"archinstall.lib.disk.luks": {"Luks2": Luks2}}, version="4.6"):
                pass
        self.assertEqual(dict(vars(Luks2)), untouched, "archinstall was patched before the version check")


if __name__ == "__main__":
    unittest.main()
