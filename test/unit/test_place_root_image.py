"""Unit tests for the root image install's disk steps and the parallel finalize.

_place_root_image runs against a stand-in for subprocess.run that acts
like the tools it calls: mounting the image's top level makes its subvolume
appear, `btrfs subvolume create` makes a directory. What is asserted is the
order the real tools must see (write, new fsid, wait for blkid, then mount)
and the layout left behind (@ from the image, @home/@log/@pkg, pacman.log in
@log, the target's mounts restored). finalize_boot_and_user runs its two
branches at once, waits for both, and raises the first failure."""

import subprocess
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402

DEVICE = "/dev/mapper/ainstvda2"


class InstallRootImageDdTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.target = self.tmp / "mnt"
        self.target.mkdir()
        self.image = self.tmp / "omarchy-root.img.zst"
        self.image.write_bytes(b"\0" * 4096)
        self.ctx = types.SimpleNamespace(target=self.target, state_dir=self.tmp / "state")
        self.mounts = [
            {"target": str(self.target), "source": f"{DEVICE}[/@]", "fstype": "btrfs",
             "options": "rw,noatime,compress=zstd:3,subvolid=256,subvol=/@"},
            {"target": str(self.target / "home"), "source": f"{DEVICE}[/@home]", "fstype": "btrfs",
             "options": "rw,noatime,subvolid=257,subvol=/@home"},
        ]
        self.calls = []

    def fake_run(self, argv, **kwargs):
        argv = [str(a) for a in argv]
        self.calls.append(argv)
        if argv[:3] == ["mount", "-o", "subvolid=5"]:
            log = Path(argv[4]) / phases_impl.ROOT_IMAGE_SUBVOLUME / "var/log/pacman.log"
            log.parent.mkdir(parents=True)
            log.write_text("[2026-01-01] installed base\n")
        elif argv[:3] == ["btrfs", "subvolume", "create"]:
            Path(argv[3]).mkdir()
        elif self.fail_on and argv[: len(self.fail_on)] == self.fail_on:
            raise subprocess.CalledProcessError(1, argv)
        return subprocess.CompletedProcess(argv, 0, "", "")

    def install(self, frames_written=True, fail_on=None):
        self.fail_on = fail_on
        with mock.patch.object(phases_impl, "ROOT_IMAGE", self.image), \
             mock.patch.object(phases_impl, "_root_image_target_mounts", return_value=(self.mounts, DEVICE)), \
             mock.patch.object(phases_impl, "_umount_tree",
                               side_effect=lambda t: self.calls.append(["umount-tree", str(t)])), \
             mock.patch.object(phases_impl, "_write_root_image_frames",
                               side_effect=lambda i, d: self.calls.append(["frames", str(i), d]) or frames_written), \
             mock.patch.object(phases_impl, "_write_root_image_pipe",
                               side_effect=lambda i, d: self.calls.append(["pipe", str(i), d])), \
             mock.patch.object(phases_impl, "_wait_for_blkid_uuid",
                               side_effect=lambda d: self.calls.append(["blkid-wait", d])), \
             mock.patch.object(phases_impl, "_medium_bytes_read", return_value=None), \
             mock.patch.object(phases_impl, "_write_phase_progress"), \
             mock.patch.object(phases_impl, "info"), \
             mock.patch.object(phases_impl.subprocess, "run", side_effect=self.fake_run):
            phases_impl._place_root_image(self.ctx)

    def index(self, prefix):
        for i, call in enumerate(self.calls):
            if call[: len(prefix)] == prefix:
                return i
        self.fail(f"{prefix} never ran: {self.calls}")

    def test_order_the_tools_see(self):
        self.install()
        steps = [["umount-tree"], ["frames"], ["btrfstune", "-f", "-m", DEVICE], ["blkid-wait", DEVICE],
                 ["mount", "-o", "subvolid=5", DEVICE], ["btrfs", "filesystem", "resize", "max"]]
        indices = [self.index(step) for step in steps]
        self.assertEqual(indices, sorted(indices), self.calls)
        self.assertEqual(self.calls[self.index(["frames"])][1:], [str(self.image), DEVICE])

    def test_layout_left_behind(self):
        self.install()
        top = self.ctx.state_dir / "image-top"
        self.assertTrue((top / "@" / "var/log/pacman.log").is_file())
        self.assertFalse((top / phases_impl.ROOT_IMAGE_SUBVOLUME).exists())
        for name in ("@home", "@log", "@pkg"):
            self.assertTrue((top / name).is_dir(), name)
        self.assertEqual((top / "@log" / "pacman.log").read_text(), "[2026-01-01] installed base\n")
        # The top level is unmounted before the target's own mounts return,
        # each from its device (no [/subvol] suffix) with subvol= and no
        # stale subvolid=.
        umount_top = self.index(["umount", str(top)])
        remounts = [c for c in self.calls if c[0] == "mount" and c[1:3] != ["-o", "subvolid=5"]]
        self.assertEqual([c[-2:] for c in remounts],
                         [[DEVICE, str(self.target)], [DEVICE, str(self.target / "home")]])
        self.assertLess(umount_top, self.calls.index(remounts[0]))
        self.assertIn("subvol=/@", remounts[0][2])
        self.assertNotIn("subvolid=", remounts[0][2])

    def test_a_refused_image_goes_through_the_pipe(self):
        self.install(frames_written=False)
        self.assertLess(self.index(["frames"]), self.index(["pipe"]))
        self.assertLess(self.index(["pipe"]), self.index(["btrfstune"]))

    def test_a_failed_reshape_still_unmounts_the_top_level(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.install(fail_on=["btrfs", "filesystem", "resize"])
        top = self.ctx.state_dir / "image-top"
        self.index(["umount", str(top)])
        self.assertFalse(any(c[0] == "mount" and c[1:3] != ["-o", "subvolid=5"] for c in self.calls))


class FinalizeBootAndUserTest(unittest.TestCase):
    def ctx(self, defer=False):
        return types.SimpleNamespace(defer_provisioning=defer)

    def test_the_branches_run_at_the_same_time(self):
        # Each branch waits for the other to have started: only a parallel
        # run gets past the barrier (a serial one times out on it).
        barrier = threading.Barrier(2, timeout=5)
        seen = {}

        def boot(ctx):
            barrier.wait()
            seen["boot"] = True

        def user(ctx, private_mounts=False):
            barrier.wait()
            seen["user"] = private_mounts

        with mock.patch.object(phases_impl, "finalize_limine_boot", side_effect=boot), \
             mock.patch.object(phases_impl, "run_chroot_finalizer", side_effect=user), \
             mock.patch.dict(phases_impl.os.environ, {}, clear=False):
            phases_impl.os.environ.pop("OMARCHY_SERIAL_FINALIZE", None)
            phases_impl.finalize_boot_and_user(self.ctx())
        # The user chroot gets its own mount namespace.
        self.assertEqual(seen, {"boot": True, "user": True})

    def test_a_failing_branch_is_raised_after_both_finish(self):
        finished = []

        def boot(ctx):
            raise RuntimeError("limine-install failed")

        def user(ctx, private_mounts=False):
            finished.append("user")

        with mock.patch.object(phases_impl, "finalize_limine_boot", side_effect=boot), \
             mock.patch.object(phases_impl, "run_chroot_finalizer", side_effect=user):
            with self.assertRaisesRegex(RuntimeError, "limine-install failed"):
                phases_impl.finalize_boot_and_user(self.ctx())
        self.assertEqual(finished, ["user"])

    def test_deferred_provisioning_runs_them_one_after_the_other(self):
        order = []
        with mock.patch.object(phases_impl, "finalize_limine_boot",
                               side_effect=lambda ctx: order.append("boot")), \
             mock.patch.object(phases_impl, "run_chroot_finalizer",
                               side_effect=lambda ctx, **kw: order.append(("user", kw))):
            phases_impl.finalize_boot_and_user(self.ctx(defer=True))
        self.assertEqual(order, ["boot", ("user", {})])


if __name__ == "__main__":
    unittest.main()
