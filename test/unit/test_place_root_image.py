"""Unit tests for the root image install's disk steps and the parallel finalize.

_place_root_image runs against a stand-in for subprocess.run that acts
like the tools it calls: mounting the image's top level makes its subvolume
appear, `btrfs subvolume create` makes a directory. What is asserted is the
order the real tools must see (write, new fsid, wait for blkid, then mount)
and the layout left behind (@ from the image, @home/@log/@pkg, pacman.log in
@log, the target's mounts restored). finalize_boot_and_user runs its two
branches at once, waits for both, and raises the first failure."""

import os
import shutil
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
        self.image = self.tmp / "omarchy-root.sfs"
        self.image.write_bytes(b"\0" * 4096)
        # The raw image inside it, as _mount_root_image returns it for dd.
        self.raw = self.tmp / "root-image" / "omarchy-root.img"
        self.raw.parent.mkdir()
        self.raw.write_bytes(b"\0" * 4096)
        self.ctx = types.SimpleNamespace(target=self.target, state_dir=self.tmp / "state")
        self.mounts = [
            {"target": str(self.target), "source": f"{DEVICE}[/@]", "fstype": "btrfs",
             "options": "rw,noatime,compress=zstd:3,subvolid=256,subvol=/@"},
            {"target": str(self.target / "home"), "source": f"{DEVICE}[/@home]", "fstype": "btrfs",
             "options": "rw,noatime,subvolid=257,subvol=/@home"},
        ]
        self.calls = []
        self.image_files = []
        self.image_links = []

    def fake_run(self, argv, **kwargs):
        argv = [str(a) for a in argv]
        self.calls.append(argv)
        if argv[:3] == ["mount", "-o", "subvolid=5"]:
            log = Path(argv[4]) / phases_impl.ROOT_IMAGE_SUBVOLUME / "var/log/pacman.log"
            log.parent.mkdir(parents=True)
            log.write_text("[2026-01-01] installed base\n")
            for name in self.image_files:
                f = Path(argv[4]) / phases_impl.ROOT_IMAGE_SUBVOLUME / name
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(name)
            for name, points_to in self.image_links:
                link = Path(argv[4]) / phases_impl.ROOT_IMAGE_SUBVOLUME / name
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(points_to)
        elif argv[:3] == ["btrfs", "subvolume", "create"]:
            Path(argv[3]).mkdir()
        elif argv[:3] == ["cp", "-a", "--reflink=always"]:
            shutil.copytree(argv[3].removesuffix("/."), argv[4], symlinks=True, dirs_exist_ok=True)
        elif argv[:2] == ["cp", "-r"]:
            shutil.copytree(argv[2].removesuffix("/."), argv[3], symlinks=True, dirs_exist_ok=True)
        elif self.fail_on and argv[: len(self.fail_on)] == self.fail_on:
            raise subprocess.CalledProcessError(1, argv)
        return subprocess.CompletedProcess(argv, 0, "", "")

    def fake_dd(self, image, device):
        self.calls.append(["pipe", str(image), device])
        if self.dd_fails:
            raise subprocess.CalledProcessError(1, ["dd"])

    def install(self, frames_written=True, fail_on=None, dd_fails=False):
        self.fail_on = fail_on
        self.dd_fails = dd_fails
        with mock.patch.object(phases_impl, "ROOT_IMAGE", self.image), \
             mock.patch.object(phases_impl, "_root_image_target_mounts", return_value=(self.mounts, DEVICE)), \
             mock.patch.object(phases_impl, "_umount_tree",
                               side_effect=lambda t: self.calls.append(["umount-tree", str(t)])), \
             mock.patch.object(phases_impl, "_mount_root_image",
                               side_effect=lambda c: self.calls.append(["mount-image", str(c)]) or self.raw), \
             mock.patch.object(phases_impl, "_umount_root_image",
                               side_effect=lambda: self.calls.append(["umount-image"])), \
             mock.patch.object(phases_impl, "_write_root_image_parallel",
                               side_effect=lambda i, d: self.calls.append(["frames", str(i), d]) or frames_written), \
             mock.patch.object(phases_impl, "_write_root_image_dd", side_effect=self.fake_dd), \
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
        steps = [["umount-tree"], ["frames"],
                 ["btrfstune", "-f", "-m", DEVICE], ["blkid-wait", DEVICE],
                 ["mount", "-o", "subvolid=5", DEVICE], ["btrfs", "filesystem", "resize", "max"]]
        indices = [self.index(step) for step in steps]
        self.assertEqual(indices, sorted(indices), self.calls)
        # Straight from the squashfs: nothing mounts it.
        self.assertEqual(self.calls[self.index(["frames"])][1:], [str(self.image), DEVICE])
        self.assertFalse(any(c[0] in ("mount-image", "umount-image") for c in self.calls), self.calls)

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

    def test_an_autoinstall_layouts_own_subvolumes_come_back(self):
        # An autoinstall drive can lay the btrfs out with more than the
        # configurator's four. The image write replaces them all, so each one
        # the target had mounted from this device is made again before its
        # mount returns; the ESP, another device, is left to its own mount.
        self.mounts += [
            {"target": str(self.target / "srv"), "source": f"{DEVICE}[/@srv]", "fstype": "btrfs",
             "options": "rw,noatime,subvolid=260,subvol=/@srv"},
            {"target": str(self.target / ".snapshots"), "source": f"{DEVICE}[/@.snapshots]",
             "fstype": "btrfs", "options": "rw,noatime,subvolid=261,subvol=/@.snapshots"},
            {"target": str(self.target / "boot"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"},
        ]
        self.install()
        top = self.ctx.state_dir / "image-top"
        for name in ("@home", "@log", "@pkg", "@srv", "@.snapshots"):
            self.assertTrue((top / name).is_dir(), name)
        created = [c[3] for c in self.calls if c[:3] == ["btrfs", "subvolume", "create"]]
        self.assertNotIn(str(top / "@"), created)
        last_create = max(i for i, c in enumerate(self.calls) if c[:3] == ["btrfs", "subvolume", "create"])
        self.assertLess(last_create, self.index(["mount", "-o", "rw,noatime,subvol=/@srv"]))

    def test_a_subvolume_over_image_files_takes_them_along(self):
        # A separate /var made empty and mounted over the image would hide its
        # package database: the image's files under the mountpoint move into
        # the new subvolume, and the mountpoint is left empty in @.
        self.image_files = ["var/lib/pacman/local/base-3-3/desc", "var/lib/systemd/random-seed"]
        self.mounts.append(
            {"target": str(self.target / "var"), "source": f"{DEVICE}[/@var]", "fstype": "btrfs",
             "options": "rw,noatime,subvolid=262,subvol=/@var"})
        self.install()
        top = self.ctx.state_dir / "image-top"
        self.assertEqual((top / "@var" / "lib/pacman/local/base-3-3/desc").read_text(),
                         "var/lib/pacman/local/base-3-3/desc")
        self.assertTrue((top / "@var" / "lib/systemd/random-seed").is_file())
        self.assertTrue((top / "@" / "var").is_dir())
        self.assertEqual(list((top / "@" / "var").iterdir()), [])
        # @log stays as it was: pacman.log copied, nothing moved out of @.
        self.assertEqual((top / "@log" / "pacman.log").read_text(), "[2026-01-01] installed base\n")

    def test_image_files_under_the_esp_land_on_it(self):
        # The ESP mounts at /boot over the image's /boot, where the kernel
        # package put its device trees; Snapdragon setup reads them from
        # /boot/dtbs. They move out of @ and onto the ESP once it is mounted,
        # as a pacstrap onto the mounted ESP would have left them.
        dtb = "boot/dtbs/linux-omarchy/qcom/x1e80100-lenovo-yoga-slim7x.dtb"
        self.image_files = [dtb]
        self.mounts.append(
            {"target": str(self.target / "boot"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"})
        self.install()
        top = self.ctx.state_dir / "image-top"
        self.assertEqual((self.target / dtb).read_text(), dtb)
        self.assertEqual(list((top / "@" / "boot").iterdir()), [])
        self.assertLess(self.index(["mount", "-o", "rw,relatime,fmask=0077", "/dev/vda1"]),
                        self.index(["cp", "-r"]))
        self.assertFalse((self.ctx.state_dir / "image-under-esp").exists())

    def test_a_stage_left_by_an_earlier_attempt_is_dropped(self):
        dtb = "boot/dtbs/linux-omarchy/qcom/x1e80100-lenovo-yoga-slim7x.dtb"
        self.image_files = [dtb]
        stale = self.ctx.state_dir / "image-under-esp" / "boot" / "dtbs"
        stale.mkdir(parents=True)
        (stale / "stale.dtb").write_text("stale")
        self.mounts.append(
            {"target": str(self.target / "boot"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"})
        self.install()
        self.assertEqual((self.target / dtb).read_text(), dtb)
        self.assertFalse((self.target / "boot/dtbs/stale.dtb").exists())
        self.assertFalse((self.target / "boot/dtbs/dtbs").exists())

    def test_an_esp_below_a_placed_subvolume_gets_its_files_from_it(self):
        # A /boot subvolume takes the image's /boot along; an ESP at
        # /boot/efi below it gets what the image held there.
        self.image_files = ["boot/efi/EFI/BOOT/startup.nsh"]
        self.mounts += [
            {"target": str(self.target / "boot"), "source": f"{DEVICE}[/@boot]", "fstype": "btrfs",
             "options": "rw,noatime,subvolid=262,subvol=/@boot"},
            {"target": str(self.target / "boot/efi"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"},
        ]
        self.install()
        top = self.ctx.state_dir / "image-top"
        self.assertEqual((self.target / "boot/efi/EFI/BOOT/startup.nsh").read_text(),
                         "boot/efi/EFI/BOOT/startup.nsh")
        self.assertEqual(list((top / "@boot" / "efi").iterdir()), [])

    def test_a_subvolume_placed_inside_the_esp_stays_for_its_mount(self):
        self.image_files = ["boot/dtbs/qcom/a.dtb", "boot/limine/BOOTAA64.EFI"]
        self.mounts += [
            {"target": str(self.target / "boot"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"},
            {"target": str(self.target / "boot/dtbs"), "source": f"{DEVICE}[/@/boot/dtbs]", "fstype": "btrfs",
             "options": "rw,noatime,subvolid=264,subvol=/@/boot/dtbs"},
        ]
        self.install()
        top = self.ctx.state_dir / "image-top"
        self.assertEqual((top / "@/boot/dtbs/qcom/a.dtb").read_text(), "boot/dtbs/qcom/a.dtb")
        self.assertEqual((self.target / "boot/limine/BOOTAA64.EFI").read_text(), "boot/limine/BOOTAA64.EFI")
        self.assertFalse((self.target / "boot/dtbs/qcom").exists())

    def test_files_beside_a_subvolume_deep_inside_the_esp_still_land_on_it(self):
        # Only the subvolume stays: its parent directories are walked, and
        # what sits beside it moves onto the ESP.
        self.image_files = ["boot/EFI/Linux/omarchy.efi", "boot/EFI/BOOT/BOOTAA64.EFI", "boot/limine.conf"]
        self.mounts += [
            {"target": str(self.target / "boot"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"},
            {"target": str(self.target / "boot/EFI/Linux"), "source": f"{DEVICE}[/@/boot/EFI/Linux]",
             "fstype": "btrfs", "options": "rw,noatime,subvolid=265,subvol=/@/boot/EFI/Linux"},
        ]
        self.install()
        top = self.ctx.state_dir / "image-top"
        self.assertEqual((top / "@/boot/EFI/Linux/omarchy.efi").read_text(), "boot/EFI/Linux/omarchy.efi")
        self.assertEqual((self.target / "boot/EFI/BOOT/BOOTAA64.EFI").read_text(), "boot/EFI/BOOT/BOOTAA64.EFI")
        self.assertEqual((self.target / "boot/limine.conf").read_text(), "boot/limine.conf")
        self.assertEqual(sorted(p.name for p in (top / "@/boot/EFI").iterdir()), ["Linux"])

    def test_links_land_on_the_esp_as_the_files_they_name(self):
        # FAT has no symlinks: a link is copied as the file it names, read
        # from the image while that is still in place, here inside a
        # subvolume that stays behind.
        self.image_files = ["boot/EFI/Linux/omarchy.efi"]
        self.image_links = [("boot/EFI/current.efi", "Linux/omarchy.efi"), ("boot/gone.efi", "nowhere.efi")]
        self.mounts += [
            {"target": str(self.target / "boot"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"},
            {"target": str(self.target / "boot/EFI/Linux"), "source": f"{DEVICE}[/@/boot/EFI/Linux]",
             "fstype": "btrfs", "options": "rw,noatime,subvolid=265,subvol=/@/boot/EFI/Linux"},
        ]
        self.install()
        current = self.target / "boot/EFI/current.efi"
        self.assertFalse(current.is_symlink())
        self.assertEqual(current.read_text(), "boot/EFI/Linux/omarchy.efi")
        self.assertFalse(os.path.lexists(self.target / "boot/gone.efi"))

    def test_links_are_read_before_anything_is_removed(self):
        # Relative links resolve from where they sit, whatever the order the
        # directory lists them in; a loop is copied once; a link that names
        # nothing is dropped.
        self.image_files = ["boot/kernel.efi", "boot/EFI/omarchy.efi", "boot/dtbs/qcom/a.dtb"]
        self.image_links = [("boot/current.efi", "kernel.efi"), ("boot/EFI/current.efi", "omarchy.efi"),
                            ("boot/dtbs/latest", "qcom"), ("boot/dtbs/qcom/loop", ".."),
                            ("boot/EFI/gone.efi", "missing.efi")]
        self.mounts.append(
            {"target": str(self.target / "boot"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"})
        self.install()
        boot = self.target / "boot"
        self.assertEqual((boot / "current.efi").read_text(), "boot/kernel.efi")
        self.assertEqual((boot / "EFI/current.efi").read_text(), "boot/EFI/omarchy.efi")
        self.assertEqual((boot / "dtbs/latest/a.dtb").read_text(), "boot/dtbs/qcom/a.dtb")
        self.assertFalse(any(p.is_symlink() for p in boot.rglob("*")))
        self.assertFalse(os.path.lexists(boot / "EFI/gone.efi"))
        self.assertEqual(list((self.ctx.state_dir / "image-top" / "@" / "boot").iterdir()), [])

    def test_a_link_across_two_esp_mounts_is_read_before_either_is_emptied(self):
        self.image_files = ["boot/kernel.efi"]
        self.image_links = [("efi/current.efi", "../boot/kernel.efi")]
        self.mounts += [
            {"target": str(self.target / "boot"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"},
            {"target": str(self.target / "efi"), "source": "/dev/vda3", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"},
        ]
        self.install()
        self.assertEqual((self.target / "boot/kernel.efi").read_text(), "boot/kernel.efi")
        self.assertEqual((self.target / "efi/current.efi").read_text(), "boot/kernel.efi")

    def test_an_esp_mounted_inside_another_fat_mount_keeps_its_own_files(self):
        # FAT at /boot and at /boot/efi: each gets what the image held under
        # it, and the outer one leaves the inner mountpoint to it.
        self.image_files = ["boot/dtbs/qcom/a.dtb", "boot/efi/EFI/BOOT/BOOTAA64.EFI"]
        self.mounts += [
            {"target": str(self.target / "boot"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"},
            {"target": str(self.target / "boot/efi"), "source": "/dev/vda3", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"},
        ]
        self.install()
        self.assertEqual((self.target / "boot/dtbs/qcom/a.dtb").read_text(), "boot/dtbs/qcom/a.dtb")
        self.assertEqual((self.target / "boot/efi/EFI/BOOT/BOOTAA64.EFI").read_text(),
                         "boot/efi/EFI/BOOT/BOOTAA64.EFI")
        at_boot = self.ctx.state_dir / "image-top" / "@" / "boot"
        self.assertEqual([p.name for p in at_boot.iterdir()], ["efi"])
        self.assertEqual(list((at_boot / "efi").iterdir()), [])

    def test_other_filesystems_are_left_to_their_own_mounts(self):
        self.image_files = ["srv/data/readme"]
        self.mounts.append(
            {"target": str(self.target / "srv/data"), "source": "/dev/vdb1", "fstype": "ext4",
             "options": "rw,relatime"})
        self.install()
        top = self.ctx.state_dir / "image-top"
        self.assertEqual((top / "@" / "srv/data/readme").read_text(), "srv/data/readme")
        self.assertFalse(any(c[:2] == ["cp", "-r"] for c in self.calls), self.calls)

    def test_nothing_is_copied_when_the_image_has_nothing_under_the_esp(self):
        self.mounts.append(
            {"target": str(self.target / "boot"), "source": "/dev/vda1", "fstype": "vfat",
             "options": "rw,relatime,fmask=0077"})
        self.install()
        self.assertFalse(any(c[:2] == ["cp", "-r"] for c in self.calls), self.calls)

    def test_a_subvolume_named_inside_at_becomes_one(self):
        # A name nested in @ (@/srv/data) is a plain directory in the image;
        # it becomes a subvolume holding what that directory held.
        self.image_files = ["srv/data/readme"]
        self.mounts.append(
            {"target": str(self.target / "srv/data"), "source": f"{DEVICE}[/@/srv/data]", "fstype": "btrfs",
             "options": "rw,noatime,subvolid=263,subvol=/@/srv/data"})
        self.install()
        top = self.ctx.state_dir / "image-top"
        created = [c[3] for c in self.calls if c[:3] == ["btrfs", "subvolume", "create"]]
        self.assertIn(str(top / "@/srv/data"), created)
        self.assertEqual((top / "@/srv/data/readme").read_text(), "srv/data/readme")
        self.assertEqual(sorted(p.name for p in (top / "@/srv").iterdir()), ["data"])

    def test_a_refused_image_goes_through_the_pipe(self):
        # dd reads the file inside the mounted squashfs, and the mount goes
        # away before the image is touched again.
        self.install(frames_written=False)
        steps = [["frames"], ["mount-image", str(self.image)], ["pipe", str(self.raw), DEVICE],
                 ["umount-image"], ["btrfstune"]]
        indices = [self.index(step) for step in steps]
        self.assertEqual(indices, sorted(indices), self.calls)

    def test_a_failed_pipe_still_unmounts_the_image(self):
        with self.assertRaises(subprocess.CalledProcessError):
            self.install(frames_written=False, dd_fails=True)
        self.assertLess(self.index(["pipe"]), self.index(["umount-image"]))

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
