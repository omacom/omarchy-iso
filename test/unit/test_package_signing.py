"""aarch64 installs: the target keyring must trust Arch Linux ARM's signatures.

The install runs offline with SigLevel = Never, so a target that never got
archlinuxarm-keyring looked fine until its first online pacman run failed with
"unknown trust". These tests keep the installer populating the Arch Linux ARM keys
into the target keyring and keep validate_boot refusing a target keyring
pacman would not accept.
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


class TargetKeyringTest(unittest.TestCase):
    # The root image ships no keyring; the installer populates the target's
    # from the keyring packages the image holds, archlinuxarm-keyring among
    # them on aarch64.
    def script(self, machine):
        ctx = mock.Mock()
        ctx.target = Path("/mnt")
        ctx.state = {}
        with mock.patch.object(phases_impl.platform, "machine", return_value=machine), \
                mock.patch.object(phases_impl.subprocess, "run"), \
                mock.patch.object(phases_impl.subprocess, "Popen") as popen, \
                mock.patch.object(phases_impl, "info", lambda _message: None):
            phases_impl._start_target_keyring_init(ctx)
        return popen.call_args.args[0][-1]

    def test_aarch64_populates_the_arch_linux_arm_keys(self):
        self.assertIn("--populate archlinux omarchy archlinuxarm", self.script("aarch64"))

    def test_x86_64_does_not(self):
        script = self.script("x86_64")
        self.assertIn("--populate archlinux omarchy", script)
        self.assertNotIn("archlinuxarm", script)


class KeyringBeforeSystemFinalizerTest(unittest.TestCase):
    # On aarch64 the runtime's own post-install initialises and populates the
    # target keyring; two pacman-keys on one gnupg dir corrupt it, so the
    # unit must have finished when omarchy-apply-system starts.
    def pending_at_finalizer(self, machine):
        ctx = mock.Mock()
        ctx.defer_provisioning = False
        ctx.username = "omarchy"
        ctx.target = Path("/mnt")
        proc = mock.Mock(returncode=0)
        proc.communicate.return_value = ("", None)
        ctx.state = {"target_keyring_proc": proc}
        seen = []
        with mock.patch.object(phases_impl.platform, "machine", return_value=machine), \
                mock.patch.object(phases_impl, "_mask_mkinitcpio_pacman_hooks"), \
                mock.patch.object(phases_impl, "_unmask_mkinitcpio_pacman_hooks"), \
                mock.patch.object(phases_impl, "_run_target_setup_command",
                                  lambda ctx, cmd: seen.append("target_keyring_proc" in ctx.state)):
            phases_impl.run_system_finalizer(ctx)
        return seen

    def test_aarch64_joins_the_keyring_unit_first(self):
        self.assertEqual(self.pending_at_finalizer("aarch64"), [False])

    def test_x86_64_keeps_it_running_alongside(self):
        self.assertEqual(self.pending_at_finalizer("x86_64"), [True])


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
        self.ctx = types.SimpleNamespace(target=self.target, state={})

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
