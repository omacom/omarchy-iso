"""Unit tests for the root image install path in the orchestrator.

Covers the pre-flight checks prepare_install_target runs before the disk is
touched (stream present and verified by the boot-time unit, a disk layout
the image can land on) and the destructive subvolume dance in _install_root_image,
asserted on the subprocess calls against a temp target.
"""

import errno
import json
import os
import shlex
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

    def helper_returns(self, returncode=0, stdout="", stderr=""):
        self.captured = {}

        def fake_run(cmd, **kwargs):
            self.captured["cmd"] = cmd
            return CompletedProcess(cmd, returncode, stdout=stdout, stderr=stderr)

        return mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run)

    def test_passes_when_helper_exits_zero(self):
        with self.helper_returns(0, stdout="boot medium: /dev/sda1 on /dev/sda, scheduler: none mq-deadline kyber [bfq]\n"):
            phases_impl.verify_root_image_stream(self.ctx)
        self.assertEqual(self.captured["cmd"], [self.HELPER])
        # The boot medium / scheduler line the helper prints reaches the log.
        self.assertTrue(any("bfq" in m for m in self.infos))

    def test_corrupt_medium_raises_with_the_helpers_message(self):
        stderr = ("install medium is corrupt: re-flash it\n"
                  "sha256 mismatch on the root image\n"
                  "omarchy-root.btrfs.zst: FAILED")
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


