"""Unit tests for load_arch_config's dropped-device guard (archinstall_adapter).

archinstall's DiskLayoutConfiguration.parse_arg silently skips any
device_modification whose path isn't in DeviceHandler's map, leaving
FilesystemHandler with nothing to partition so the install fills the live
ISO's tmpfs root. load_arch_config must fail immediately when a configured
disk disappears during parsing.
"""

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from archinstall_fakes import adapter  # noqa: E402


def _make_mod(device_path: str):
    return types.SimpleNamespace(
        device=types.SimpleNamespace(
            device_info=types.SimpleNamespace(path=Path(device_path)),
        ),
    )


class LoadArchConfigTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.creds_path = self.dir / "creds.json"
        self.creds_path.write_text("{}\n")

    def _write_config(self, config: dict) -> Path:
        path = self.dir / "archinstall-user_configuration.json"
        path.write_text(json.dumps(config))
        return path

    def _load(self, config: dict, parsed_devices: list[str] | None):
        config_path = self._write_config(config)
        disk_config = (
            None
            if parsed_devices is None
            else types.SimpleNamespace(device_modifications=[_make_mod(p) for p in parsed_devices])
        )

        class FakeHandler:
            def __init__(self):
                self.config = types.SimpleNamespace(disk_config=disk_config)

        with adapter({"archinstall.lib.args": {"ArchConfigHandler": FakeHandler}}) as arch:
            return arch.load_arch_config(config_path, self.creds_path)

    def test_dropped_device_raises(self):
        config = {"disk_config": {"device_modifications": [{"device": "/dev/nvme0n1", "wipe": True}]}}
        with self.assertRaisesRegex(RuntimeError, r"archinstall dropped configured install device\(s\): /dev/nvme0n1"):
            self._load(config, parsed_devices=[])

    def test_partially_dropped_devices_names_only_missing(self):
        config = {
            "disk_config": {
                "device_modifications": [
                    {"device": "/dev/nvme0n1", "wipe": True},
                    {"device": "/dev/nvme1n1", "wipe": True},
                ]
            }
        }
        with self.assertRaisesRegex(RuntimeError, r"archinstall dropped configured install device\(s\): /dev/nvme1n1"):
            self._load(config, parsed_devices=["/dev/nvme0n1"])

    def test_all_configured_devices_loaded_succeeds(self):
        config = {"disk_config": {"device_modifications": [{"device": "/dev/nvme0n1", "wipe": True}]}}
        handler = self._load(config, parsed_devices=["/dev/nvme0n1"])
        self.assertEqual(len(handler.config.disk_config.device_modifications), 1)

    def test_pre_mounted_config_without_device_modifications_succeeds(self):
        config = {"disk_config": {"config_type": "pre_mounted_config", "mountpoint": "/mnt"}}
        handler = self._load(config, parsed_devices=[])
        self.assertEqual(handler.config.disk_config.device_modifications, [])


if __name__ == "__main__":
    unittest.main()
