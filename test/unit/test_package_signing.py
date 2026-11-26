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
    def script(self, machine, hw="x86", *, target=None, keyrings_dir=None):
        ctx = mock.Mock()
        ctx.target = target if target is not None else Path("/mnt")
        ctx.state_dir = Path("/run/omarchy-install")
        ctx.state = {}
        with mock.patch.object(phases_impl.platform, "machine", return_value=machine), \
                mock.patch.object(phases_impl, "hw_platform", return_value=hw), \
                mock.patch.object(phases_impl.subprocess, "run"), \
                mock.patch.object(phases_impl.subprocess, "Popen") as popen, \
                mock.patch.object(phases_impl, "info", lambda _message: None):
            phases_impl._start_target_keyring_init(ctx, keyrings_dir=keyrings_dir)
        return popen.call_args.args[0][-1] if popen.called else None

    def target_with_iso_keyring_guard(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        helper = tmp / "usr/share/omarchy/install/helpers/pacman-keyring.sh"
        helper.parent.mkdir(parents=True)
        helper.write_text('omarchy_pacman_keyring_start() {\n  [[ ${OMARCHY_KEYRING_MANAGED_BY_ISO:-0} == "1" ]] && return 0\n}\n')
        return tmp

    def test_apple_silicon_populates_the_arch_linux_arm_keys(self):
        self.assertIn("--populate archlinux omarchy archlinuxarm", self.script("aarch64", "aarch64-apple"))

    def test_x86_64_does_not(self):
        script = self.script("x86_64")
        self.assertIn("--populate archlinux omarchy", script)
        self.assertNotIn("archlinuxarm", script)

    def test_aarch64_with_iso_managed_guard_starts_the_unit(self):
        target = self.target_with_iso_keyring_guard()
        for hw in ("aarch64", "aarch64-n1x", "aarch64-gb10", "aarch64-qualcomm"):
            with self.subTest(hw=hw):
                script = self.script("aarch64", hw, target=target)
                self.assertIsNotNone(script)
                self.assertIn("--populate archlinux omarchy archlinuxarm", script)

    def test_prepare_live_starts_the_unit_on_all_aarch64_platforms(self):
        for hw in ("aarch64", "aarch64-n1x", "aarch64-gb10", "aarch64-qualcomm"):
            with self.subTest(hw=hw):
                script = self.script("aarch64", hw, keyrings_dir=Path("/usr/share/pacman/keyrings"))
                self.assertIsNotNone(script)
                self.assertIn("--populate archlinux omarchy archlinuxarm", script)

    # An older aarch64 runtime without the OMARCHY_KEYRING_MANAGED_BY_ISO guard
    # always rebuilds the keyring in post-install; fallback start skips it.
    def test_older_aarch64_runtime_leaves_it_to_the_runtime(self):
        empty_target = Path(self.enterContext(tempfile.TemporaryDirectory()))
        comment_only_target = Path(self.enterContext(tempfile.TemporaryDirectory()))
        helper = comment_only_target / "usr/share/omarchy/install/helpers/pacman-keyring.sh"
        helper.parent.mkdir(parents=True)
        helper.write_text("# OMARCHY_KEYRING_MANAGED_BY_ISO is not wired here\nomarchy_pacman_keyring_start() { :; }\n")
        for target in (empty_target, comment_only_target):
            for hw in ("aarch64", "aarch64-n1x", "aarch64-gb10", "aarch64-qualcomm"):
                with self.subTest(target=target.name, hw=hw):
                    self.assertIsNone(self.script("aarch64", hw, target=target))


class KeyringBeforeSystemFinalizerTest(unittest.TestCase):
    # A target runtime that honours OMARCHY_KEYRING_MANAGED_BY_ISO=1 keeps the
    # tmpfs keyring unit overlapping run_system_finalizer on aarch64 too; an
    # older aarch64 runtime without the guard stops any pre-started tmpfs unit
    # so the runtime builds its own without blocking on thrown-away work.
    def run_finalizer(self, machine, *, hw="x86", supports_guard=False):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        if supports_guard:
            helper = tmp / "usr/share/omarchy/install/helpers/pacman-keyring.sh"
            helper.parent.mkdir(parents=True)
            helper.write_text('[[ ${OMARCHY_KEYRING_MANAGED_BY_ISO:-0} == "1" ]] && return 0\n')
        ctx = mock.Mock()
        ctx.defer_provisioning = False
        ctx.username = "omarchy"
        ctx.target = tmp
        ctx.log_path = tmp / "install.log"
        proc = mock.Mock(returncode=0)
        proc.communicate.return_value = ("", None)
        ctx.state = {"target_keyring_proc": proc}
        seen = {}

        def fake_timing(cmd):
            seen["pending"] = "target_keyring_proc" in ctx.state
            seen["cmd"] = cmd

        with mock.patch.object(phases_impl.platform, "machine", return_value=machine), \
                mock.patch.object(phases_impl, "hw_platform", return_value=hw), \
                mock.patch.object(phases_impl, "_mask_mkinitcpio_pacman_hooks"), \
                mock.patch.object(phases_impl, "_unmask_mkinitcpio_pacman_hooks"), \
                mock.patch.object(phases_impl, "_prepare_target_setup"), \
                mock.patch.object(phases_impl, "_ensure_finalizer_log_started", return_value=("0", "0")), \
                mock.patch.object(phases_impl.subprocess, "run") as run_mock, \
                mock.patch.object(phases_impl, "_run_timing_scripts", side_effect=fake_timing):
            phases_impl.run_system_finalizer(ctx)
        seen["runs"] = [call.args[0] for call in run_mock.call_args_list]
        return seen

    def test_aarch64_with_guard_keeps_unit_overlapping_and_exports_env(self):
        seen = self.run_finalizer("aarch64", hw="aarch64", supports_guard=True)
        self.assertTrue(seen["pending"])
        self.assertIn("OMARCHY_KEYRING_MANAGED_BY_ISO=1", seen["cmd"])

    def test_older_aarch64_without_guard_stops_unit_and_omits_env(self):
        seen = self.run_finalizer("aarch64", hw="aarch64", supports_guard=False)
        self.assertFalse(seen["pending"])
        self.assertNotIn("OMARCHY_KEYRING_MANAGED_BY_ISO=1", seen["cmd"])
        self.assertIn(["systemctl", "stop", "omarchy-target-keyring"], seen["runs"])

    def test_x86_64_keeps_it_running_alongside(self):
        seen = self.run_finalizer("x86_64")
        self.assertTrue(seen["pending"])
        self.assertIn("OMARCHY_KEYRING_MANAGED_BY_ISO=1", seen["cmd"])

    def test_build_root_image_pacman_keyring_patch_guards_start_and_finish(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        helper = tmp / "pacman-keyring.sh"
        helper.write_text(
            "omarchy_pacman_keyring_start() {\n"
            "  echo started\n"
            "}\n\n"
            "omarchy_pacman_keyring_finish() {\n"
            "  echo finished\n"
            "}\n"
        )
        script = (ROOT / "builder/build-root-image.sh").read_text()
        start = script.index('keyring_helper_sh=')
        end = script.index('\nfi\n', start) + 4
        snippet = script[start:end].replace('$root/usr/share/omarchy/install/helpers/pacman-keyring.sh', str(helper))
        subprocess.run(["bash", "-euo", "pipefail", "-c", snippet], check=True)
        out_managed = subprocess.run(
            ["bash", "-c", f'source "{helper}"; OMARCHY_KEYRING_MANAGED_BY_ISO=1 omarchy_pacman_keyring_start; OMARCHY_KEYRING_MANAGED_BY_ISO=1 omarchy_pacman_keyring_finish'],
            check=True, capture_output=True, text=True,
        ).stdout
        self.assertEqual(out_managed, "")
        out_unmanaged = subprocess.run(
            ["bash", "-c", f'source "{helper}"; omarchy_pacman_keyring_start; omarchy_pacman_keyring_finish'],
            check=True, capture_output=True, text=True,
        ).stdout
        self.assertEqual(out_unmanaged, "started\nfinished\n")


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