class PublishVerifyProgressTest(unittest.TestCase):
    """_publish_verify_progress mirrors the hasher's fdinfo read position into
    phase_progress while the unit is activating. Our own unbuffered fd on a
    temp stream stands in for sha256sum's, with MainPID pointed at this
    process."""

    def test_mirrors_hasher_read_position(self):
        with tempfile.TemporaryDirectory() as tmp:
            stream = (Path(tmp) / "omarchy-root.btrfs.zst").resolve()
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
                               Path("/nonexistent/omarchy-root.btrfs.zst")), \
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
    """The subvolume swap: receive at the top level, snapshot writable, drop
    the empty @, rename the snapshot in, replay the mounts."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        self.target.mkdir()
        self.state_dir = Path(self.tmp.name) / "state"
        self.state_dir.mkdir()
        self.top = self.state_dir / "image-top"
        self.stream = Path(self.tmp.name) / "omarchy-root.btrfs.zst"
        self.stream.write_bytes(b"stream")
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

        def fake_run(cmd, **kwargs):
            self.calls.append(cmd)
            if cmd[0] == "mount" and cmd[1:3] == ["-o", "subvolid=5"]:
                # The top level as archinstall left it: an empty @ and the
                # other subvolumes of the layout.
                top = Path(cmd[-1])
                for name in ("@", "@home", "@log"):
                    (top / name).mkdir(parents=True, exist_ok=True)
            elif cmd[:3] == ["btrfs", "subvolume", "snapshot"]:
                shutil.copytree(cmd[3], cmd[4])
            elif cmd[:3] == ["btrfs", "subvolume", "delete"]:
                shutil.rmtree(cmd[3])
            return CompletedProcess(cmd, 0, stdout="", stderr="")

        def fake_receive(ctx, top, stream_path):
            self.assertEqual(stream_path, self.stream)
            self.calls.append(["btrfs", "receive", str(top)])
            received = top / phases_impl.ROOT_IMAGE_SUBVOLUME
            (received / "var/log").mkdir(parents=True)
            (received / "var/log/pacman.log").write_text("[image] installed base\n")
            (received / "etc").mkdir()

        patches = [
            mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run),
            mock.patch.object(phases_impl, "_findmnt_mounts", return_value=self.mounts),
            mock.patch.object(phases_impl, "_receive_root_image", side_effect=fake_receive),
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

    def test_swaps_received_image_in_for_the_empty_root(self):
        phases_impl._install_root_image(self.ctx)

        top = str(self.top)
        received = f"{top}/{phases_impl.ROOT_IMAGE_SUBVOLUME}"
        self.assertEqual(self.calls[0], ["mount", "-o", "subvolid=5", "/dev/mapper/omarchy_root", top])
        self.assertEqual(
            self.btrfs_calls(),
            [
                ["btrfs", "receive", top],
                ["btrfs", "subvolume", "snapshot", received, f"{top}/@.image"],
                ["btrfs", "subvolume", "delete", received],
                ["btrfs", "subvolume", "delete", f"{top}/@"],
            ],
        )
        # The old @ is deleted only once the layout is unmounted, and the
        # snapshot takes its name.
        unmount = self.calls.index(["umount", "-R", str(self.target)])
        delete_root = self.calls.index(["btrfs", "subvolume", "delete", f"{top}/@"])
        self.assertLess(unmount, delete_root)
        self.assertTrue((self.top / "@" / "etc").is_dir())
        self.assertFalse((self.top / "@.image").exists())
        self.assertFalse((self.top / phases_impl.ROOT_IMAGE_SUBVOLUME).exists())

    def test_replays_mounts_without_subvolid(self):
        phases_impl._install_root_image(self.ctx)

        delete_root = self.calls.index(["btrfs", "subvolume", "delete", f"{self.top}/@"])
        remounts = [cmd for cmd in self.calls[delete_root:] if cmd[0] == "mount"]
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
        # The top level is released last, then per-machine identity is set.
        self.assertEqual(self.calls[-2], ["umount", str(self.top)])
        self.assertEqual(self.calls[-1], ["systemd-machine-id-setup", f"--root={self.target}"])

    def test_carries_image_pacman_log_into_log_subvolume(self):
        phases_impl._install_root_image(self.ctx)
        self.assertEqual((self.top / "@log/pacman.log").read_text(), "[image] installed base\n")

    def test_stale_subvolumes_from_a_previous_attempt_are_removed_first(self):
        original_run = phases_impl.subprocess.run.side_effect

        def run_with_leftovers(cmd, **kwargs):
            result = original_run(cmd, **kwargs)
            if cmd[0] == "mount" and cmd[1:3] == ["-o", "subvolid=5"]:
                top = Path(cmd[-1])
                (top / phases_impl.ROOT_IMAGE_SUBVOLUME).mkdir()
                (top / "@.image").mkdir()
            return result

        phases_impl.subprocess.run.side_effect = run_with_leftovers
        phases_impl._install_root_image(self.ctx)

        top = str(self.top)
        received = f"{top}/{phases_impl.ROOT_IMAGE_SUBVOLUME}"
        self.assertEqual(
            self.btrfs_calls()[:4],
            [
                ["btrfs", "subvolume", "delete", received],
                ["btrfs", "receive", top],
                ["btrfs", "subvolume", "delete", f"{top}/@.image"],
                ["btrfs", "subvolume", "snapshot", received, f"{top}/@.image"],
            ],
        )

    def test_missing_required_package_fails_after_the_swap(self):
        self.received_packages.discard("omarchy")
        with self.assertRaisesRegex(RuntimeError, "lacks required packages: omarchy"):
            phases_impl._install_root_image(self.ctx)
        # The layout is back in place and the top level released either way.
        self.assertIn(["umount", str(self.top)], self.calls)
        self.assertTrue((self.top / "@" / "etc").is_dir())

    def test_receive_failure_releases_top_level_and_keeps_layout_mounted(self):
        phases_impl._receive_root_image.side_effect = RuntimeError("btrfs receive failed")
        with self.assertRaisesRegex(RuntimeError, "btrfs receive failed"):
            phases_impl._install_root_image(self.ctx)
        self.assertEqual(self.calls[-1], ["umount", str(self.top)])
        self.assertNotIn(["umount", "-R", str(self.target)], self.calls)
        self.assertTrue((self.top / "@").is_dir())


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


class ReceiveRootImageTest(unittest.TestCase):
    """The stream-through-zstd-into-btrfs-receive pump, against real children
    on real pipes.

    The decompressor is the real zstd on real fixture streams; btrfs receive
    is stood in for by a shell that drains stdin, so its pipe blocks the way
    the real one does and the child is only reaped when its stdin actually
    reaches EOF (which now takes the decompressor exiting first).
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.state_dir = root / "state"
        self.state_dir.mkdir()
        (self.state_dir / "state.json").write_text("{}")
        self.top = root / "image-top"
        self.received = root / "received"
        self.ctx = types.SimpleNamespace(target=root / "mnt", state_dir=self.state_dir)
        self.procs = []

    def stand_in(self, script):
        """Patch Popen so btrfs receive is this shell script instead, keeping
        the caller's pipes and stderr file. The zstd child spawns for real.

        Fixtures must be built before this arms: subprocess.run resolves
        Popen through the patched module attribute too.
        """

        spawn = subprocess.Popen  # before the patch below replaces it

        def popen(cmd, **kwargs):
            if cmd[0] == "zstd":
                return spawn(cmd, **kwargs)
            self.assertEqual(cmd[:2], ["btrfs", "receive"])
            proc = spawn(["sh", "-c", script], **kwargs)
            self.procs.append(proc)
            return proc

        patch = mock.patch.object(phases_impl.subprocess, "Popen", side_effect=popen)
        patch.start()
        self.addCleanup(patch.stop)

    def drains_stdin(self):
        self.stand_in(f"cat > {shlex.quote(str(self.received))}")

    def compressed(self, data):
        return subprocess.run(
            ["zstd", "-q", "-c", "--long=27"], input=data,
            stdout=subprocess.PIPE, check=True,
        ).stdout

    def stream_file(self, data, raw=False):
        """The shipped artifact: DATA behind the outer zstd layer (or, with
        raw=True, a file that never was a zstd stream)."""
        path = Path(self.tmp.name) / "omarchy-root.btrfs.zst"
        path.write_bytes(data if raw else self.compressed(data))
        return path

    def test_streams_the_file_through_and_reports_done(self):
        stream = self.stream_file(b"x" * (9 << 20))
        self.drains_stdin()
        phases_impl._receive_root_image(self.ctx, self.top, stream)

        self.assertEqual(self.received.read_bytes(), b"x" * (9 << 20))
        self.assertEqual(json.loads((self.state_dir / "state.json").read_text())["phase_progress"], 1.0)

    def test_a_failed_receive_raises_with_its_error_output(self):
        stream = self.stream_file(b"stream")
        self.stand_in("cat > /dev/null; echo 'ERROR: chunk failed' >&2; exit 1")
        with self.assertRaisesRegex(RuntimeError, "btrfs receive failed.*chunk failed"):
            phases_impl._receive_root_image(self.ctx, self.top, stream)

    def test_a_receive_that_dies_at_once_fails_instead_of_blocking(self):
        # With the parent still holding a read end of the decoded pipe, a
        # dead receive would never EPIPE the decompressor and the pump would
        # block on full pipes forever. The payload outsizes every buffer in
        # the pipeline so that hang is reachable. The EPIPE takes the
        # decompressor down too, so the headline names both.
        stream = self.stream_file(b"x" * (9 << 20))
        self.stand_in("exit 1")
        with self.assertRaisesRegex(RuntimeError, "decompression and btrfs receive both failed"):
            phases_impl._receive_root_image(self.ctx, self.top, stream)

    def test_a_corrupt_layer_with_a_failing_receive_names_both(self):
        # The corrupt-medium shape the headline used to get backwards: zstd
        # dies on the junk, the starved receive exits nonzero after it, and
        # the message blamed the receive alone. Neither death order is
        # provable from exit codes, so both are named and the shared detail
        # file carries zstd's own verdict.
        stream = self.stream_file(b"junk that is no zstd frame", raw=True)
        self.stand_in("cat > /dev/null; exit 1")
        with self.assertRaisesRegex(RuntimeError, "decompression and btrfs receive both failed"):
            phases_impl._receive_root_image(self.ctx, self.top, stream)

    def test_a_receive_that_cannot_spawn_reaps_the_decompressor(self):
        # The half-built pipeline: on the live ISO btrfs-progs is guaranteed,
        # so a receive that cannot spawn is close to unreachable -- but a
        # decompressor left alive and blocked on a stdin nobody will ever
        # feed turns that loud failure into a wedged teardown.
        stream = self.stream_file(b"x" * (9 << 20))
        spawn = subprocess.Popen
        zstd_procs = []

        def popen(cmd, **kwargs):
            if cmd[0] == "zstd":
                proc = spawn(cmd, **kwargs)
                zstd_procs.append(proc)
                return proc
            raise FileNotFoundError("btrfs")

        patch = mock.patch.object(phases_impl.subprocess, "Popen", side_effect=popen)
        patch.start()
        self.addCleanup(patch.stop)
        with self.assertRaises(FileNotFoundError):
            phases_impl._receive_root_image(self.ctx, self.top, stream)

        (zstd,) = zstd_procs
        self.assertIsNotNone(zstd.poll())

    def test_an_interrupt_during_spawn_reaps_the_decompressor_too(self):
        # A KeyboardInterrupt aimed at this process alone (not the process
        # group, which reaches zstd directly) lands wherever the interpreter
        # happens to be -- including inside the second Popen. It is a
        # BaseException, so an `except Exception` would skip the cleanup and
        # leak the blocked decompressor while the orchestrator unwinds.
        stream = self.stream_file(b"x" * (9 << 20))
        spawn = subprocess.Popen
        zstd_procs = []

        def popen(cmd, **kwargs):
            if cmd[0] == "zstd":
                proc = spawn(cmd, **kwargs)
                zstd_procs.append(proc)
                return proc
            raise KeyboardInterrupt

        patch = mock.patch.object(phases_impl.subprocess, "Popen", side_effect=popen)
        patch.start()
        self.addCleanup(patch.stop)
        with self.assertRaises(KeyboardInterrupt):
            phases_impl._receive_root_image(self.ctx, self.top, stream)

        (zstd,) = zstd_procs
        self.assertIsNotNone(zstd.poll())

    def test_a_corrupt_outer_layer_fails_as_decompression(self):
        # The boot-time hash normally rejects this first; the pipe is the
        # backstop when the medium rots between hash and receive.
        stream = self.stream_file(b"not a zstd frame at all", raw=True)
        self.drains_stdin()
        with self.assertRaisesRegex(RuntimeError, "decompression failed"):
            phases_impl._receive_root_image(self.ctx, self.top, stream)
        self.assertEqual(self.procs[0].wait(timeout=10), 0)

    def test_a_read_error_off_the_medium_still_closes_and_reaps_the_receive(self):
        # EIO out of a dying stick is the failure the verify machinery exists
        # for. If stdin were left open, the zstd child would sit blocked on it
        # — and btrfs receive behind it — holding the staging mount busy for
        # the caller's silent umount. Random payload so the compressed stream
        # outgrows the 8 MiB first chunk and the EIO lands mid-stream.
        payload = os.urandom(12 << 20)
        stream = DyingStream(self.compressed(payload))
        self.drains_stdin()
        with self.assertRaises(OSError):
            phases_impl._receive_root_image(self.ctx, self.top, stream)

        proc = self.procs[0]
        self.assertEqual(proc.wait(timeout=10), 0)
        received = self.received.read_bytes()
        # What made it through is a flushed prefix of the payload: the
        # truncated tail died in the decompressor, not in the receive.
        self.assertTrue(payload.startswith(received))
        self.assertLess(len(received), len(payload))


class DyingStream:
    """A stream path whose reads give one chunk and then fail like a medium
    that has gone away mid-install."""

    def __init__(self, data):
        self.data = data

    def stat(self):
        return types.SimpleNamespace(st_size=len(self.data))

    def open(self, mode):
        return self

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, size):
        if self.data:
            chunk, self.data = self.data[:size], b""
            return chunk
        raise OSError(errno.EIO, "Input/output error")


if __name__ == "__main__":
    unittest.main()
