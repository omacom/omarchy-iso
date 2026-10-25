"""Unit tests for open_installer's Installer subclass (archinstall_adapter).

archinstall's Installer.__exit__ prints "Please submit this issue (and file) to
https://github.com/archlinux/archinstall/issues" for any exception inside the
with-block, and Omarchy runs most of its own install in that block, so its
failures would be filed with archinstall (archlinux/archinstall#4773). The
Installer below behaves like archinstall 4.4's.
"""

import io
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path

# The helper sits next to this file; unittest discovery does not always put
# this directory on the path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from archinstall_fakes import adapter  # noqa: E402


ARCHINSTALL_MESSAGE = "Please submit this issue (and file) to https://github.com/archlinux/archinstall/issues"


class Installer:
    """archinstall 4.4's Installer, as far as __enter__/__exit__ go."""

    def __init__(self, mountpoint, disk_config, kernels=None, silent=False):
        self.calls = []

    def __enter__(self):
        return self

    def sync_log_to_install_medium(self):
        self.calls.append("sync_log")

    def __exit__(self, exc_type, exc_value, traceback):
        if exc_type is not None:
            self.sync_log_to_install_medium()
            print("[!] A log file has been created here: /var/log/archinstall/install.log")
            print(ARCHINSTALL_MESSAGE)
            return None
        self.calls.append("success")
        return None


class Config:
    disk_config = object()
    kernels = ["linux-omarchy"]


class OpenInstallerTest(unittest.TestCase):
    def setUp(self):
        self.arch = self.enterContext(adapter({"archinstall.lib.installer": {"Installer": Installer}}))

    def test_a_failure_is_not_sent_to_archinstall(self):
        out = io.StringIO()
        with redirect_stdout(out), self.assertRaises(RuntimeError):
            with self.arch.open_installer(Config(), Path("/mnt")) as installer:
                raise RuntimeError("efibootmgr --create exited 5")
        self.assertNotIn(ARCHINSTALL_MESSAGE, out.getvalue())
        self.assertEqual(installer.calls, ["sync_log"])

    def test_success_is_archinstalls_own_exit(self):
        with self.arch.open_installer(Config(), Path("/mnt")) as installer:
            pass
        self.assertEqual(installer.calls, ["success"])

    def test_the_subclass_is_what_runs_the_install(self):
        with self.arch.open_installer(Config(), Path("/mnt")) as installer:
            self.assertIsInstance(installer, self.arch.OmarchyInstaller)
            self.assertIsInstance(installer, Installer)


if __name__ == "__main__":
    unittest.main()
