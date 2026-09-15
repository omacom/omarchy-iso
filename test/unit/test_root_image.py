"""Unit tests for the root image install path in the orchestrator.

Covers the pre-flight checks prepare_install_target runs before the disk is
touched (image present and verified by the boot-time unit, a disk layout the
image can land on) and the filesystem restore/subvolume setup in
_install_root_image, asserted on the subprocess calls against a temp target.
"""

import os
import shutil
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


class TimedSubstepTest(unittest.TestCase):
    def test_records_monotonic_duration_and_prints_it(self):
        ctx = types.SimpleNamespace(state={})
        with mock.patch.object(phases_impl.time, "monotonic", side_effect=[4.0, 6.25]), \
             mock.patch.object(phases_impl, "info") as info:
            with phases_impl._timed_substep(ctx, "root image"):
                pass

        self.assertEqual(
            ctx.state["phase_substeps"],
            [{"name": "root image", "elapsed": 2.25}],
        )
        info.assert_called_once_with("› timing: root image: 2.250s")


class VerifyRootImageStreamTest(unittest.TestCase):
    """verify_root_image_stream delegates to the shared shell helper
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

    def helper_returns(self, returncode=0, stdout="", stderr="", image_returncode=0):
        self.captured = {}

        def fake_run(cmd, **kwargs):
            self.captured.setdefault("cmds", []).append(cmd)
            if cmd == [self.HELPER]:
                return CompletedProcess(cmd, returncode, stdout=stdout, stderr=stderr)
            self.assertEqual(cmd[:4], ["qemu-img", "check", "-q", "-f"])
            return CompletedProcess(
                cmd, image_returncode, stdout="", stderr="bad qcow2" if image_returncode else ""
            )

        return mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run)

    def test_passes_when_helper_exits_zero(self):
        with self.helper_returns(0, stdout="boot medium: /dev/sda1 on /dev/sda, scheduler: none mq-deadline kyber [bfq]\n"):
            with mock.patch.object(phases_impl, "_root_image_stream", return_value=Path("/image.qcow2")):
                phases_impl.verify_root_image_stream(self.ctx)
        self.assertEqual(self.captured["cmds"][0], [self.HELPER])
        self.assertEqual(self.captured["cmds"][1][-1], "/image.qcow2")
        # The boot medium / scheduler line the helper prints reaches the log.
        self.assertTrue(any("bfq" in m for m in self.infos))

    def test_corrupt_medium_raises_with_the_helpers_message(self):
        stderr = ("install medium is corrupt: re-flash it\n"
                  "sha256 mismatch on the root image\n"
                  "omarchy-root.btrfs.qcow2: FAILED")
        with self.helper_returns(1, stdout="boot medium: /dev/sda1 ...\n", stderr=stderr):
            with self.assertRaises(RuntimeError) as raised:
                phases_impl.verify_root_image_stream(self.ctx)
        # The dashboard headlines the first line, so it must lead and be short.
        first = str(raised.exception).splitlines()[0]
        self.assertEqual(first, "install medium is corrupt: re-flash it")
        self.assertLess(len(first), 50)

    def test_nonzero_without_stderr_still_fails(self):
        with self.helper_returns(3, stdout="", stderr=""):
            with self.assertRaisesRegex(RuntimeError, "status 3"):
                phases_impl.verify_root_image_stream(self.ctx)

    def test_missing_helper_fails_the_install(self):
        with mock.patch.object(phases_impl.subprocess, "run",
                               side_effect=FileNotFoundError("no helper")):
            with self.assertRaisesRegex(RuntimeError, "could not run"):
                phases_impl.verify_root_image_stream(self.ctx)

    def test_invalid_qcow2_fails_before_install(self):
        with self.helper_returns(0, image_returncode=1), \
             mock.patch.object(phases_impl, "_root_image_stream", return_value=Path("/image.qcow2")):
            with self.assertRaisesRegex(RuntimeError, "root image is invalid.*bad qcow2"):
                phases_impl.verify_root_image_stream(self.ctx)


class PublishVerifyProgressTest(unittest.TestCase):
    """_publish_verify_progress mirrors the hasher's fdinfo read position into
    phase_progress while the unit is activating. Our own unbuffered fd on a
    temp stream stands in for sha256sum's, with MainPID pointed at this
    process."""

    def test_mirrors_hasher_read_position(self):
        with tempfile.TemporaryDirectory() as tmp:
            stream = (Path(tmp) / "omarchy-root.btrfs.qcow2").resolve()
            stream.write_bytes(b"\0" * 4096)
            states = iter(["activating", "active"])

            def unit_property(prop):
                return next(states) if prop == "ActiveState" else str(os.getpid())

            fractions = []
            fd = os.open(stream, os.O_RDONLY)
            try:
                os.read(fd, 1024)
                with mock.patch.object(phases_impl, "ROOT_IMAGE_STREAM", stream), \
                     mock.patch.object(phases_impl, "_verify_unit_property",
                                       side_effect=unit_property), \
                     mock.patch.object(phases_impl, "_write_phase_progress",
                                       side_effect=lambda ctx, f: fractions.append(f)), \
                     mock.patch.object(phases_impl.time, "sleep"):
                    phases_impl._publish_verify_progress(ctx=None)
            finally:
                os.close(fd)
            self.assertEqual(fractions, [0.25])

    def test_missing_stream_is_a_no_op(self):
        with mock.patch.object(phases_impl, "ROOT_IMAGE_STREAM",
                               Path("/nonexistent/omarchy-root.btrfs.qcow2")), \
             mock.patch.object(phases_impl, "_verify_unit_property") as show:
            phases_impl._publish_verify_progress(ctx=None)
        show.assert_not_called()


class PrepareInstallTargetTest(unittest.TestCase):
    """prepare_install_target wires the checks together per install mode."""

    def setUp(self):
        self.calls = []
        for name in ("verify_protected_mounts", "verify_root_image_stream",
                     "verify_root_image_layout", "_root_image_target_mounts"):
            patch = mock.patch.object(
                phases_impl, name, side_effect=lambda *a, _n=name, **k: self.calls.append(_n)
            )
            patch.start()
            self.addCleanup(patch.stop)

    def test_full_disk_checks_json_layout_then_stream(self):
        ctx = types.SimpleNamespace(
            is_protected=False, target=Path("/mnt"),
            user_configuration={"disk_config": btrfs_root_layout()},
        )
        phases_impl.prepare_install_target(ctx)
        self.assertEqual(self.calls, ["verify_root_image_layout", "verify_root_image_stream"])

    def test_protected_checks_real_mounts_then_stream(self):
        ctx = types.SimpleNamespace(
            is_protected=True, target=Path("/mnt"),
            user_configuration={"disk_config": {"config_type": "pre_mounted_config"}},
        )
        phases_impl.prepare_install_target(ctx)
        self.assertEqual(
            self.calls,
            ["verify_protected_mounts", "_root_image_target_mounts", "verify_root_image_stream"],
        )


class InstallRootImageTest(unittest.TestCase):
    """A compact Btrfs filesystem is restored, made unique and writable, then
    the layout captured from archinstall is recreated and mounted."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        self.target.mkdir()
        self.state_dir = Path(self.tmp.name) / "state"
        self.state_dir.mkdir()
        self.top = self.state_dir / "image-top"
        self.stream = Path(self.tmp.name) / "omarchy-root.btrfs.qcow2"
        self.stream.write_bytes(b"qcow2")
        self.ctx = types.SimpleNamespace(target=self.target, state_dir=self.state_dir)

        self.mounts = [
            {"target": str(self.target), "source": "/dev/mapper/omarchy_root[/@]",
             "fstype": "btrfs", "options": "rw,noatime,compress=zstd:3,subvolid=256,subvol=/@"},
            {"target": str(self.target / "boot"), "source": "/dev/vda1",
             "fstype": "vfat", "options": "rw,relatime"},
            {"target": str(self.target / "home"), "source": "/dev/mapper/omarchy_root[/@home]",
             "fstype": "btrfs", "options": "rw,noatime,compress=zstd:3,subvolid=257,subvol=/@home"},
            {"target": str(self.target / "var/log"), "source": "/dev/mapper/omarchy_root[/@log]",
             "fstype": "btrfs", "options": "rw,noatime,compress=zstd:3,subvolid=258,subvol=/@log"},
        ]
        self.calls = []
        self.received_packages = {"limine", "omarchy-keyring", "omarchy", "omarchy-settings", "omarchy-nvim"}
        self.make_received_subvolume = True

        def fake_run(cmd, **kwargs):
            self.calls.append(cmd)
            if cmd[0] == "mount" and cmd[1:3] == ["-o", "subvolid=5"]:
                top = Path(cmd[-1])
                if self.make_received_subvolume:
                    received = top / phases_impl.ROOT_IMAGE_SUBVOLUME
                    (received / "var/log").mkdir(parents=True, exist_ok=True)
                    (received / "var/log/pacman.log").write_text("[image] installed base\n")
                    (received / "etc").mkdir()
            elif cmd[:3] == ["btrfs", "subvolume", "snapshot"]:
                shutil.copytree(cmd[3], cmd[4])
            elif cmd[:3] == ["btrfs", "subvolume", "delete"]:
                shutil.rmtree(cmd[3])
            elif cmd[:3] == ["btrfs", "subvolume", "create"]:
                Path(cmd[3]).mkdir(parents=True)
            return CompletedProcess(cmd, 0, stdout="", stderr="")

        def fake_restore(image, device):
            self.assertEqual(image, self.stream)
            self.assertEqual(device, "/dev/mapper/omarchy_root")
            self.calls.append(["qemu-img", "restore", str(image), device])

        patches = [
            mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run),
            mock.patch.object(phases_impl, "capture_identifier", return_value="40800092160"),
            mock.patch.object(phases_impl, "_findmnt_mounts", return_value=self.mounts),
            mock.patch.object(phases_impl, "_root_image_virtual_size", return_value=6174015488),
            mock.patch.object(phases_impl, "_restore_root_image", side_effect=fake_restore),
            mock.patch.object(phases_impl, "_umount_tree",
                              side_effect=lambda root: self.calls.append(["umount", "-R", str(root)])),
            mock.patch.object(phases_impl, "_root_image_required_packages",
                              return_value=["limine", "omarchy-keyring", "omarchy"]),
            mock.patch.object(phases_impl.arch, "target_has_package", create=True,
                              side_effect=lambda target, pkg: pkg in self.received_packages),
            mock.patch.object(phases_impl, "ROOT_IMAGE_STREAM", self.stream),
            mock.patch.object(phases_impl, "info"),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def btrfs_calls(self):
        return [cmd for cmd in self.calls if cmd[0] == "btrfs"]

    def test_restores_unique_filesystem_and_makes_image_the_root(self):
        phases_impl._install_root_image(self.ctx)

        top = str(self.top)
        received = f"{top}/{phases_impl.ROOT_IMAGE_SUBVOLUME}"
        self.assertEqual(self.calls[0], ["umount", "-R", str(self.target)])
        self.assertEqual(
            self.calls[1],
            ["qemu-img", "restore", str(self.stream), "/dev/mapper/omarchy_root"],
        )
        self.assertEqual(
            self.calls[2], ["btrfstune", "-f", "-u", "/dev/mapper/omarchy_root"]
        )
        self.assertEqual(
            self.calls[3], ["mount", "-o", "subvolid=5", "/dev/mapper/omarchy_root", top]
        )
        self.assertEqual(
            self.btrfs_calls(),
            [
                ["btrfs", "filesystem", "resize", "max", top],
                ["btrfs", "property", "set", "-ts", received, "ro", "false"],
                ["btrfs", "subvolume", "create", f"{top}/@home"],
                ["btrfs", "subvolume", "create", f"{top}/@log"],
            ],
        )
        self.assertTrue((self.top / "@" / "etc").is_dir())
        self.assertFalse((self.top / phases_impl.ROOT_IMAGE_SUBVOLUME).exists())

    def test_preserves_nested_directories_without_snapshotting_or_deleting_root(self):
        nested = self.top / phases_impl.ROOT_IMAGE_SUBVOLUME / "var/lib/machines"
        original_run = phases_impl.subprocess.run.side_effect

        def with_nested(cmd, **kwargs):
            result = original_run(cmd, **kwargs)
            if cmd[0] == "mount" and cmd[1:3] == ["-o", "subvolid=5"]:
                nested.mkdir(parents=True, exist_ok=True)
                (nested / "kept").write_text("complete\n")
            return result

        phases_impl.subprocess.run.side_effect = with_nested
        phases_impl._install_root_image(self.ctx)

        self.assertEqual((self.top / "@/var/lib/machines/kept").read_text(), "complete\n")
        self.assertFalse(any(cmd[:3] == ["btrfs", "subvolume", "snapshot"] for cmd in self.calls))
        self.assertFalse(any(cmd[:3] == ["btrfs", "subvolume", "delete"] for cmd in self.calls))

    def test_replays_mounts_without_subvolid(self):
        phases_impl._install_root_image(self.ctx)

        top_umount = self.calls.index(["umount", str(self.top)])
        remounts = [cmd for cmd in self.calls[top_umount + 1:] if cmd[0] == "mount"]
        self.assertEqual(
            remounts,
            [
                ["mount", "-t", "btrfs", "-o", "rw,noatime,compress=zstd:3,subvol=/@",
                 "/dev/mapper/omarchy_root", str(self.target)],
                ["mount", "-t", "vfat", "-o", "rw,relatime", "/dev/vda1", str(self.target / "boot")],
                ["mount", "-t", "btrfs", "-o", "rw,noatime,compress=zstd:3,subvol=/@home",
                 "/dev/mapper/omarchy_root", str(self.target / "home")],
                ["mount", "-t", "btrfs", "-o", "rw,noatime,compress=zstd:3,subvol=/@log",
                 "/dev/mapper/omarchy_root", str(self.target / "var/log")],
            ],
        )
        # The top level is released before replaying the user-visible layout;
        # per-machine identity is set only after the new root is mounted.
        self.assertLess(
            self.calls.index(["umount", str(self.top)]),
            self.calls.index(remounts[0]),
        )
        self.assertEqual(self.calls[-1], ["systemd-machine-id-setup", f"--root={self.target}"])

    def test_carries_image_pacman_log_into_log_subvolume(self):
        phases_impl._install_root_image(self.ctx)
        self.assertEqual((self.top / "@log/pacman.log").read_text(), "[image] installed base\n")

    def test_image_larger_than_target_fails_before_unmount(self):
        phases_impl._root_image_virtual_size.return_value = 50000000000
        with self.assertRaisesRegex(RuntimeError, "root image needs.*has only"):
            phases_impl._install_root_image(self.ctx)
        self.assertNotIn(["umount", "-R", str(self.target)], self.calls)
        phases_impl._restore_root_image.assert_not_called()

    def test_missing_image_subvolume_preserves_original_error_without_invalid_remount(self):
        self.make_received_subvolume = False
        with self.assertRaisesRegex(RuntimeError, "has no omarchy-root subvolume"):
            phases_impl._install_root_image(self.ctx)
        self.assertIn(["umount", str(self.top)], self.calls)
        self.assertFalse(any(cmd[0] == "mount" and cmd[-1] == str(self.target) for cmd in self.calls))

    def test_missing_required_package_fails_after_the_swap(self):
        self.received_packages.discard("omarchy")
        with self.assertRaisesRegex(RuntimeError, "lacks required packages: omarchy"):
            phases_impl._install_root_image(self.ctx)
        # The layout is back in place and the top level released either way.
        self.assertIn(["umount", str(self.top)], self.calls)
        self.assertTrue((self.top / "@" / "etc").is_dir())

    def test_restore_failure_does_not_try_to_mount_a_partial_filesystem(self):
        phases_impl._restore_root_image.side_effect = RuntimeError("root filesystem restore failed")
        with self.assertRaisesRegex(RuntimeError, "root filesystem restore failed"):
            phases_impl._install_root_image(self.ctx)
        self.assertEqual(self.calls, [["umount", "-R", str(self.target)]])

    def test_layout_subvolumes_are_derived_without_duplicates_or_root(self):
        mounts = [*self.mounts, dict(self.mounts[2])]
        self.assertEqual(
            phases_impl._layout_subvolumes(mounts, "/dev/mapper/omarchy_root"),
            ["@home", "@log"],
        )


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


