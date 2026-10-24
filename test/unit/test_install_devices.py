"""Unit tests for resolving the autoinstall disk before archinstall sees it.

archinstall only matches device_modifications[].device by kernel name, so a
/dev/disk/by-id/ link in an autoinstall config must be resolved by the
orchestrator, and a disk that is not there must stop the install up front.
"""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator.context import InstallContext  # noqa: E402


class InstallDeviceResolutionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.disk = self.dir / "nvme0n1"
        self.disk.touch()
        self.by_id = self.dir / "nvme-Samsung_SSD_990_PRO_S7XXNJ0W000000"
        self.by_id.symlink_to(self.disk)
        (self.dir / "user_credentials.json").write_text(json.dumps({"users": []}))
        self.env = {
            "OMARCHY_INSTALL_CONFIG": str(self.dir / "user_configuration.json"),
            "OMARCHY_INSTALL_CREDS": str(self.dir / "user_credentials.json"),
            "OMARCHY_INSTALL_STATE_DIR": str(self.dir / "state"),
        }

    def from_device(self, device):
        config = {
            "disk_config": {
                "config_type": "default_layout",
                "device_modifications": [{"device": device, "wipe": True, "partitions": []}],
            },
            "omarchy_install": {"mode": "full_disk", "target_mount": "/mnt"},
        }
        (self.dir / "user_configuration.json").write_text(json.dumps(config))
        with mock.patch.dict(os.environ, self.env, clear=False):
            return InstallContext.from_env()

    def archinstall_device(self, ctx):
        config = json.loads(ctx.arch_config_path.read_text())
        return config["disk_config"]["device_modifications"][0]["device"]

    def test_by_id_link_resolves_to_kernel_name(self):
        ctx = self.from_device(str(self.by_id))
        self.assertEqual(self.archinstall_device(ctx), os.path.realpath(self.disk))
        self.assertEqual(
            ctx.user_configuration["disk_config"]["device_modifications"][0]["device"],
            os.path.realpath(self.disk),
        )

    def test_kernel_name_passes_through(self):
        ctx = self.from_device(os.path.realpath(self.disk))
        self.assertEqual(self.archinstall_device(ctx), os.path.realpath(self.disk))

    def test_missing_disk_stops_the_install(self):
        with self.assertRaisesRegex(RuntimeError, "install disk not found"):
            self.from_device(str(self.dir / "nvme-gone"))

    def test_dangling_link_stops_the_install(self):
        dangling = self.dir / "nvme-unplugged"
        dangling.symlink_to(self.dir / "nvme1n1")
        with self.assertRaisesRegex(RuntimeError, "install disk not found"):
            self.from_device(str(dangling))

    def test_config_without_device_modifications_is_untouched(self):
        (self.dir / "user_configuration.json").write_text(json.dumps({
            "disk_config": {"config_type": "pre_mounted_config"},
            "omarchy_install": {"mode": "full_disk", "target_mount": "/mnt"},
        }))
        with mock.patch.dict(os.environ, self.env, clear=False):
            ctx = InstallContext.from_env()
        self.assertNotIn("device_modifications", ctx.user_configuration["disk_config"])


if __name__ == "__main__":
    unittest.main()
