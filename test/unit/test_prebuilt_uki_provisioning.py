"""An encrypted deferred-provisioning install never boots the pre-built UKI.

Its first boot unlocks the disk with a key in the initramfs: the provisioning
staging adds it with FILES+= and cryptkey= (the busybox encrypt hook's). The
pre-built UKI was built with FILES=() and an sd-encrypt initramfs, so it would
ask for a generated passphrase the owner may never have been shown.
"""

import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402


class PrebuiltUkiProvisioningTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_an_ordinary_install_keeps_the_prebuilt_uki(self):
        self.assertFalse(phases_impl._initramfs_carries_provisioning_key(self.root))

    def test_a_staged_provisioning_key_builds_the_uki_on_the_machine(self):
        ctx = types.SimpleNamespace(target=self.root)
        provisioning = self.root / "var/lib/omarchy/provisioning"
        provisioning.mkdir(parents=True)
        with mock.patch.object(phases_impl, "_provision_encryption_password", return_value="secret"), \
                mock.patch.object(phases_impl, "info", lambda _message: None):
            phases_impl._stage_provisioning_luks_unlock(ctx, provisioning)
        self.assertTrue(phases_impl._initramfs_carries_provisioning_key(self.root))


if __name__ == "__main__":
    unittest.main()