class RestoreRootImageTest(unittest.TestCase):
    def test_restore_uses_two_coroutines_per_visible_cpu(self):
        completed = CompletedProcess([], 0, stdout="", stderr="")
        with mock.patch.object(phases_impl.os, "cpu_count", return_value=8), \
             mock.patch.object(phases_impl.subprocess, "run", return_value=completed) as run:
            phases_impl._restore_root_image(Path("/image.qcow2"), "/dev/mapper/root")

        self.assertEqual(run.call_args.args[0][9:11], ["-m", "16"])

    def test_parallel_qcow_restore_never_creates_or_truncates_target(self):
        completed = CompletedProcess([], 0, stdout="", stderr="")
        with mock.patch.object(phases_impl.os, "cpu_count", return_value=48), \
             mock.patch.object(phases_impl.subprocess, "run", return_value=completed) as run:
            phases_impl._restore_root_image(Path("/image.qcow2"), "/dev/mapper/root")

        cmd = run.call_args.args[0]
        self.assertEqual(
            cmd,
            ["qemu-img", "convert", "-q", "-f", "qcow2", "-O", "raw", "-W", "-n",
             "-m", "16", "/image.qcow2", "/dev/mapper/root"],
        )

    def test_restore_failure_includes_qemu_error(self):
        failed = CompletedProcess([], 1, stdout="", stderr="write failed")
        with mock.patch.object(phases_impl.subprocess, "run", return_value=failed):
            with self.assertRaisesRegex(RuntimeError, "restore failed: write failed"):
                phases_impl._restore_root_image(Path("/image.qcow2"), "/dev/vda2")

    def test_virtual_size_comes_from_qcow_metadata(self):
        result = CompletedProcess([], 0, stdout='{"virtual-size": 6174015488}', stderr="")
        with mock.patch.object(phases_impl.subprocess, "run", return_value=result) as run:
            size = phases_impl._root_image_virtual_size(Path("/image.qcow2"))
        self.assertEqual(size, 6174015488)
        self.assertEqual(
            run.call_args.args[0],
            ["qemu-img", "info", "--output=json", "-f", "qcow2", "/image.qcow2"],
        )

    def test_invalid_virtual_size_metadata_is_rejected(self):
        result = CompletedProcess([], 0, stdout='{"virtual-size": 0}', stderr="")
        with mock.patch.object(phases_impl.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(RuntimeError, "invalid virtual size"):
                phases_impl._root_image_virtual_size(Path("/image.qcow2"))


if __name__ == "__main__":
    unittest.main()
