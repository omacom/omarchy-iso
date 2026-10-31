#!/usr/bin/python

"""Releasing the install disk before archinstall partitions it.

omarchy-iso-cleanup-disk refuses when something still holds the disk, and its
last line says what. prepare_live has to put that line on the failure screen
rather than the "returned non-zero exit status 1" a bare check=True gives, and
has to stop before archinstall is ever loaded. These tests put stand-in
cleanup scripts on PATH, so the real command capture runs.
"""

import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

# phases_impl imports the archinstall adapter at module scope, which pulls in
# the archinstall library that only exists on the live ISO.
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402

FULL_DISK = {"disk_config": {"device_modifications": [{"device": "/dev/vda", "wipe": True}]}}


class InstallDiskReleaseTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin_dir = Path(self.tmp.name)
        path = mock.patch.dict(os.environ, {"PATH": f"{self.bin_dir}:{os.environ['PATH']}"})
        path.start()
        self.addCleanup(path.stop)
        self.arch = mock.Mock()
        patches = [
            mock.patch.object(phases_impl, "arch", self.arch, create=True),
            mock.patch.object(phases_impl, "_stage_apple_t2_firmware"),
            mock.patch.object(phases_impl, "_stage_qualcomm_firmware"),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def cleanup_script(self, body: str) -> None:
        script = self.bin_dir / "omarchy-iso-cleanup-disk"
        script.write_text(f"#!/bin/sh\n{body}\n")
        script.chmod(0o755)

    def ctx(self):
        return types.SimpleNamespace(
            is_protected=False,
            user_configuration=FULL_DISK,
            arch_config_path=Path("/root/user_configuration.json"),
            creds_path=Path("/root/user_credentials.json"),
            state={},
        )

    def test_a_held_disk_stops_with_what_holds_it(self):
        self.cleanup_script(
            'echo "Cleaning up existing holders on install disk: $1"\n'
            'echo "/dev/vda is still in use and cannot be partitioned (vda2 is held by md127)."\n'
            "exit 1"
        )

        with self.assertRaises(RuntimeError) as raised:
            phases_impl.prepare_live(self.ctx())

        self.assertEqual(
            str(raised.exception),
            "/dev/vda is still in use and cannot be partitioned (vda2 is held by md127).",
        )
        self.arch.load_arch_config.assert_not_called()

    def test_a_silent_failure_still_names_the_disk(self):
        self.cleanup_script("exit 1")

        with self.assertRaises(RuntimeError) as raised:
            phases_impl.prepare_live(self.ctx())

        self.assertEqual(str(raised.exception), "Could not release /dev/vda")

    def test_a_released_disk_goes_on_to_archinstall(self):
        self.cleanup_script('[ "$1" = /dev/vda ] || exit 1\necho "Released $1"')

        phases_impl.prepare_live(self.ctx())

        self.arch.load_arch_config.assert_called_once()

    def test_t2_firmware_is_staged_before_disk_cleanup(self):
        events = []
        released = subprocess.CompletedProcess([], 0, stdout="Released /dev/vda\n", stderr="")
        with mock.patch.object(
            phases_impl, "_stage_apple_t2_firmware", side_effect=lambda: events.append("stage")
        ), mock.patch.object(
            phases_impl, "capture", side_effect=lambda _cmd: events.append("cleanup") or released
        ):
            phases_impl.prepare_live(self.ctx())

        self.assertEqual(events, ["stage", "cleanup"])


if __name__ == "__main__":
    unittest.main()
