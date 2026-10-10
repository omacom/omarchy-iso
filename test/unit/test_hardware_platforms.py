"""Profile selection, offline package closure and persistent boot settings."""

import copy
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault("orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter"))
from orchestrator import hardware, phases_impl  # noqa: E402


class HardwarePlatformsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.platforms = hardware.load_platforms(ROOT / "configs/aarch64/platforms.json")
        self.dmi = self.root / "dmi"
        self.dmi.mkdir()

    def identity(self, vendor, product):
        (self.dmi / "sys_vendor").write_text(vendor + "\n")
        (self.dmi / "product_name").write_text(product + "\n")

    def test_exact_matches_unknown_and_missing_identity(self):
        self.assertIsNone(hardware.select_platform(self.platforms, self.dmi, "aarch64/generic"))
        for entry in self.platforms:
            with self.subTest(platform=entry["id"]):
                match = entry["match"][0]
                self.identity(match["sys_vendor"], match["product_name"])
                self.assertEqual(hardware.select_platform(self.platforms, self.dmi, entry["media_target"]), entry)
                self.identity("Different vendor", match["product_name"])
                self.assertIsNone(hardware.select_platform(self.platforms, self.dmi, entry["media_target"]))

    def test_wrong_media_is_rejected(self):
        self.identity("NVIDIA", "NVIDIA_DGX_Spark")
        with self.assertRaisesRegex(ValueError, "requires aarch64/generic"):
            hardware.select_platform(self.platforms, self.dmi, "aarch64/snapdragon")

    def test_invalid_profiles_fail_validation(self):
        for field, value in [("packages", ["--overwrite"]), ("kernel_cmdline", ['$(touch /tmp/bad)']),
                             ("media_target", "aarch64/unknown"), ("match", [{"product_name": "83ED"}])]:
            with self.subTest(field=field):
                data = copy.deepcopy(self.platforms)
                data[0][field] = value
                manifest = self.root / "invalid.json"
                manifest.write_text(json.dumps({"schema_version": 1, "platforms": data}))
                with self.assertRaises(ValueError):
                    hardware.load_platforms(manifest)
        data = copy.deepcopy(self.platforms)
        data[1]["match"] = data[0]["match"]
        manifest.write_text(json.dumps({"schema_version": 1, "platforms": data}))
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            hardware.load_platforms(manifest)

    def test_installer_rejects_invalid_profile_before_disk_or_firmware_access(self):
        ctx = types.SimpleNamespace(state={})
        with mock.patch.object(hardware, "detect_platform", side_effect=ValueError("invalid")), \
             mock.patch.object(phases_impl, "_stage_qualcomm_firmware") as stage, \
             mock.patch.object(phases_impl.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "invalid"):
                phases_impl.prepare_live(ctx)
            stage.assert_not_called()
            run.assert_not_called()

    def test_x86_never_reads_arm_manifest(self):
        with mock.patch.object(hardware.platform, "machine", return_value="x86_64"), \
             mock.patch.object(hardware, "load_platforms") as load:
            self.assertIsNone(hardware.detect_platform())
            load.assert_not_called()

    def test_offline_closure_covers_each_selected_platform(self):
        snapdragon = hardware.offline_packages(self.platforms, "aarch64/snapdragon")
        generic = hardware.offline_packages(self.platforms, "aarch64/generic")
        self.assertNotIn("nvidia-open-dkms", snapdragon)
        self.assertIn("nvidia-open-dkms", generic)
        self.assertNotIn("linux-firmware-qcom", generic)
        for entry in self.platforms:
            self.assertTrue(set(entry["packages"]) <= set(hardware.offline_packages(self.platforms, entry["media_target"])))

    def test_runtime_installs_only_matched_extras_without_duplicates(self):
        for entry in [None, *self.platforms]:
            with self.subTest(platform=entry):
                ctx = types.SimpleNamespace(state={"hardware_platform": entry})
                with mock.patch.object(phases_impl, "_early_packages", return_value=[]), \
                     mock.patch.object(Path, "read_text", return_value="base\nlinux-firmware-qcom\n"):
                    packages = phases_impl._runtime_package_list(ctx)
                self.assertEqual(len(packages), len(set(packages)))
                extras = entry["packages"] if entry else []
                self.assertTrue(set(extras) <= set(packages))
                self.assertEqual("nvidia-open-dkms" in packages, "nvidia-open-dkms" in extras)

    def test_spark_boot_flags_persist_without_replacing_encryption_config(self):
        spark = next(entry for entry in self.platforms if entry["id"] == "nvidia-dgx-spark")
        target = self.root / "target"
        default = target / "etc/default/limine"
        default.parent.mkdir(parents=True)
        default.write_text('KERNEL_CMDLINE[default]+=" root=/dev/mapper/root cryptdevice=UUID=test:root"\n')
        original = default.read_bytes()
        for _ in range(2):
            hardware.configure_boot(target, spark)
        config = (target / hardware.BOOT_CONFIG).read_text()
        self.assertEqual(config.count("console=tty0"), 1)
        self.assertEqual(config.count("plymouth.ignore-serial-consoles"), 1)
        self.assertNotIn("plymouth.enable=0", config)
        self.assertEqual(default.read_bytes(), original)
        ctx = types.SimpleNamespace(target=target)
        combined = phases_impl._limine_combined_config_text(ctx, default.read_text())
        cmdline = phases_impl._limine_kernel_cmdline(combined)
        self.assertIn("cryptdevice=UUID=test:root", cmdline)
        self.assertIn("console=tty0", cmdline)

    def test_final_boot_generation_sees_platform_dropin(self):
        target = self.root / "target"
        files = {
            "usr/bin/limine-update": "",
            "etc/default/limine": 'KERNEL_CMDLINE[default]+=" root=/dev/mapper/root cryptdevice=UUID=test:root"\n',
            "etc/snapper/configs/root": "",
            "boot/limine.conf": "Omarchy cryptdevice=UUID=test:root\n",
        }
        for name, content in files.items():
            path = target / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        spark = next(entry for entry in self.platforms if entry["id"] == "nvidia-dgx-spark")
        ctx = types.SimpleNamespace(target=target, state={"hardware_platform": spark})

        def run(command, **kwargs):
            if command[-1] == "limine-update":
                self.assertIn("plymouth.ignore-serial-consoles", (target / hardware.BOOT_CONFIG).read_text())
            return mock.Mock(returncode=0)

        with mock.patch.object(phases_impl.subprocess, "run", side_effect=run) as execute:
            phases_impl.finalize_limine_boot(ctx)
        execute.assert_any_call(["arch-chroot", str(target), "limine-update"], check=True)

    def test_yoga_keeps_runtime_owned_boot_setup(self):
        yoga = next(entry for entry in self.platforms if entry["id"] == "lenovo-yoga-slim7x")
        for entry in (None, yoga):
            target = self.root / "target"
            hardware.configure_boot(target, entry)
            self.assertFalse(target.exists())


if __name__ == "__main__":
    unittest.main()
