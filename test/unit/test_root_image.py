"""Unit tests for the root image install path in the orchestrator.

Covers the pre-flight checks prepare_install_target runs before the disk is
touched (image present and verified by the boot-time units, a disk layout the
image can land on), the verify progress the dashboard shows, what the written
image owes the later phases, and the target keyring unit. The write and the
reshape are in test_place_root_image.py.
"""

import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


def btrfs_root_layout(name="@", mountpoint="/"):
    return {
        "config_type": "default_layout",
        "device_modifications": [
            {
                "device": "/dev/vda",
                "wipe": True,
                "partitions": [
                    {"fs_type": "fat32", "mountpoint": "/boot", "btrfs": []},
                    {
                        "fs_type": "btrfs",
                        "mountpoint": None,
                        "btrfs": [
                            {"name": name, "mountpoint": mountpoint},
                            {"name": "@home", "mountpoint": "/home"},
                        ],
                    },
                ],
            }
        ],
    }


class VerifyRootImageLayoutTest(unittest.TestCase):
    def test_btrfs_root_subvolume_passes(self):
        phases_impl.verify_root_image_layout(btrfs_root_layout())
        phases_impl.verify_root_image_layout(btrfs_root_layout(name="/@"))

    def test_lvm_rejected(self):
        layout = btrfs_root_layout()
        layout["lvm_config"] = {"config_type": "default", "vol_groups": []}
        with self.assertRaisesRegex(RuntimeError, "LVM"):
            phases_impl.verify_root_image_layout(layout)

    def test_root_not_on_at_subvolume_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "@ subvolume"):
            phases_impl.verify_root_image_layout(btrfs_root_layout(name="root"))

    def test_ext4_root_rejected(self):
        layout = {
            "device_modifications": [
                {"partitions": [{"fs_type": "ext4", "mountpoint": "/", "btrfs": []}]}
            ]
        }
        with self.assertRaisesRegex(RuntimeError, "@ subvolume"):
            phases_impl.verify_root_image_layout(layout)

    def test_empty_config_rejected(self):
        with self.assertRaises(RuntimeError):
            phases_impl.verify_root_image_layout({})


class VerifyRootImageTest(unittest.TestCase):
    """verify_install_medium delegates to the shared shell helper
    (omarchy-wait-root-image-verify): it passes when the helper exits 0 and
    fails the install with the helper's message when it does not. The wait,
    the systemd handoff and the corrupt-medium wording live in the helper and
    are covered by test/unit/wait-root-image-verify-test.sh."""

    HELPER = phases_impl.ROOT_IMAGE_VERIFY_HELPER

    def setUp(self):
        self.ctx = types.SimpleNamespace(state_dir=Path("/nonexistent"))
        self.infos = []
        patch = mock.patch.object(phases_impl, "info", side_effect=self.infos.append)
        patch.start()
        self.addCleanup(patch.stop)

    def helper_returns(self, returncode=0, stdout="", stderr=""):
        self.captured = {}

        def fake_run(cmd, **kwargs):
            self.captured["cmd"] = cmd
            return CompletedProcess(cmd, returncode, stdout=stdout, stderr=stderr)

        return mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run)

    def test_passes_when_helper_exits_zero(self):
        with self.helper_returns(0, stdout="boot medium: /dev/sda1 on /dev/sda, scheduler: none mq-deadline kyber [bfq]\n"):
            phases_impl.verify_install_medium(self.ctx)
        self.assertEqual(self.captured["cmd"], [self.HELPER])
        # The boot medium / scheduler line the helper prints reaches the log.
        self.assertTrue(any("bfq" in m for m in self.infos))

    def test_corrupt_medium_raises_with_the_helpers_message(self):
        stderr = ("install medium is corrupt: re-flash it\n"
                  "sha256 mismatch on the root image\n"
                  "omarchy-root.img.zst: FAILED")
        with self.helper_returns(1, stdout="boot medium: /dev/sda1 ...\n", stderr=stderr):
            with self.assertRaises(RuntimeError) as raised:
                phases_impl.verify_install_medium(self.ctx)
        # The dashboard headlines the first line, so it must lead and be short.
        first = str(raised.exception).splitlines()[0]
        self.assertEqual(first, "install medium is corrupt: re-flash it")
        self.assertLess(len(first), 50)

    def test_nonzero_without_stderr_still_fails(self):
        with self.helper_returns(3, stdout="", stderr=""):
            with self.assertRaisesRegex(RuntimeError, "status 3"):
                phases_impl.verify_install_medium(self.ctx)

    def test_missing_helper_fails_the_install(self):
        with mock.patch.object(phases_impl.subprocess, "run",
                               side_effect=FileNotFoundError("no helper")):
            with self.assertRaisesRegex(RuntimeError, "could not run"):
                phases_impl.verify_install_medium(self.ctx)


