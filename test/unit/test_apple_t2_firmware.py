"""Apple T2 firmware is saved before partitioning and restored afterwards."""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import apple_t2_firmware  # noqa: E402


class AppleT2FirmwareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.pci = self.root / "pci"
        self.firmware = self.root / "live-firmware"
        self.manifest = self.root / "installed-files"
        self.stage = self.root / "stage"
        self.fetcher = self.root / "apple-bcm-firmware-fetcher"
        self.pci.mkdir()
        self.firmware.mkdir()
        self.fetcher.touch()

    def hardware(self, vendor="0x106b", device="0x1801"):
        slot = self.pci / "0000:01:00.0"
        slot.mkdir(exist_ok=True)
        (slot / "vendor").write_text(vendor + "\n")
        (slot / "device").write_text(device + "\n")

    def stage_firmware(self, files):
        def fetched(*_args, **_kwargs):
            for name, content in files.items():
                (self.firmware / name).write_bytes(content)
            self.manifest.write_text("".join(f"{name}\n" for name in files))
            return subprocess.CompletedProcess([], 0)

        with mock.patch.object(apple_t2_firmware.subprocess, "run", side_effect=fetched):
            return apple_t2_firmware.stage_from_macos(
                pci_devices=self.pci,
                fetcher=self.fetcher,
                firmware=self.firmware,
                manifest=self.manifest,
                stage=self.stage,
            )

    def test_only_exact_t2_pci_ids_are_detected(self):
        for vendor, device, expected in [
            ("0x106b", "0x1801", True),
            ("0x106b", "0x1802", True),
            ("0x106b", "0x2001", False),
            ("0x8086", "0x1801", False),
        ]:
            with self.subTest(vendor=vendor, device=device):
                self.hardware(vendor, device)
                self.assertEqual(apple_t2_firmware.is_apple_t2(self.pci), expected)

    def test_non_t2_machine_does_not_run_the_fetcher(self):
        self.hardware("0x106b", "0x2001")
        with mock.patch.object(apple_t2_firmware.subprocess, "run") as run:
            result = apple_t2_firmware.stage_from_macos(
                pci_devices=self.pci, fetcher=self.fetcher,
                firmware=self.firmware, manifest=self.manifest, stage=self.stage,
            )
        self.assertIsNone(result)
        run.assert_not_called()
        self.assertFalse(self.stage.exists())

    def test_stage_and_target_round_trip_preserves_exact_files(self):
        self.hardware()
        files = {
            "brcmfmac4364b2-pcie.apple,foo.bin": b"wifi",
            "brcmfmac4364b2-pcie.apple,foo.clm_blob": b"regulatory",
            "brcmbt4377b3-apple,bar-m.bin": b"bluetooth",
        }
        self.assertEqual(self.stage_firmware(files), len(files))

        target = self.root / "target"
        self.assertEqual(apple_t2_firmware.install_into_target(target, self.stage), len(files))
        for name, content in files.items():
            self.assertEqual((target / apple_t2_firmware.TARGET_FIRMWARE / name).read_bytes(), content)
        self.assertEqual(
            (target / apple_t2_firmware.TARGET_STATE).read_text().splitlines(),
            list(files),
        )

    def test_unsafe_or_missing_manifest_entries_are_not_staged(self):
        self.hardware()

        def fetched(*_args, **_kwargs):
            (self.firmware / "valid.bin").write_bytes(b"ok")
            self.manifest.write_text("../escape\nsubdir/file\nmissing.bin\nvalid.bin\n")
            return subprocess.CompletedProcess([], 0)

        with mock.patch.object(apple_t2_firmware.subprocess, "run", side_effect=fetched):
            count = apple_t2_firmware.stage_from_macos(
                pci_devices=self.pci, fetcher=self.fetcher,
                firmware=self.firmware, manifest=self.manifest, stage=self.stage,
            )
        self.assertEqual(count, 1)
        self.assertEqual((self.stage / "installed-files").read_text(), "valid.bin\n")

    def test_stage_over_the_file_limit_is_refused(self):
        self.hardware()
        with mock.patch.object(apple_t2_firmware, "MAX_FILES", 1):
            count = self.stage_firmware({"one.bin": b"1", "two.bin": b"2"})
        self.assertEqual(count, 0)
        self.assertFalse(self.stage.exists())

    def test_target_copy_must_verify(self):
        self.hardware()
        self.assertEqual(self.stage_firmware({"firmware.bin": b"data"}), 1)
        with mock.patch.object(apple_t2_firmware, "_digest", side_effect=["source", "different"]):
            with self.assertRaisesRegex(RuntimeError, "did not verify"):
                apple_t2_firmware.install_into_target(self.root / "target", self.stage)

    def test_fetch_failure_leaves_no_stage(self):
        self.hardware()
        self.stage.mkdir()
        (self.stage / "stale").write_text("must not survive a retry")
        with mock.patch.object(
            apple_t2_firmware.subprocess, "run",
            return_value=subprocess.CompletedProcess([], 1),
        ):
            result = apple_t2_firmware.stage_from_macos(
                pci_devices=self.pci, fetcher=self.fetcher,
                firmware=self.firmware, manifest=self.manifest, stage=self.stage,
            )
        self.assertEqual(result, 0)
        self.assertFalse(self.stage.exists())

    def test_x86_live_image_extracts_a_pinned_fetcher_without_its_hook(self):
        builder = (ROOT / "builder/build-iso.sh").read_text()
        live_packages = re.search(
            r'^if \[\[ \$OMARCHY_ARCH == aarch64 \]\]; then\n.*?^else\n(?P<x86>.*?)^fi\nlive_packages_file=',
            builder, re.M | re.S,
        )
        self.assertIsNotNone(live_packages)
        self.assertNotIn("apple-bcm-firmware-fetcher", live_packages.group("x86"))
        self.assertIn('bsdtar -xOf "$t2_fetcher_archive" usr/bin/apple-bcm-firmware-fetcher', builder)
        self.assertIn("7f6e23722c3ab26a7674b535c4ea899c0764f67281f945ae25cc30c730b525e2", builder)
        self.assertIn("873f78849627293781c6eb7c7a36d9a621a340ce8aaba292023eefa6aa481ba6", builder)


if __name__ == "__main__":
    unittest.main()
