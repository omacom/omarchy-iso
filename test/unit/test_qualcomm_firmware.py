import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault("orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter"))
from orchestrator import phases_impl, qualcomm_firmware as firmware


class A16FirmwareTest(unittest.TestCase):
    def test_board_compatibles(self):
        with tempfile.TemporaryDirectory() as tmp:
            prop = Path(tmp) / "compatible"
            self.assertFalse(firmware.is_a16(prop))
            for value, expected in [
                (b"asus,zenbook-a16-ux3607oa\0qcom,glymur\0", True),
                (b"asus,ux3607oa\0qcom,glymur\0", True),
                (b"ASUS,UX3607OA\0qcom,glymur\0", True),
                (b"asus,ux3607oa-other\0qcom,glymur\0", False),
                (b"qcom,glymur-crd\0qcom,glymur\0", False),
            ]:
                prop.write_bytes(value)
                self.assertEqual(firmware.is_a16(prop), expected)

    def test_missing_and_corrupt_firmware_stop_before_disk_cleanup(self):
        name = "qcom/glymur/ASUSTeK/UX3607OA/qcadsp8480.mbn"
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp)
            path = stage / name
            path.parent.mkdir(parents=True)
            for data in (None, b"", b"corrupt-image"):
                digest = hashlib.sha256(b"" if data == b"" else b"signed-image").hexdigest()
                (stage / "manifest").write_text(f"{name} {digest} Windows/DriverStore/file\n")
                if data is not None:
                    path.write_bytes(data)
                with self.subTest(data=data), \
                     mock.patch.object(phases_impl, "is_a16", return_value=True), \
                     mock.patch.object(phases_impl.shutil, "which", return_value="extract"), \
                     mock.patch.object(phases_impl, "LIVE_FIRMWARE_STAGE", stage), \
                     mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, name + "\n", "")) as run, \
                     mock.patch.object(phases_impl, "_install_disk") as disk:
                    with self.assertRaisesRegex(RuntimeError, "before disk cleanup"):
                        phases_impl.prepare_live(types.SimpleNamespace(is_protected=False))
                    disk.assert_not_called()
                    self.assertEqual(run.call_count, 3)
                    self.assertIn("--stage-installed", run.call_args_list[1].args[0])

    def test_complete_verified_stage_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp)
            name = "qcom/board/adsp.mbn"
            path = stage / name
            path.parent.mkdir(parents=True)
            path.write_bytes(b"signed-image")
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            (stage / "manifest").write_text(f"{name} {digest} source\n")
            with mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, name + "\n", "")) as run:
                firmware.validate_a16_stage("extract", stage)
                self.assertEqual(run.call_args.args[0], ["extract", "--list-required"])

    def test_no_missing_files_needs_no_stage(self):
        with mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "", "")):
            firmware.validate_a16_stage("extract", Path("/nonexistent-stage"))

    def test_extractor_failure_is_not_treated_as_complete(self):
        with mock.patch.object(subprocess, "run", side_effect=subprocess.CalledProcessError(1, "extract")):
            with self.assertRaises(subprocess.CalledProcessError):
                firmware.validate_a16_stage("extract", Path("/nonexistent-stage"))


    def test_packaged_firmware_is_activated_before_staging(self):
        with mock.patch.object(subprocess, "run") as run, \
             mock.patch.object(firmware, "validate_a16_stage") as validate:
            stage = Path("/run/omarchy/firmware")
            firmware.prepare_a16_stage("extract", stage)
            self.assertEqual(run.call_args_list, [
                mock.call(["/usr/lib/asus-zenbook-a16-firmware/activate-calibration"], check=True),
                mock.call(["extract", "--stage", str(stage), "--stage-installed"], check=True),
            ])
            validate.assert_called_once_with("extract", stage)

    def test_activation_failure_prevents_staging(self):
        with mock.patch.object(subprocess, "run", side_effect=subprocess.CalledProcessError(1, "activate")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                firmware.prepare_a16_stage("extract", Path("/run/omarchy/firmware"))
            self.assertEqual(run.call_count, 1)


if __name__ == "__main__":
    unittest.main()