class PublishVerifyProgressTest(unittest.TestCase):
    """_publish_verify_progress mirrors the hasher's fdinfo read position into
    phase_progress while the unit is activating. Our own unbuffered fd on a
    temp stream stands in for sha256sum's, with MainPID pointed at this
    process."""

    def test_mirrors_hasher_read_position(self):
        with tempfile.TemporaryDirectory() as tmp:
            stream = (Path(tmp) / "omarchy-root.img.zst").resolve()
            stream.write_bytes(b"\0" * 4096)
            states = iter(["activating", "active"])

            def unit_property(prop, unit=None):
                return next(states) if prop == "ActiveState" else str(os.getpid())

            fractions = []
            fd = os.open(stream, os.O_RDONLY)
            try:
                os.read(fd, 1024)
                with mock.patch.object(phases_impl, "ROOT_IMAGE", stream), \
                     mock.patch.object(phases_impl, "_verify_unit_property",
                                       side_effect=unit_property), \
                     mock.patch.object(phases_impl, "_write_phase_progress",
                                       side_effect=lambda ctx, f: fractions.append(f)), \
                     mock.patch.object(phases_impl.time, "sleep"):
                    phases_impl._publish_verify_progress(ctx=None)
            finally:
                os.close(fd)
            self.assertEqual(fractions, [0.25])

    def test_mirror_then_image_as_one_fraction(self):
        # Two 1000-byte packages hashed first (the hasher 500 bytes into the
        # second), then a 4096-byte image (1024 bytes in): 1500 and then
        # 2000 + 1024 of 6096 bytes.
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp).resolve()
            stream = tmp / "omarchy-root.img.zst"
            stream.write_bytes(b"\0" * 4096)
            mirror = tmp / "mirror"
            mirror.mkdir()
            for name in ("a.pkg.tar.zst", "b.pkg.tar.zst"):
                (mirror / name).write_bytes(b"\1" * 1000)
            sums = tmp / "offline-mirror.sha256"
            sums.write_text("00  a.pkg.tar.zst\n00  b.pkg.tar.zst\n")
            mirror_states = iter(["activating", "active"])
            image_states = iter(["inactive", "activating", "active"])
            stage = {"unit": None}

            def unit_property(prop, unit=phases_impl.ROOT_IMAGE_VERIFY_UNIT):
                if prop == "MainPID":
                    stage["unit"] = unit
                    return str(os.getpid())
                return next(mirror_states if unit == phases_impl.MIRROR_VERIFY_UNIT else image_states)

            fractions = []
            package = os.open(mirror / "b.pkg.tar.zst", os.O_RDONLY)
            image = os.open(stream, os.O_RDONLY)
            try:
                os.read(package, 500)
                os.read(image, 1024)
                with mock.patch.object(phases_impl, "ROOT_IMAGE", stream), \
                     mock.patch.object(phases_impl, "MIRROR_SUMS", sums), \
                     mock.patch.object(phases_impl, "OFFLINE_MIRROR", mirror), \
                     mock.patch.object(phases_impl, "_verify_unit_property",
                                       side_effect=unit_property), \
                     mock.patch.object(phases_impl, "_write_phase_progress",
                                       side_effect=lambda ctx, f: fractions.append(f)), \
                     mock.patch.object(phases_impl.time, "sleep"):
                    phases_impl._publish_verify_progress(ctx=None)
            finally:
                os.close(package)
                os.close(image)
            self.assertEqual(fractions, [1500 / 6096, 3024 / 6096])

    def test_missing_image_is_a_no_op(self):
        with mock.patch.object(phases_impl, "ROOT_IMAGE",
                               Path("/nonexistent/omarchy-root.img.zst")), \
             mock.patch.object(phases_impl, "_verify_unit_property") as show:
            phases_impl._publish_verify_progress(ctx=None)
        show.assert_not_called()


