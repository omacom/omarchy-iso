"""Unit tests for the orchestrator's run_custom_commands phase.

The phase touches the target only through mount, arch-chroot and one
directory, so the tests run it against a temp directory with subprocess.run
recorded and the drive's mount faked.
"""

import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

# phases_impl imports the archinstall adapter at module scope, which pulls in
# the archinstall library that only exists on the live ISO. run_custom_commands
# never touches it, so stub the adapter out before the import.
sys.modules.setdefault("orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter"))

from orchestrator import phases_impl  # noqa: E402


class RunCustomCommandsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "target"
        self.target.mkdir()
        self.drive = Path(self.tmp.name) / "run-cidata"
        self.drive.mkdir()
        self.mountpoint = self.target / "root" / "cidata"
        self.drive_mounted = True
        self.calls = []
        self.fail_on = None

        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

        run_patch = mock.patch.object(phases_impl.subprocess, "run", side_effect=self.fake_run)
        run_patch.start()
        self.addCleanup(run_patch.stop)

        ismount_patch = mock.patch.object(phases_impl.os.path, "ismount", side_effect=lambda path: self.drive_mounted and Path(path) == self.drive)
        ismount_patch.start()
        self.addCleanup(ismount_patch.stop)

    def fake_run(self, cmd, **kwargs):
        self.calls.append(cmd)
        if cmd[-1] == self.fail_on:
            raise subprocess.CalledProcessError(1, cmd)
        return CompletedProcess(cmd, 0)

    def run_phase(self, commands=None):
        config = {} if commands is None else {"custom_commands": commands}
        ctx = types.SimpleNamespace(target=self.target, user_configuration=config, cidata_dir=self.drive)
        phases_impl.run_custom_commands(ctx)

    def chroot(self, command):
        return ["arch-chroot", str(self.target), "env", "CIDATA=/root/cidata", "/bin/bash", "-c", command]

    def test_no_commands_is_a_no_op(self):
        self.run_phase()
        self.run_phase(commands=[])
        self.assertEqual(self.calls, [])

    def test_runs_each_command_in_order_with_the_drive_mounted_read_only(self):
        self.run_phase(commands=["echo one", "echo two"])
        self.assertEqual(self.calls, [
            ["mount", "--bind", "-o", "ro", str(self.drive), str(self.mountpoint)],
            self.chroot("echo one"),
            self.chroot("echo two"),
            ["umount", str(self.mountpoint)],
        ])
        self.assertFalse(self.mountpoint.exists())

    def test_without_a_mounted_drive_the_commands_still_run(self):
        self.drive_mounted = False
        self.run_phase(commands=["echo one"])
        self.assertEqual(self.calls, [self.chroot("echo one")])

    def test_a_failing_command_fails_the_install_and_unmounts_the_drive(self):
        self.fail_on = "false"
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_phase(commands=["false", "echo never"])
        self.assertEqual(self.calls[1:], [self.chroot("false"), ["umount", str(self.mountpoint)]])
        self.assertFalse(self.mountpoint.exists())

    def test_rejects_anything_but_a_list_of_strings(self):
        for commands in ("echo one", [["echo", "one"]], {"cmd": "echo"}):
            with self.subTest(commands=commands):
                with self.assertRaises(RuntimeError):
                    self.run_phase(commands=commands)
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
