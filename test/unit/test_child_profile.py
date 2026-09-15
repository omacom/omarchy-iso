"""Unit tests for the child install profile (Omarchy's kids mode) in the
orchestrator: the profile read from the configurator's JSON, the child package
list on top of the base set, the --profile handoff to omarchy-apply-system, and
the parent password added as a second LUKS key."""

import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402
from orchestrator.context import InstallContext  # noqa: E402


class ChildProfileContextTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.env = {
            "OMARCHY_INSTALL_CONFIG": str(self.dir / "user_configuration.json"),
            "OMARCHY_INSTALL_CREDS": str(self.dir / "user_credentials.json"),
            "OMARCHY_INSTALL_STATE_DIR": str(self.dir / "state"),
        }

    def from_env(self, config, creds, **extra_env):
        (self.dir / "user_configuration.json").write_text(json.dumps(config))
        (self.dir / "user_credentials.json").write_text(json.dumps(creds))
        with mock.patch.dict(os.environ, {**self.env, **extra_env}, clear=False):
            return InstallContext.from_env()

    def config(self, profile=None, **omarchy_install):
        block = {"mode": "full_disk", "target_mount": "/mnt", **omarchy_install}
        if profile is not None:
            block["profile"] = profile
        return {"omarchy_install": block, "disk_config": {"config_type": "default_layout"}}

    def creds(self, **extra):
        return {
            "root_enc_password": "$6$parent",
            "users": [{"username": "kid", "enc_password": "$6$kid", "groups": [], "sudo": False}],
            **extra,
        }

    def test_profile_defaults_when_absent(self):
        ctx = self.from_env(self.config(), self.creds())
        self.assertEqual(ctx.profile, "default")
        self.assertEqual(ctx.omarchy_install["profile"], "default")

    def test_child_profile_is_read(self):
        ctx = self.from_env(self.config(profile="child"), self.creds())
        self.assertEqual(ctx.profile, "child")

    def test_unknown_profile_is_refused(self):
        with self.assertRaises(RuntimeError):
            self.from_env(self.config(profile="teen"), self.creds())

    def test_deferred_child_install_drops_the_parent_passphrase(self):
        ctx = self.from_env(
            self.config(profile="child", defer_provisioning=True),
            self.creds(encryption_password="kid-pass", parent_encryption_password="parent-pass"),
        )
        self.assertEqual(ctx.profile, "child")
        self.assertEqual(ctx.user_credentials.get("users"), [])
        self.assertNotIn("parent_encryption_password", ctx.user_credentials)


class ChildPackageListTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        share = Path(self.tmp.name)
        (share / "omarchy-base.packages").write_text("# base\nfoo\nbar\n")
        (share / "omarchy-child.packages").write_text("# child\nfoo\ngcompris\n")
        self.share = share

    def list_for(self, profile):
        ctx = types.SimpleNamespace(profile=profile)
        with mock.patch.object(phases_impl, "ISO_SHARE", self.share), \
                mock.patch.object(phases_impl, "_early_packages", return_value=[]), \
                mock.patch.object(phases_impl, "_omarchy_runtime_package", return_value="omarchy"), \
                mock.patch.object(phases_impl, "_omarchy_settings_package", return_value="omarchy-settings"), \
                mock.patch.object(phases_impl, "_omarchy_nvim_package", return_value="omarchy-nvim"):
            return phases_impl._runtime_package_list(ctx)

    def test_default_profile_installs_the_base_list_only(self):
        self.assertEqual(self.list_for("default"), ["omarchy", "foo", "bar"])

    def test_child_profile_adds_the_child_list_without_duplicates(self):
        self.assertEqual(self.list_for("child"), ["omarchy", "foo", "bar", "gcompris"])


class ProfileHandoffTest(unittest.TestCase):
    def test_system_finalizer_passes_the_profile(self):
        ctx = types.SimpleNamespace(profile="child", defer_provisioning=False, username="kid", target=Path("/mnt"))
        with mock.patch.object(phases_impl, "_run_target_setup_command") as run, \
                mock.patch.object(phases_impl, "_mask_mkinitcpio_pacman_hooks"), \
                mock.patch.object(phases_impl, "_unmask_mkinitcpio_pacman_hooks"):
            phases_impl.run_system_finalizer(ctx)
        cmd = run.call_args.args[1]
        self.assertEqual(cmd[-2:], ["--profile", "child"])
        self.assertIn("--install-user", cmd)

    def test_deferred_finalizer_still_passes_the_profile(self):
        ctx = types.SimpleNamespace(profile="child", defer_provisioning=True, username="", target=Path("/mnt"))
        with mock.patch.object(phases_impl, "_run_target_setup_command") as run, \
                mock.patch.object(phases_impl, "_mask_mkinitcpio_pacman_hooks"), \
                mock.patch.object(phases_impl, "_unmask_mkinitcpio_pacman_hooks"):
            phases_impl.run_system_finalizer(ctx)
        cmd = run.call_args.args[1]
        self.assertIn("--defer-provisioning", cmd)
        self.assertEqual(cmd[-2:], ["--profile", "child"])


class ParentDiskKeyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.state_dir = Path(self.tmp.name)

    def ctx(self, profile="child", encrypted=True, parent="parent-pass", kid="kid-pass", deferred=False):
        storage = {"luks_uuid": "1111-2222"} if encrypted else {}
        creds = {"users": [{"username": "kid"}]}
        if kid:
            creds["encryption_password"] = kid
        if parent:
            creds["parent_encryption_password"] = parent
        return types.SimpleNamespace(
            profile=profile,
            defer_provisioning=deferred,
            encrypt=encrypted,
            user_credentials=creds,
            user_configuration={"disk_config": {"config_type": "pre_mounted_config"}},
            omarchy_install={"mode": "protected", "storage": storage},
            state_dir=self.state_dir,
        )

    def run_phase(self, ctx, test_passphrase_rc=1):
        calls = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            rc = test_passphrase_rc if "--test-passphrase" in cmd else 0
            return CompletedProcess(cmd, rc)

        with mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run):
            phases_impl.add_parent_disk_key(ctx)
        return calls

    def test_adds_the_parent_key_with_the_kid_passphrase_unlocking(self):
        calls = self.run_phase(self.ctx())
        add = [c for c in calls if c[:2] == ["cryptsetup", "luksAddKey"]]
        self.assertEqual(len(add), 1)
        self.assertEqual(add[0][2:4], ["--key-file", str(self.state_dir / "luks-kid-key")])
        self.assertEqual(add[0][4], "/dev/disk/by-uuid/1111-2222")
        self.assertEqual(add[0][5], str(self.state_dir / "luks-parent-key"))
        self.assertFalse((self.state_dir / "luks-kid-key").exists(), "key files are removed afterwards")
        self.assertFalse((self.state_dir / "luks-parent-key").exists(), "key files are removed afterwards")

    def test_is_idempotent_when_the_parent_key_already_unlocks(self):
        calls = self.run_phase(self.ctx(), test_passphrase_rc=0)
        self.assertFalse(any(c[:2] == ["cryptsetup", "luksAddKey"] for c in calls))

    def test_does_nothing_outside_child_or_encrypted_installs(self):
        self.assertEqual(self.run_phase(self.ctx(profile="default")), [])
        self.assertEqual(self.run_phase(self.ctx(encrypted=False)), [])
        self.assertEqual(self.run_phase(self.ctx(deferred=True)), [])

    def test_refuses_without_both_passphrases(self):
        with self.assertRaises(RuntimeError):
            self.run_phase(self.ctx(parent=None))


if __name__ == "__main__":
    unittest.main()
