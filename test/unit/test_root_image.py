"""Unit tests for the root image install path in the orchestrator.

Covers the pre-flight checks prepare_install_target runs before the disk is
touched (image present and verified by the boot-time units, a disk layout the
image can land on), the verify progress the dashboard shows, what the written
image owes the later phases, and the target keyring unit. The write and the
reshape are in test_place_root_image.py.
"""

import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import types
import unittest
from contextlib import ExitStack
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

    def test_nested_subvolume_must_sit_at_its_mountpoint(self):
        # A subvolume named inside another is made at that path after the image
        # write, so a mountpoint elsewhere would make it copy into itself or
        # take another mountpoint's files: refused before the disk is touched.
        def with_subvolumes(*extra):
            layout = btrfs_root_layout()
            layout["device_modifications"][0]["partitions"][1]["btrfs"] += [
                {"name": name, "mountpoint": mountpoint} for name, mountpoint in extra]
            return layout

        phases_impl.verify_root_image_layout(with_subvolumes(("@/srv/data", "/srv/data")))
        phases_impl.verify_root_image_layout(with_subvolumes(("@data", "/srv"), ("@data/x", "/srv/x")))
        phases_impl.verify_root_image_layout(with_subvolumes(("@var", "/var"), ("@.snapshots", "/.snapshots")))
        # Also allowed: an extra subvolume between a nested one and its name's
        # parent only when that extra is the parent itself.
        phases_impl.verify_root_image_layout(with_subvolumes(("@var", "/var"), ("@var/lib", "/var/lib")))
        phases_impl.verify_root_image_layout(with_subvolumes(("@/var/log/journal", "/var/log/journal")))
        for extra in ((("@/srv/data", "/srv"),), (("@/usr", "/opt"), ("@system/usr", "/usr")),
                      (("@data", "/srv"), ("@data/x", "/opt/x")),
                      # @/var/lib lives in @'s /var, which @systems/.../var takes away.
                      (("@systems/linux/root/var", "/var"), ("@/var/lib", "/var/lib"))):
            with self.subTest(extra=extra), self.assertRaisesRegex(RuntimeError, "must be mounted at"):
                phases_impl.verify_root_image_layout(with_subvolumes(*extra))

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
                  "omarchy-root.sfs: FAILED")
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

    def test_helper_runs_while_the_hash_is_still_going(self):
        # A medium that stopped answering leaves the unit activating until its
        # size-based timeout (here 3 s). The helper's stall check must get to
        # run during that wait, not after the progress mirroring has sat it out.
        with tempfile.TemporaryDirectory() as tmp:
            stream = Path(tmp) / "omarchy-root.sfs"
            stream.write_bytes(b"\0" * 4096)
            began = time.monotonic()

            def unit_property(prop, unit=None):
                if prop != "ActiveState":
                    return "0"
                return "activating" if time.monotonic() - began < 3 else "failed"

            helper_started = []

            def stalled_helper(cmd, **kwargs):
                helper_started.append(time.monotonic() - began)
                return CompletedProcess(cmd, 1, stdout="", stderr="install medium stopped responding")

            with mock.patch.object(phases_impl, "ROOT_IMAGE", stream), \
                 mock.patch.object(phases_impl, "MIRROR_SUMS", Path(tmp) / "no-sums"), \
                 mock.patch.object(phases_impl, "_verify_unit_property", side_effect=unit_property), \
                 mock.patch.object(phases_impl, "_write_phase_progress"), \
                 mock.patch.object(phases_impl.subprocess, "run", side_effect=stalled_helper):
                with self.assertRaisesRegex(RuntimeError, "stopped responding"):
                    phases_impl.verify_install_medium(self.ctx)
                finished = time.monotonic() - began
        self.assertLess(helper_started[0], 1)
        self.assertLess(finished, 2)

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
            stream = (Path(tmp) / "omarchy-root.sfs").resolve()
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
            stream = tmp / "omarchy-root.sfs"
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
                               Path("/nonexistent/omarchy-root.sfs")), \
             mock.patch.object(phases_impl, "_verify_unit_property") as show:
            phases_impl._publish_verify_progress(ctx=None)
        show.assert_not_called()

    def test_helper_done_wakes_progress_wait_immediately(self):
        import threading

        with tempfile.TemporaryDirectory() as tmp:
            stream = (Path(tmp) / "omarchy-root.sfs").resolve()
            stream.write_bytes(b"\0" * 4096)
            entered = threading.Event()
            done = threading.Event()

            with mock.patch.object(phases_impl, "ROOT_IMAGE", stream), \
                 mock.patch.object(phases_impl, "_mirror_files", return_value=[]), \
                 mock.patch.object(phases_impl, "_verify_unit_property", return_value="activating"), \
                 mock.patch.object(phases_impl, "_hasher_read_pos", return_value=1024), \
                 mock.patch.object(phases_impl, "_write_phase_progress", side_effect=lambda *_: entered.set()):
                thread = threading.Thread(
                    target=phases_impl._publish_verify_progress, args=(None, done), daemon=True,
                )
                thread.start()
                self.assertTrue(entered.wait(timeout=2))
                t0 = time.monotonic()
                done.set()
                thread.join(timeout=2)
                elapsed = time.monotonic() - t0
            self.assertFalse(thread.is_alive())
            self.assertLess(elapsed, 0.2)

    def test_helper_done_wakes_mirror_and_startup_waits_immediately(self):
        import threading

        with tempfile.TemporaryDirectory() as tmp:
            stream = (Path(tmp) / "omarchy-root.sfs").resolve()
            stream.write_bytes(b"\0" * 4096)
            pkg = (Path(tmp) / "a.pkg.tar.zst").resolve()
            pkg.write_bytes(b"\1" * 1024)

            # Mirror loop wakeup
            entered = threading.Event()
            done = threading.Event()
            with mock.patch.object(phases_impl, "ROOT_IMAGE", stream), \
                 mock.patch.object(phases_impl, "_mirror_files", return_value=[(pkg, 1024)]), \
                 mock.patch.object(phases_impl, "_verify_unit_property", return_value="activating"), \
                 mock.patch.object(phases_impl, "_mirror_bytes_hashed", return_value=512), \
                 mock.patch.object(phases_impl, "_write_phase_progress", side_effect=lambda *_: entered.set()):
                thread = threading.Thread(
                    target=phases_impl._publish_verify_progress, args=(None, done), daemon=True,
                )
                thread.start()
                self.assertTrue(entered.wait(timeout=2))
                t0 = time.monotonic()
                done.set()
                thread.join(timeout=2)
                self.assertLess(time.monotonic() - t0, 0.2)

            # _verify_state_when_started retry loop wakeup + short-circuit
            probed = threading.Event()
            done2 = threading.Event()

            def fake_prop(*_args):
                probed.set()
                return "inactive"

            with mock.patch.object(phases_impl, "_verify_unit_property", side_effect=fake_prop) as show:
                thread = threading.Thread(
                    target=phases_impl._verify_state_when_started,
                    args=(phases_impl.MIRROR_VERIFY_UNIT, done2),
                    daemon=True,
                )
                thread.start()
                self.assertTrue(probed.wait(timeout=2))
                t0 = time.monotonic()
                done2.set()
                thread.join(timeout=2)
                self.assertLess(time.monotonic() - t0, 0.15)
                self.assertEqual(show.call_count, 1)

            # Already-set event makes _publish_verify_progress skip systemctl entirely
            done3 = threading.Event()
            done3.set()
            with mock.patch.object(phases_impl, "_verify_unit_property") as show:
                phases_impl._publish_verify_progress(None, done3)
            show.assert_not_called()