class PrepareInstallTargetTest(unittest.TestCase):
    """prepare_install_target wires the checks together per install mode."""

    def setUp(self):
        self.calls = []
        for name in ("verify_protected_mounts", "verify_install_medium",
                     "verify_root_image_layout", "_root_image_target_mounts"):
            patch = mock.patch.object(
                phases_impl, name, side_effect=lambda *a, _n=name, **k: self.calls.append(_n)
            )
            patch.start()
            self.addCleanup(patch.stop)

    def test_full_disk_checks_json_layout_then_image(self):
        ctx = types.SimpleNamespace(
            is_protected=False, target=Path("/mnt"),
            user_configuration={"disk_config": btrfs_root_layout()},
        )
        phases_impl.prepare_install_target(ctx)
        self.assertEqual(self.calls, ["verify_root_image_layout", "verify_install_medium"])

    def test_protected_checks_real_mounts_then_image(self):
        ctx = types.SimpleNamespace(
            is_protected=True, target=Path("/mnt"),
            user_configuration={"disk_config": {"config_type": "pre_mounted_config"}},
        )
        phases_impl.prepare_install_target(ctx)
        self.assertEqual(
            self.calls,
            ["verify_protected_mounts", "_root_image_target_mounts", "verify_install_medium"],
        )


class FinishRootImageTest(unittest.TestCase):
    """What the written image owes the rest of the install: the packages the
    later phases assume, and a machine-id. (The write and the reshape are in
    test_place_root_image.py.)"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ctx = types.SimpleNamespace(target=Path(self.tmp.name) / "mnt")
        self.packages = {"limine", "omarchy-keyring", "omarchy"}
        self.calls = []
        for patch in (
            mock.patch.object(phases_impl, "_root_image_required_packages",
                              return_value=["limine", "omarchy-keyring", "omarchy"]),
            mock.patch.object(phases_impl.arch, "target_has_package", create=True,
                              side_effect=lambda target, pkg: pkg in self.packages),
            mock.patch.object(phases_impl.subprocess, "run",
                              side_effect=lambda cmd, **kw: self.calls.append(cmd)),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def test_sets_up_the_machine_id(self):
        phases_impl._finish_root_image(self.ctx)
        self.assertEqual(self.calls, [["systemd-machine-id-setup", f"--root={self.ctx.target}"]])

    def test_missing_required_package_fails_before_anything_else(self):
        self.packages.discard("omarchy")
        with self.assertRaisesRegex(RuntimeError, "lacks required packages: omarchy"):
            phases_impl._finish_root_image(self.ctx)
        self.assertEqual(self.calls, [])


class FakeUnitProc:
    """What Popen(systemd-run --wait --pipe ...) hands back."""

    def __init__(self, returncode=0, output=""):
        self.returncode = returncode
        self.output = output
        self.joined = 0

    def communicate(self):
        self.joined += 1
        return self.output, None


class TargetKeyringUnitTest(unittest.TestCase):
    """The per-machine keyring the image deliberately ships without, run as
    a transient unit and joined before the factory snapshot."""

    def setUp(self):
        self.target = Path("/mnt")
        self.ctx = types.SimpleNamespace(target=self.target, state={})
        self.runs = []
        self.popens = []

        def fake_run(cmd, **kwargs):
            self.runs.append(cmd)
            return CompletedProcess(cmd, 0, stdout="", stderr="")

        def fake_popen(cmd, **kwargs):
            self.popens.append((cmd, kwargs))
            return FakeUnitProc()

        for patch in (
            mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run),
            mock.patch.object(phases_impl.subprocess, "Popen", side_effect=fake_popen),
            mock.patch.object(phases_impl, "info"),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def test_start_runs_init_then_populate_in_a_waited_unit(self):
        phases_impl._start_target_keyring_init(self.ctx)

        self.assertEqual(self.runs, [["systemctl", "reset-failed", "omarchy-target-keyring"]])
        (cmd, kwargs), = self.popens
        self.assertEqual(
            cmd[:6],
            ["systemd-run", "--wait", "--pipe", "--collect", "--quiet", "--unit=omarchy-target-keyring"],
        )
        self.assertEqual(cmd[6:8], ["sh", "-c"])
        self.assertEqual(
            cmd[8],
            "pacman-key --gpgdir /mnt/etc/pacman.d/gnupg --init && "
            "pacman-key --gpgdir /mnt/etc/pacman.d/gnupg "
            "--populate-from /mnt/usr/share/pacman/keyrings --populate archlinux omarchy",
        )
        self.assertNotIn("arch-chroot", cmd[8])
        self.assertIs(kwargs["stderr"], phases_impl.subprocess.STDOUT)
        self.assertIsInstance(self.ctx.state["target_keyring_proc"], FakeUnitProc)

    def test_join_waits_once_and_clears_state(self):
        proc = FakeUnitProc()
        self.ctx.state["target_keyring_proc"] = proc
        phases_impl._join_target_keyring_init(self.ctx)
        phases_impl._join_target_keyring_init(self.ctx)  # no-op: nothing pending
        self.assertEqual(proc.joined, 1)
        self.assertNotIn("target_keyring_proc", self.ctx.state)

    def test_join_raises_with_the_unit_output(self):
        self.ctx.state["target_keyring_proc"] = FakeUnitProc(returncode=1, output="gpg: boom\n")
        with self.assertRaisesRegex(RuntimeError, r"(?s)keyring init failed \(exit 1\).*gpg: boom"):
            phases_impl._join_target_keyring_init(self.ctx)
        self.assertNotIn("target_keyring_proc", self.ctx.state)

    def test_stop_ends_the_unit_and_never_raises(self):
        proc = FakeUnitProc(returncode=1, output="killed")
        self.ctx.state["target_keyring_proc"] = proc
        phases_impl.stop_target_keyring_init(self.ctx)
        self.assertEqual(self.runs, [["systemctl", "stop", "omarchy-target-keyring"]])
        self.assertEqual(proc.joined, 1)
        self.assertNotIn("target_keyring_proc", self.ctx.state)

    def test_stop_without_a_unit_touches_nothing(self):
        phases_impl.stop_target_keyring_init(self.ctx)
        self.assertEqual(self.runs, [])

    def test_factory_snapshot_joins_the_unit_before_anything_else(self):
        # Even when the snapshot itself is skipped, the join runs: a failed
        # keyring must fail the install.
        self.ctx.state["target_keyring_proc"] = FakeUnitProc(returncode=1, output="gpg: boom")
        with mock.patch.object(phases_impl, "_findmnt_value", return_value="ext4"):
            with self.assertRaisesRegex(RuntimeError, "keyring init failed"):
                phases_impl.create_factory_snapshot(self.ctx)
        self.assertEqual(self.runs, [])


if __name__ == "__main__":
    unittest.main()
