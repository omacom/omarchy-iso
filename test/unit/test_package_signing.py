"""aarch64 installs: the target keyring must trust Arch Linux ARM's signatures.

The install runs offline with SigLevel = Never, so a target that never got
archlinuxarm-keyring looked fine until its first online pacman run failed with
"unknown trust". These tests keep the keyring in the early packages and keep
validate_boot refusing a target keyring pacman would not accept.
"""

import os
import shutil
import subprocess
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

PACKAGE = "archlinuxarm-keyring-20240419-2-any.pkg.tar.xz"


class EarlyKeyringTest(unittest.TestCase):
    def test_aarch64_installs_the_arch_linux_arm_keyring_early(self):
        with mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"):
            packages = phases_impl._early_bootstrap_packages()
        self.assertIn("archlinuxarm-keyring", packages)
        # In the transaction that populates omarchy-keyring, before anything
        # is installed from an Arch Linux ARM repository online.
        self.assertLess(packages.index("archlinuxarm-keyring"), packages.index(phases_impl._omarchy_settings_package()))

    def test_x86_64_does_not(self):
        with mock.patch.object(phases_impl.platform, "machine", return_value="x86_64"):
            self.assertNotIn("archlinuxarm-keyring", phases_impl._early_bootstrap_packages())


@unittest.skipUnless(shutil.which("gpg") and shutil.which("gpgconf"), "needs GnuPG")
class PackageSigningTest(unittest.TestCase):
    """Real GnuPG: a throwaway build key signs a fake keyring package, and the
    target keyring either trusts that key or does not."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="omarchy-sig-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

        self.builder = self.tmp / "builder"
        self.builder.mkdir(mode=0o700)
        self.addCleanup(self.gpg_kill, self.builder)
        self.gpg(self.builder, "--quick-gen-key", "--passphrase", "", "Build System <builder@example.invalid>", "ed25519", "sign", "never")
        self.fingerprint = next(
            line.split(":")[9]
            for line in self.gpg(self.builder, "--with-colons", "--list-keys").splitlines()
            if line.startswith("fpr:")
        )

        self.mirror = self.tmp / "mirror"
        self.mirror.mkdir()
        package = self.mirror / PACKAGE
        package.write_bytes(os.urandom(512))
        self.gpg(self.builder, "--detach-sign", "--output", f"{package}.sig", str(package))

        self.target = self.tmp / "target"
        self.gnupg = self.target / "etc/pacman.d/gnupg"
        self.gnupg.mkdir(parents=True, mode=0o700)
        self.addCleanup(self.gpg_kill, self.gnupg)
        public_key = self.tmp / "builder.asc"
        self.gpg(self.builder, "--export", "--armor", "--output", str(public_key), self.fingerprint)
        self.ctx = types.SimpleNamespace(target=self.target)

    def gpg(self, home, *args, stdin=None):
        return subprocess.run(
            ["gpg", "--homedir", str(home), "--batch", "--no-permission-warning", *args],
            check=True, capture_output=True, text=True, input=stdin,
        ).stdout

    def gpg_kill(self, home):
        subprocess.run(["gpgconf", "--homedir", str(home), "--kill", "all"], capture_output=True)

    def validate(self, machine="aarch64"):
        with mock.patch.object(phases_impl.platform, "machine", return_value=machine):
            phases_impl._validate_package_signing(self.ctx, mirror=self.mirror)

    def test_key_missing_from_target_fails(self):
        with self.assertRaisesRegex(RuntimeError, "unknown trust"):
            self.validate()

    def test_imported_but_untrusted_key_fails(self):
        # What answering pacman's "Import PGP key?" prompt leaves behind.
        self.gpg(self.gnupg, "--import", str(self.tmp / "builder.asc"))
        with self.assertRaisesRegex(RuntimeError, "unknown trust"):
            self.validate()

    def test_trusted_key_passes(self):
        # What populating archlinuxarm-keyring leaves behind: a key the
        # keyring considers valid.
        self.gpg(self.gnupg, "--import", str(self.tmp / "builder.asc"))
        self.gpg(self.gnupg, "--import-ownertrust", stdin=f"{self.fingerprint}:6:\n")
        self.validate()

    def test_x86_64_is_not_checked(self):
        self.validate(machine="x86_64")

    def test_missing_signature_in_the_mirror_fails(self):
        for path in self.mirror.iterdir():
            path.unlink()
        with self.assertRaisesRegex(RuntimeError, "no archlinuxarm-keyring signature"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