class PrepareInstallTargetTest(unittest.TestCase):
    """prepare_install_target wires the checks together per install mode."""

    def setUp(self):
        self.calls = []
        for name in ("verify_protected_mounts", "verify_install_medium",
                     "verify_root_image_layout", "verify_pre_mounted_root_empty"):
            patch = mock.patch.object(
                phases_impl, name, side_effect=lambda *a, _n=name, **k: self.calls.append(_n)
            )
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(
            phases_impl, "_root_image_target_mounts",
            side_effect=lambda *a: self.calls.append("_root_image_target_mounts") or ([], "/dev/vda2"),
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
            ["verify_protected_mounts", "_root_image_target_mounts",
             "verify_pre_mounted_root_empty", "verify_install_medium"],
        )


class VerifyPreMountedRootEmptyTest(unittest.TestCase):
    """The root image is written over the whole btrfs behind a pre-mounted @,
    so a pre-mounted target must be a freshly made filesystem. The stand-in
    for mount fills the top level the check mounts with a layout."""

    DEVICE = "/dev/mapper/omarchy_root"

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.ctx = types.SimpleNamespace(
            is_protected=True, target=Path("/mnt"), state_dir=Path(tmp.name) / "state",
            user_configuration={"disk_config": {"config_type": "pre_mounted_config"}},
        )
        self.calls = []
        for name in ("verify_protected_mounts", "verify_install_medium"):
            patch = mock.patch.object(phases_impl, name)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(phases_impl, "_root_image_target_mounts",
                                  return_value=([], self.DEVICE))
        patch.start()
        self.addCleanup(patch.stop)

    def check(self, layout, umount_fails=False):
        """layout: paths under the top level; a trailing / makes a directory,
        "a -> b" a symlink."""
        def fake_run(argv, **kwargs):
            argv = [str(a) for a in argv]
            self.calls.append(argv)
            if argv[:3] == ["mount", "-o", "ro,subvolid=5"]:
                top = Path(argv[4])
                for path in layout:
                    if " -> " in path:
                        link, dest = path.split(" -> ")
                        (top / link).symlink_to(dest)
                    elif path.endswith("/"):
                        (top / path).mkdir(parents=True, exist_ok=True)
                    else:
                        (top / path).parent.mkdir(parents=True, exist_ok=True)
                        (top / path).write_text("data\n")
            elif argv[0] == "umount":
                if umount_fails:
                    if kwargs.get("check"):
                        raise subprocess.CalledProcessError(32, argv)
                    return subprocess.CompletedProcess(argv, 32, "", "")
                shutil.rmtree(argv[1])
                Path(argv[1]).mkdir()
            return subprocess.CompletedProcess(argv, 0, "", "")

        with mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run), \
             mock.patch.object(phases_impl, "info"):
            phases_impl.prepare_install_target(self.ctx)

    # What the configurator hands over: four new subvolumes, and in @ the
    # directories it mounts the others and the ESP on.
    FRESH = ["@/home/", "@/var/log/", "@/var/cache/pacman/pkg/", "@/boot/",
             "@home/", "@log/", "@pkg/"]

    def test_configurators_fresh_filesystem_passes(self):
        self.check(self.FRESH)
        self.assertEqual(self.calls[-1][0], "umount")

    def test_file_in_home_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, r"@home/emir/notes.txt.*fresh"):
            self.check(self.FRESH + ["@home/emir/notes.txt"])
        self.assertEqual(self.calls[-1][0], "umount")

    def test_other_subvolume_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, r"found @snapshots\b"):
            self.check(self.FRESH + ["@snapshots/1/"])

    def test_file_in_root_subvolume_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, r"@/etc/fstab"):
            self.check(self.FRESH + ["@/etc/fstab"])

    def test_symlink_to_a_directory_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, r"@home/emir"):
            self.check(self.FRESH + ["@home/emir -> /"])

    def test_top_level_left_mounted_fails_the_check(self):
        # A top level still mounted would keep the device busy, or be
        # written under, when the image goes over it.
        with self.assertRaises(subprocess.CalledProcessError):
            self.check(self.FRESH, umount_fails=True)

    def test_top_level_is_mounted_read_only_on_the_root_device(self):
        self.check(self.FRESH)
        mount = next(c for c in self.calls if c[0] == "mount")
        self.assertEqual(mount[:4], ["mount", "-o", "ro,subvolid=5", self.DEVICE])


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
        def fake_run(cmd, **kw):
            self.calls.append(cmd)
            return CompletedProcess(cmd, 0, stdout="", stderr="")

        for patch in (
            mock.patch.object(phases_impl, "_root_image_required_packages",
                              return_value=["limine", "omarchy-keyring", "omarchy"]),
            mock.patch.object(phases_impl.arch, "target_package_names", create=True,
                              side_effect=lambda target: self.packages),
            mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def test_sets_up_the_machine_id(self):
        phases_impl._finish_root_image(self.ctx)
        self.assertIn(["systemd-machine-id-setup", f"--root={self.ctx.target}"], self.calls)

    def test_prepares_nocow_journal_directory(self):
        phases_impl._finish_root_image(self.ctx)
        journal_dir = self.ctx.target / "var" / "log" / "journal"
        self.assertTrue(journal_dir.is_dir())
        self.assertIn(["chattr", "+C", str(journal_dir)], self.calls)

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
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        self.state_dir = Path(self.tmp.name) / "run"
        self.ctx = types.SimpleNamespace(target=self.target, state_dir=self.state_dir, state={})
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
            # The x86_64 unit, whatever machine runs the tests.
            mock.patch.object(phases_impl.platform, "machine", return_value="x86_64"),
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
        staged = self.state_dir / "target-gnupg"
        self.assertEqual(
            cmd[8],
            f"rm -rf {staged} && mkdir -m 700 -p {staged} && "
            f"pacman-key --gpgdir {staged} --init && "
            f"pacman-key --gpgdir {staged} "
            f"--populate-from {self.target}/usr/share/pacman/keyrings --populate archlinux omarchy",
        )
        self.assertNotIn("arch-chroot", cmd[8])
        self.assertIs(kwargs["stderr"], phases_impl.subprocess.STDOUT)
        self.assertIsInstance(self.ctx.state["target_keyring_proc"], FakeUnitProc)
        self.assertEqual(self.ctx.state["target_keyring_stage"], staged)

    def test_start_is_idempotent_while_running_or_installed(self):
        phases_impl._start_target_keyring_init(self.ctx)
        phases_impl._start_target_keyring_init(self.ctx)
        self.assertEqual(len(self.popens), 1)

        phases_impl._join_target_keyring_init(self.ctx)
        phases_impl._start_target_keyring_init(self.ctx)
        self.assertEqual(len(self.popens), 1)

    def test_prepare_live_starts_keyring_before_disk_cleanup_when_live_keyrings_exist(self):
        live_keyrings = Path(self.tmp.name) / "live-keyrings"
        live_keyrings.mkdir()
        (live_keyrings / "archlinux.gpg").write_bytes(b"a")
        (live_keyrings / "omarchy.gpg").write_bytes(b"o")

        events = []
        ctx = types.SimpleNamespace(
            target=self.target,
            state_dir=self.state_dir,
            state={},
            is_protected=False,
            user_configuration={"disk_config": {"device_modifications": [{"device": "/dev/vda", "wipe": True}]}},
            arch_config_path=Path("/tmp/cfg.json"),
            creds_path=Path("/tmp/creds.json"),
        )
        with (
            mock.patch.object(phases_impl, "LIVE_KEYRINGS_DIR", live_keyrings),
            mock.patch.object(phases_impl, "_stage_qualcomm_firmware"),
            mock.patch.object(
                phases_impl, "_start_target_keyring_init",
                side_effect=lambda c, *, keyrings_dir=None: events.append(("keyring", keyrings_dir)),
            ),
            mock.patch.object(
                phases_impl, "capture",
                side_effect=lambda cmd: events.append(("cleanup", cmd)) or CompletedProcess(cmd, 0, "", ""),
            ),
            mock.patch.object(phases_impl.arch, "load_arch_config", return_value=object(), create=True),
            mock.patch.object(phases_impl.arch, "make_mirror_handler", return_value=object(), create=True),
        ):
            phases_impl.prepare_live(ctx)

        self.assertEqual(events[0], ("keyring", live_keyrings))
        self.assertEqual(events[1][0], "cleanup")

    def test_prepare_live_skips_keyring_when_live_keyrings_are_missing(self):
        missing_keyrings = Path(self.tmp.name) / "empty-keyrings"
        missing_keyrings.mkdir()

        events = []
        ctx = types.SimpleNamespace(
            target=self.target,
            state_dir=self.state_dir,
            state={},
            is_protected=False,
            user_configuration={"disk_config": {"device_modifications": [{"device": "/dev/vda", "wipe": True}]}},
            arch_config_path=Path("/tmp/cfg.json"),
            creds_path=Path("/tmp/creds.json"),
        )
        with (
            mock.patch.object(phases_impl, "LIVE_KEYRINGS_DIR", missing_keyrings),
            mock.patch.object(phases_impl, "_stage_qualcomm_firmware"),
            mock.patch.object(
                phases_impl, "_start_target_keyring_init",
                side_effect=lambda c, *, keyrings_dir=None: events.append(("keyring", keyrings_dir)),
            ),
            mock.patch.object(
                phases_impl, "capture",
                side_effect=lambda cmd: events.append(("cleanup", cmd)) or CompletedProcess(cmd, 0, "", ""),
            ),
            mock.patch.object(phases_impl.arch, "load_arch_config", return_value=object(), create=True),
            mock.patch.object(phases_impl.arch, "make_mirror_handler", return_value=object(), create=True),
        ):
            phases_impl.prepare_live(ctx)

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0][0], "cleanup")

    def test_join_installs_staged_keyring_replacing_existing_and_skipping_sockets(self):
        staged = self.state_dir / "target-gnupg"
        (staged / "private-keys-v1.d").mkdir(parents=True)
        (staged / "pubring.gpg").write_bytes(b"pubring")
        key_file = staged / "private-keys-v1.d" / "master.key"
        key_file.write_bytes(b"secret")
        key_file.chmod(0o600)
        sock_path = staged / "S.gpg-agent"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.bind(str(sock_path))
            existing = self.target / "etc" / "pacman.d" / "gnupg"
            existing.mkdir(parents=True)
            (existing / "stale.txt").write_text("from pacstrap\n")

            self.ctx.state["target_keyring_proc"] = FakeUnitProc()
            self.ctx.state["target_keyring_stage"] = staged
            phases_impl._join_target_keyring_init(self.ctx)
        finally:
            sock.close()

        self.assertEqual((existing / "pubring.gpg").read_bytes(), b"pubring")
        self.assertEqual((existing / "private-keys-v1.d" / "master.key").read_bytes(), b"secret")
        self.assertEqual(existing.stat().st_mode & 0o777, 0o700)
        self.assertFalse((existing / "stale.txt").exists())
        self.assertFalse((existing / "S.gpg-agent").exists())
        self.assertFalse(staged.exists())

    def test_join_waits_once_and_clears_state(self):
        proc = FakeUnitProc()
        self.ctx.state["target_keyring_proc"] = proc
        phases_impl._join_target_keyring_init(self.ctx)
        phases_impl._join_target_keyring_init(self.ctx)  # no-op: nothing pending
        self.assertEqual(proc.joined, 1)
        self.assertNotIn("target_keyring_proc", self.ctx.state)

    def test_join_raises_with_the_unit_output(self):
        staged = self.state_dir / "target-gnupg"
        staged.mkdir(parents=True)
        self.ctx.state["target_keyring_proc"] = FakeUnitProc(returncode=1, output="gpg: boom\n")
        self.ctx.state["target_keyring_stage"] = staged
        with self.assertRaisesRegex(RuntimeError, r"(?s)keyring init failed \(exit 1\).*gpg: boom"):
            phases_impl._join_target_keyring_init(self.ctx)
        self.assertNotIn("target_keyring_proc", self.ctx.state)
        self.assertFalse(staged.exists())

    def test_stop_ends_the_unit_and_never_raises(self):
        staged = self.state_dir / "target-gnupg"
        staged.mkdir(parents=True)
        (staged / "pubring.gpg").write_bytes(b"partial")
        proc = FakeUnitProc(returncode=1, output="killed")
        self.ctx.state["target_keyring_proc"] = proc
        self.ctx.state["target_keyring_stage"] = staged
        phases_impl.stop_target_keyring_init(self.ctx)
        self.assertEqual(self.runs, [["systemctl", "stop", "omarchy-target-keyring"]])
        self.assertEqual(proc.joined, 1)
        self.assertNotIn("target_keyring_proc", self.ctx.state)
        self.assertFalse(staged.exists())
        self.assertFalse((self.target / "etc" / "pacman.d" / "gnupg").exists())

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

    def test_arch_install_starts_staged_keyring_without_blocking_pacstrap_and_defers_sof(self):
        for tailscale, has_sof_script in ((False, True), (True, True), (False, False)):
            with self.subTest(tailscale=tailscale, has_sof_script=has_sof_script):
                events = []
                app_calls = []
                target = Path(self.tmp.name) / f"mnt-{tailscale}-{has_sof_script}"
                if has_sof_script:
                    sof = target / "usr/share/omarchy/install/hardware/intel/sof-firmware.sh"
                    sof.parent.mkdir(parents=True, exist_ok=True)
                    sof.write_text("#!/bin/bash\n")
                installer = mock.MagicMock()
                installer.create_users.side_effect = lambda users: events.append("create_users")
                installer.add_additional_packages.side_effect = lambda pkgs: events.append(("strap", list(pkgs)))

                def record_install_apps(inst, cfg, *, before_strap=None, skip_packages=()):
                    events.append("install_apps")
                    app_calls.append((before_strap, tuple(skip_packages)))

                config = types.SimpleNamespace(
                    kernels=["linux-omarchy"], locale_config=None, mirror_config=None,
                    swap=types.SimpleNamespace(enabled=True),
                    auth_config=types.SimpleNamespace(users=["dhh"]),
                    app_config=object(), timezone=None, ntp=False, hostname="test",
                    pacman_config="/etc/pacman.conf",
                )
                ctx = types.SimpleNamespace(
                    state={"arch_config_handler": types.SimpleNamespace(config=config), "mirror_handler": None},
                    target=target,
                    state_dir=self.state_dir,
                    tailscale_authkey_path=Path("/tmp/key") if tailscale else None,
                    defer_provisioning=False,
                    omarchy_install={},
                )
                with ExitStack() as stack:
                    for name in (
                        "_mount_offline_package_cache",
                        "_unmount_offline_package_cache",
                        "_mask_mkinitcpio_pacman_hooks",
                        "_unmask_mkinitcpio_pacman_hooks",
                        "_install_root_image",
                        "_apply_platform_layer",
                        "_drop_archinstall_zram_conf",
                        "_write_language_marker",
                        "_write_region_marker",
                        "_write_pre_mounted_fstab",
                    ):
                        stack.enter_context(mock.patch.object(phases_impl, name))
                    stack.enter_context(mock.patch.object(phases_impl, "_platform_delta_packages", return_value=[]))
                    stack.enter_context(mock.patch.object(phases_impl, "_configure_limine_boot", side_effect=lambda *a: events.append("limine")))
                    stack.enter_context(mock.patch.object(phases_impl, "configure_keyboard", return_value=True))
                    stack.enter_context(mock.patch.object(phases_impl, "_start_target_keyring_init", side_effect=lambda c: events.append("start_keyring")))
                    stack.enter_context(mock.patch.object(phases_impl, "_join_target_keyring_init", side_effect=lambda c: events.append("join_keyring")))
                    stack.enter_context(mock.patch.object(phases_impl.arch, "is_pre_mount", return_value=True, create=True))
                    opened = stack.enter_context(mock.patch.object(phases_impl.arch, "open_installer", create=True))
                    stack.enter_context(mock.patch.object(phases_impl.arch, "sanity_check", create=True))
                    stack.enter_context(mock.patch.object(phases_impl.arch, "install_base_delta", side_effect=lambda *a, **kw: events.append("base_delta"), create=True))
                    stack.enter_context(mock.patch.object(phases_impl.arch, "setup_zram_swap", side_effect=lambda inst: events.append("zram"), create=True))
                    stack.enter_context(mock.patch.object(phases_impl.arch, "target_missing_packages", return_value=[], create=True))
                    stack.enter_context(mock.patch.object(phases_impl.arch, "install_applications", side_effect=record_install_apps, create=True))
                    stack.enter_context(mock.patch.object(phases_impl.arch, "root_user", return_value=None, create=True))
                    opened.return_value.__enter__.return_value = installer
                    phases_impl.arch_install_system(ctx)

                self.assertLess(events.index("start_keyring"), events.index("base_delta"))
                self.assertLess(events.index("start_keyring"), events.index("limine"))
                self.assertLess(events.index("start_keyring"), events.index("create_users"))
                self.assertNotIn("join_keyring", events)
                expected_skip = ("sof-firmware",) if has_sof_script else ()
                self.assertEqual(app_calls, [(None, expected_skip)])
                if tailscale:
                    self.assertIn(("strap", ["tailscale"]), events)


