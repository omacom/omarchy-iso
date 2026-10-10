"""Architecture-specific bootstrap and staged-firmware regression tests."""

from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


class Aarch64BootTest(unittest.TestCase):
    def test_kernel_shim_is_bootstrapped_only_on_aarch64(self):
        for arch in ("aarch64", "x86_64"):
            with self.subTest(arch=arch), mock.patch.object(phases_impl.platform, "machine", return_value=arch):
                packages = phases_impl._early_bootstrap_packages()
                self.assertEqual("linux-aarch64-pkgbase-shim" in packages, arch == "aarch64")

    def test_firmware_copy_repairs_partial_target_on_retry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            stage.mkdir()
            (stage / "manifest").write_text("firmware\n")
            (stage / "firmware").write_bytes(b"firmware")
            ctx = types.SimpleNamespace(target=root / "target")
            target = ctx.target / phases_impl.TARGET_FIRMWARE_STAGE
            target.mkdir(parents=True)
            (target / "manifest").write_text("partial\n")
            with mock.patch.object(phases_impl, "LIVE_FIRMWARE_STAGE", stage):
                phases_impl._copy_firmware_stage_into_target(ctx)
                phases_impl._copy_firmware_stage_into_target(ctx)
            self.assertEqual((target / "firmware").read_bytes(), b"firmware")
            self.assertEqual((target / "manifest").read_text(), "firmware\n")

    def test_no_manifest_does_not_create_target_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ctx = types.SimpleNamespace(target=root / "target")
            with mock.patch.object(phases_impl, "LIVE_FIRMWARE_STAGE", root / "missing"):
                phases_impl._copy_firmware_stage_into_target(ctx)
            self.assertFalse(ctx.target.exists())


if __name__ == "__main__":
    unittest.main()
