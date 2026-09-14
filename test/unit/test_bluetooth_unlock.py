"""Tests for the opt-in live-ISO to early-boot Bluetooth bond handoff."""

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


CONTROLLER = "AA:BB:CC:DD:EE:FF"
KEYBOARD = "11:22:33:44:55:66"
OTHER = "22:33:44:55:66:77"


class BluetoothUnlockTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.live_state = self.root / "live-bluetooth"
        self.target = self.root / "mnt"
        self.target.mkdir()
        runtime = self.target / "usr/bin/omarchy-setup-security-bluetooth-unlock"
        runtime.parent.mkdir(parents=True)
        runtime.touch()
        self.marker = self.root / "bluetooth-unlock.json"
        self.marker.write_text(json.dumps({"controller": CONTROLLER, "device": KEYBOARD}))

        controller = self.live_state / CONTROLLER
        (controller / KEYBOARD).mkdir(parents=True)
        (controller / KEYBOARD / "info").write_text("[LinkKey]\nKey=selected-secret\n")
        (controller / OTHER).mkdir()
        (controller / OTHER / "info").write_text("unrelated-secret\n")
        (controller / "cache").mkdir()
        (controller / "cache" / KEYBOARD).write_text("selected cache\n")
        (controller / "cache" / OTHER).write_text("unrelated cache\n")
        (controller / "settings").write_text("[General]\nDiscoverable=false\n")

        state_patch = mock.patch.object(phases_impl, "BLUETOOTH_STATE_DIR", self.live_state)
        state_patch.start()
        self.addCleanup(state_patch.stop)
        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

    def ctx(self, **overrides):
        defaults = dict(
            target=self.target,
            bluetooth_unlock_path=self.marker,
            defer_provisioning=False,
            encrypt=True,
            omarchy_install={"storage": {}},
            user_configuration={"disk_config": {}},
            user_credentials={"users": [{"username": "test"}]},
        )
        defaults.update(overrides)
        return types.SimpleNamespace(**defaults)

    def test_copies_only_selected_bond_and_invokes_runtime_without_rebuild(self):
        with mock.patch.object(phases_impl, "_run_target_setup_command") as run:
            phases_impl.configure_bluetooth_unlock(self.ctx())

        target_controller = self.target / "var/lib/bluetooth" / CONTROLLER
        self.assertEqual(
            (target_controller / KEYBOARD / "info").read_text(),
            "[LinkKey]\nKey=selected-secret\n",
        )
        self.assertFalse((target_controller / OTHER).exists())
        self.assertFalse((target_controller / "cache" / OTHER).exists())
        self.assertEqual(target_controller.stat().st_mode & 0o777, 0o700)
        run.assert_called_once_with(self.ctx(), [
            "/usr/bin/omarchy-setup-security-bluetooth-unlock",
            "enable",
            "--controller", CONTROLLER,
            "--device", KEYBOARD,
            "--yes",
            "--no-rebuild",
        ])

    def test_rejects_non_object_marker(self):
        self.marker.write_text("[]")
        with self.assertRaisesRegex(RuntimeError, "JSON object"):
            phases_impl.configure_bluetooth_unlock(self.ctx())

    def test_requires_runtime_before_copying_secrets(self):
        (self.target / "usr/bin/omarchy-setup-security-bluetooth-unlock").unlink()
        with self.assertRaisesRegex(RuntimeError, "does not support"):
            phases_impl.configure_bluetooth_unlock(self.ctx())
        self.assertFalse((self.target / "var/lib/bluetooth").exists())

    def test_rejects_target_and_cache_symlinks_before_copy(self):
        outside = self.root / "outside"
        outside.mkdir()
        for relative in ("var", "var/lib", "var/lib/bluetooth",
                         f"var/lib/bluetooth/{CONTROLLER}/settings",
                         f"var/lib/bluetooth/{CONTROLLER}/cache"):
            with self.subTest(relative=relative):
                path = self.target / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.symlink_to(outside)
                with self.assertRaisesRegex(RuntimeError, "symlink"):
                    phases_impl.configure_bluetooth_unlock(self.ctx())
                self.assertEqual(list(outside.iterdir()), [])
                path.unlink()
        cache = self.live_state / CONTROLLER / "cache"
        import shutil
        shutil.rmtree(cache)
        cache.symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, "cache symlink"):
            phases_impl.configure_bluetooth_unlock(self.ctx())

    def test_secret_permissions_are_restricted(self):
        with mock.patch.object(phases_impl, "_run_target_setup_command"):
            phases_impl.configure_bluetooth_unlock(self.ctx())
        controller = self.target / "var/lib/bluetooth" / CONTROLLER
        for path in (controller / KEYBOARD / "info", controller / "settings", controller / "cache" / KEYBOARD):
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_rejects_unencrypted_and_deferred_installs(self):
        with self.assertRaisesRegex(RuntimeError, "unencrypted"):
            phases_impl.configure_bluetooth_unlock(self.ctx(encrypt=False))
        with self.assertRaisesRegex(RuntimeError, "deferred provisioning"):
            phases_impl.configure_bluetooth_unlock(self.ctx(defer_provisioning=True))

    def test_rejects_invalid_addresses_and_source_symlinks(self):
        self.marker.write_text(json.dumps({"controller": "../etc", "device": KEYBOARD}))
        with self.assertRaisesRegex(RuntimeError, "invalid controller"):
            phases_impl.configure_bluetooth_unlock(self.ctx())

        self.marker.write_text(json.dumps({"controller": CONTROLLER, "device": KEYBOARD}))
        (self.live_state / CONTROLLER / KEYBOARD / "unsafe").symlink_to("/etc/shadow")
        with self.assertRaisesRegex(RuntimeError, "contains a symlink"):
            phases_impl.configure_bluetooth_unlock(self.ctx())


if __name__ == "__main__":
    unittest.main()