class ReflinkSkelCreateUsers(unittest.TestCase):
    def test_reflink_skel_uses_empty_skel_and_chowns_from_target_passwd(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            (target / "etc" / "skel" / ".config").mkdir(parents=True)
            (target / "etc" / "skel" / ".bashrc").write_text("export FOO=1\n")
            (target / "etc" / "passwd").write_text("root:x:0:0:root:/root:/bin/bash\ndhh:x:1001:1001::/home/dhh:/bin/bash\n")
            home = target / "home" / "dhh"
            home.mkdir(parents=True)
            ctx = types.SimpleNamespace(target=target, state={})
            seen_skel = []
            runs = []

            class FakeInstaller:
                def create_users(self, users):
                    seen_skel.append(getattr(self, "_omarchy_empty_skel", None))
                    self.assert_empty = list((target / seen_skel[0].lstrip("/")).iterdir())

            installer = FakeInstaller()
            with mock.patch.object(phases_impl, "_findmnt_value", return_value="btrfs"), \
                    mock.patch.object(phases_impl.subprocess, "run", side_effect=lambda cmd, **kw: runs.append(cmd)):
                phases_impl._create_users_with_reflink_skel(ctx, installer, [types.SimpleNamespace(username="dhh")])

            self.assertEqual(len(seen_skel), 1)
            self.assertTrue(seen_skel[0].startswith("/tmp/omarchy-empty-skel-"))
            self.assertEqual(installer.assert_empty, [])
            self.assertFalse(hasattr(installer, "_omarchy_empty_skel"))
            self.assertEqual(runs[0][:4], ["cp", "-a", "--reflink=auto", "--"])
            self.assertEqual(runs[0][-1], f"{home}/")
            self.assertEqual(runs[1], ["chown", "-hR", "1001:1001", str(home)])


if __name__ == "__main__":
    unittest.main()
