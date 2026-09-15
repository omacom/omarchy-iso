"""Encrypted and plain roots must build different initramfs unlock paths."""

import sys
import tempfile
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


class InitramfsEncryptionHooksTest(unittest.TestCase):
    def context(self, root: Path, *, encrypted: bool, storage=None):
        return types.SimpleNamespace(
            target=root,
            encrypt=encrypted,
            user_configuration={"disk_config": {}},
            omarchy_install={"storage": storage or {}},
        )

    def test_unencrypted_root_removes_only_unlock_hooks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ctx = self.context(root, encrypted=False)
            phases_impl._configure_initramfs_encryption_hooks(ctx)

            text = (root / phases_impl.UNENCRYPTED_HOOKS_DROPIN).read_text()
            self.assertIn("encrypt | sd-encrypt", text)
            self.assertIn('HOOKS=("${_omarchy_unencrypted_hooks[@]}")', text)
            self.assertNotIn("resume)", text)

    def test_encrypted_root_removes_stale_unencrypted_dropin(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dropin = root / phases_impl.UNENCRYPTED_HOOKS_DROPIN
            dropin.parent.mkdir(parents=True)
            dropin.write_text("stale")

            phases_impl._configure_initramfs_encryption_hooks(
                self.context(root, encrypted=True)
            )
            self.assertFalse(dropin.exists())

    def test_protected_luks_intent_counts_as_encrypted(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ctx = self.context(
                root,
                encrypted=False,
                storage={"luks_uuid": "11111111-2222-3333-4444-555555555555"},
            )
            phases_impl._configure_initramfs_encryption_hooks(ctx)
            self.assertFalse((root / phases_impl.UNENCRYPTED_HOOKS_DROPIN).exists())


class QuietResumeHookTest(unittest.TestCase):
    def test_no_resume_configuration_creates_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            phases_impl._configure_quiet_resume_hook(types.SimpleNamespace(target=root))
            self.assertFalse((root / phases_impl.QUIET_RESUME_RUNTIME_HOOK).exists())

    def test_configured_hibernation_keeps_resume_and_suppresses_only_no_image_warning(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            resume = root / "etc/mkinitcpio.conf.d/omarchy_resume.conf"
            resume.parent.mkdir(parents=True)
            resume.write_text("HOOKS+=(resume)\n")

            phases_impl._configure_quiet_resume_hook(types.SimpleNamespace(target=root))

            install = root / phases_impl.QUIET_RESUME_INSTALL_HOOK
            runtime = root / phases_impl.QUIET_RESUME_RUNTIME_HOOK
            dropin = root / phases_impl.QUIET_RESUME_DROPIN
            self.assertTrue(install.stat().st_mode & 0o111)
            self.assertTrue(runtime.stat().st_mode & 0o111)
            self.assertIn("add_binary /usr/lib/systemd/systemd-hibernate-resume", install.read_text())
            self.assertIn("SYSTEMD_LOG_LEVEL=err", runtime.read_text())
            self.assertIn("omarchy-resume", dropin.read_text())
            self.assertIn("HOOKS+=(resume)", resume.read_text())


if __name__ == "__main__":
    unittest.main()
