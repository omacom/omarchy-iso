#!/usr/bin/python

"""Releasing the install disk before archinstall partitions it.

omarchy-iso-cleanup-disk refuses when something still holds the disk, and its
last line says what. prepare_live has to put that line on the failure screen
rather than the "returned non-zero exit status 1" a bare check=True gives, and
has to stop before archinstall is ever loaded. These tests put stand-in
cleanup scripts on PATH, so the real command capture runs.
"""

import os
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

    def test_a_home_drive_that_fails_its_checks_stops_before_any_disk_is_touched(self):
        self.cleanup_script(f'touch "{self.bin_dir}/ran"')
        ctx = self.ctx()
        ctx.omarchy_install = {"home": {"mode": "fresh", "disk": "/dev/vdc"}}
        with mock.patch.object(phases_impl.home_drive, "check_before_erase",
                               side_effect=RuntimeError("home drive: /dev/vdc cannot be erased")):
            with self.assertRaisesRegex(RuntimeError, "cannot be erased"):
                phases_impl.prepare_live(ctx)
        self.assertFalse((self.bin_dir / "ran").exists())

    def home_ctx(self, protected=False):
        ctx = self.ctx()
        ctx.is_protected = protected
        ctx.omarchy_install = {"home": {"mode": "fresh", "disk": "/dev/vdc"}}
        check = mock.patch.object(phases_impl.home_drive, "check_before_erase")
        check.start()
        self.addCleanup(check.stop)
        return ctx

    def released(self):
        return (self.bin_dir / "args").read_text().splitlines()

    def test_a_fresh_home_disk_is_released_like_the_install_disk(self):
        # The live ISO's udev activates an old volume group or RAID member on
        # the home disk as on the install disk, and it holds the partitions
        # the fresh home is made over.
        self.cleanup_script(f'echo "$*" >>"{self.bin_dir}/args"')
        phases_impl.prepare_live(self.home_ctx())
        self.assertEqual(self.released(), ["--home /dev/vdc", "/dev/vda"])

    def test_a_protected_install_releases_only_the_home_disk(self):
        self.cleanup_script(f'echo "$*" >>"{self.bin_dir}/args"')
        phases_impl.prepare_live(self.home_ctx(protected=True))
        self.assertEqual(self.released(), ["--home /dev/vdc"])

    def test_a_held_home_disk_stops_with_what_holds_it(self):
        self.cleanup_script('[ "$1" = --home ] || exit 0\necho "/dev/vdc is still in use (vdc1 is held by md127)."\nexit 1')
        with self.assertRaisesRegex(RuntimeError, "vdc1 is held by md127"):
            phases_impl.prepare_live(self.home_ctx())

    def test_a_released_disk_goes_on_to_archinstall(self):
        self.cleanup_script('[ "$1" = /dev/vda ] || exit 1\necho "Released $1"')

        phases_impl.prepare_live(self.ctx())

        self.arch.load_arch_config.assert_called_once()


class HomeDriveFailureCleanupTest(unittest.TestCase):
    """A failed install lets go of the home drive in either mode: a home
    mapping left open, or home-top left mounted, makes the next attempt
    refuse it."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin_dir = Path(self.tmp.name)
        script = self.bin_dir / "omarchy-release-install-target"
        script.write_text(f'#!/bin/sh\necho "$*" >>"{self.bin_dir}/args"\n')
        script.chmod(0o755)
        path = mock.patch.dict(os.environ, {"PATH": f"{self.bin_dir}:{os.environ['PATH']}"})
        path.start()
        self.addCleanup(path.stop)

    def ctx(self, home):
        return types.SimpleNamespace(target=Path("/mnt"), omarchy_install={"home": home})

    def test_the_home_mount_and_mapping_are_released(self):
        phases_impl.cleanup_home_drive(self.ctx({"mode": "fresh", "disk": "/dev/vdc"}))
        self.assertEqual((self.bin_dir / "args").read_text(), "/mnt/home home\n")

    def test_nothing_to_release_for_home_on_the_install_disk(self):
        phases_impl.cleanup_home_drive(self.ctx(None))
        self.assertFalse((self.bin_dir / "args").exists())


class MainFailureCleanupTest(unittest.TestCase):
    def test_a_failed_install_releases_the_home_drive_in_either_mode(self):
        import importlib
        from contextlib import ExitStack

        import archinstall_fakes

        for protected in (False, True):
            with archinstall_fakes.orchestrator_module("main") as main, ExitStack() as stack:
                impl = importlib.import_module("orchestrator.phases_impl")
                ctx = types.SimpleNamespace(username="kim", target=Path("/mnt"), is_protected=protected)
                stack.enter_context(mock.patch.object(main.InstallContext, "from_env", return_value=ctx))
                stack.enter_context(mock.patch.object(main, "build_phases", return_value=[]))
                stack.enter_context(mock.patch.object(main, "run", side_effect=main.PhaseError("failed")))
                for name in ("boost_cpu_governor", "restore_cpu_governors", "stop_target_keyring_init",
                             "cleanup_bind_mounts", "cleanup_target_hook_masks", "cleanup_protected_state"):
                    stack.enter_context(mock.patch.object(impl, name))
                released = stack.enter_context(mock.patch.object(impl, "cleanup_home_drive", create=True))
                self.assertEqual(main.main(), 1)
                released.assert_called_once_with(ctx)


if __name__ == "__main__":
    unittest.main()
