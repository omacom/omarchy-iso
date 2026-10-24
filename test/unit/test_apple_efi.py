#!/usr/bin/python

"""Carrying EFI/APPLE across a wipe, without the disk or the mounts.

The mount seam (`_mounted_ro`) is replaced with directories on disk, so these
exercise the real copy, the real preference rule and the real verification —
everything except the two commands that need a block device and root.
"""

import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import apple_efi  # noqa: E402

# What a Touch Bar Mac's ESP actually holds, small enough to write per test.
FIRMWARE = {
    "EFI/APPLE/EMBEDDEDOS/EmbeddedOSFirmware.im4p": b"\x00im4p" * 64,
    "EFI/APPLE/EMBEDDEDOS/FDRData": b"fdr" * 32,
    "EFI/APPLE/EXTENSIONS/Firmware.scap": b"scap" * 16,
}
OTHER_ESP = {"EFI/BOOT/BOOTX64.EFI": b"MZ", "EFI/Microsoft/Boot/bootmgfw.efi": b"MZ"}


def write_tree(root: Path, files: dict) -> Path:
    for name, contents in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
    return root


def read_tree(root: Path) -> dict:
    return {
        str(path.relative_to(root)): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


class AppleEfiTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.tmp = Path(directory.name)
        self.stash = self.tmp / "state" / "apple-efi"

        self.logged = []
        self.patch("info", self.logged.append)

    def esp(self, name: str, files: dict) -> Path:
        """A directory standing in for a mounted ESP."""
        return write_tree(self.tmp / name, files)

    def fake_disk(self, partitions: dict) -> None:
        """Make /dev/... names resolve to those directories instead of mounts.

        A None stands for a partition that would not mount.
        """
        @contextmanager
        def mounted(partition):
            yield partitions[partition]

        self.patch("_vfat_partitions", lambda disk: list(partitions))
        self.patch("_mounted_ro", mounted)

    def patch(self, name, replacement):
        patcher = mock.patch.object(apple_efi, name, replacement)
        patcher.start()
        self.addCleanup(patcher.stop)

    def log(self) -> str:
        return "\n".join(self.logged)

    def test_the_firmware_folder_is_found_and_copied_off_the_disk(self):
        self.fake_disk({"/dev/sda1": self.esp("sda1", FIRMWARE)})

        self.assertEqual(apple_efi.preserve("/dev/sda", self.stash), self.stash)
        self.assertEqual(
            read_tree(self.stash),
            {
                "EMBEDDEDOS/EmbeddedOSFirmware.im4p": FIRMWARE[
                    "EFI/APPLE/EMBEDDEDOS/EmbeddedOSFirmware.im4p"
                ],
                "EMBEDDEDOS/FDRData": FIRMWARE["EFI/APPLE/EMBEDDEDOS/FDRData"],
                "EXTENSIONS/Firmware.scap": FIRMWARE["EFI/APPLE/EXTENSIONS/Firmware.scap"],
            },
        )
        self.assertIn("preserved Apple coprocessor firmware", self.log())

    def test_a_disk_with_no_apple_folder_is_left_alone(self):
        self.fake_disk({"/dev/sda1": self.esp("sda1", OTHER_ESP)})

        self.assertIsNone(apple_efi.preserve("/dev/sda", self.stash))
        self.assertFalse(self.stash.exists())
        self.assertEqual(len(self.logged), 1)
        self.assertIn("no Apple coprocessor firmware", self.log())

    def test_the_esp_holding_the_firmware_wins_over_one_that_only_looks_apple(self):
        # A stale EFI/APPLE left by a macOS install that is no longer the one
        # the Mac boots its coprocessor from.
        decoy = self.esp("sda1", {"EFI/APPLE/README": b"stale"})
        real = self.esp("sda2", FIRMWARE)
        self.fake_disk({"/dev/sda1": decoy, "/dev/sda2": real})

        apple_efi.preserve("/dev/sda", self.stash)

        self.assertTrue((self.stash / "EMBEDDEDOS/FDRData").is_file())
        self.assertFalse((self.stash / "README").exists())
        self.assertIn("/dev/sda2", self.log())

    def test_what_the_wipe_would_have_destroyed_is_on_the_new_esp(self):
        self.fake_disk({"/dev/sda1": self.esp("sda1", FIRMWARE)})
        apple_efi.preserve("/dev/sda", self.stash)

        new_esp = self.tmp / "mnt" / "boot"
        new_esp.mkdir(parents=True)

        self.assertTrue(apple_efi.restore(new_esp, self.stash))
        self.assertEqual(
            read_tree(new_esp / "EFI/APPLE"),
            read_tree(self.tmp / "sda1" / "EFI/APPLE"),
        )
        self.assertIn("restored Apple coprocessor firmware", self.log())

    def test_nothing_preserved_means_nothing_written_to_the_new_esp(self):
        new_esp = self.tmp / "mnt" / "boot"
        new_esp.mkdir(parents=True)

        self.assertFalse(apple_efi.restore(new_esp, self.stash))
        self.assertEqual(read_tree(new_esp), {})

    def test_a_short_restore_is_reported_rather_than_claimed(self):
        self.fake_disk({"/dev/sda1": self.esp("sda1", FIRMWARE)})
        apple_efi.preserve("/dev/sda", self.stash)
        new_esp = self.tmp / "mnt" / "boot"
        new_esp.mkdir(parents=True)

        def half_a_copy(source, destination, dirs_exist_ok=False):
            Path(destination).mkdir(parents=True, exist_ok=True)
            (Path(destination) / "FDRData").write_bytes(b"truncated")

        with mock.patch.object(apple_efi.shutil, "copytree", half_a_copy):
            self.assertFalse(apple_efi.restore(new_esp, self.stash))

        self.assertNotIn("restored Apple coprocessor firmware", self.log())
        self.assertIn("warning", self.log())

    def test_an_unreadable_source_warns_and_lets_the_install_continue(self):
        self.fake_disk({"/dev/sda1": self.esp("sda1", FIRMWARE)})

        with mock.patch.object(
            apple_efi.shutil, "copytree", side_effect=PermissionError("EFI/APPLE")
        ):
            self.assertIsNone(apple_efi.preserve("/dev/sda", self.stash))

        self.assertIn("warning: could not preserve", self.log())

    def test_a_folder_too_big_for_the_live_system_is_not_copied(self):
        self.fake_disk({"/dev/sda1": self.esp("sda1", FIRMWARE)})
        self.patch("MAX_STASH_BYTES", 8)

        self.assertIsNone(apple_efi.preserve("/dev/sda", self.stash))
        self.assertFalse(self.stash.exists())
        self.assertIn("warning: not preserving", self.log())

    def test_a_partition_that_will_not_mount_is_skipped(self):
        self.fake_disk({"/dev/sda1": None, "/dev/sda2": self.esp("sda2", FIRMWARE)})

        self.assertEqual(apple_efi.preserve("/dev/sda", self.stash), self.stash)
        self.assertIn("/dev/sda2", self.log())


if __name__ == "__main__":
    unittest.main()
