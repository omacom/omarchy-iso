"""Unit tests for deferred-provisioning install support in the orchestrator.

Covers the InstallContext deferred-provisioning plumbing (marker file, credential-less input,
throwaway LUKS passphrase injection) and the stage_provisioning_state /
create_factory_snapshot / configure_login phases against a temp target with
subprocess mocked out.
"""

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


class ContextDeferProvisioningTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.state_dir = self.dir / "state"

        self.env = {
            "OMARCHY_INSTALL_CONFIG": str(self.dir / "user_configuration.json"),
            "OMARCHY_INSTALL_CREDS": str(self.dir / "user_credentials.json"),
            "OMARCHY_INSTALL_STATE_DIR": str(self.state_dir),
        }

    def write_config(self, config):
        (self.dir / "user_configuration.json").write_text(json.dumps(config))

    def write_creds(self, creds):
        (self.dir / "user_credentials.json").write_text(json.dumps(creds))

    def from_env(self, **extra_env):
        env = {**self.env, **extra_env}
        with mock.patch.dict(os.environ, env, clear=False):
            for key in (
                "OMARCHY_INSTALL_DEFER_PROVISIONING_FILE",
                "OMARCHY_INSTALL_BLUETOOTH_UNLOCK_FILE",
            ):
                if key not in env:
                    os.environ.pop(key, None)
            return InstallContext.from_env()

    def base_config(self, defer_provisioning=None, disk_encryption=None):
        config = {
            "disk_config": {"config_type": "default_layout"},
            "omarchy_install": {"mode": "full_disk", "target_mount": "/mnt"},
        }
        if defer_provisioning is not None:
            config["omarchy_install"]["defer_provisioning"] = defer_provisioning
        if disk_encryption is not None:
            config["disk_config"]["disk_encryption"] = disk_encryption
        return config

    def test_defer_provisioning_flag_from_config(self):
        self.write_config(self.base_config(defer_provisioning=True))
        ctx = self.from_env()
        self.assertTrue(ctx.defer_provisioning)
        self.assertEqual(ctx.user_credentials, {"users": []})
        self.assertEqual(ctx.username, "")

    def test_marker_file_arms_deferred_provisioning_without_credentials(self):
        self.write_config(self.base_config())
        marker = self.dir / "defer_provisioning"
        marker.touch()
        ctx = self.from_env(OMARCHY_INSTALL_DEFER_PROVISIONING_FILE=str(marker))
        self.assertTrue(ctx.defer_provisioning)
        self.assertTrue(ctx.omarchy_install["defer_provisioning"])

    def test_absent_marker_file_is_not_deferred_provisioning(self):
        self.write_config(self.base_config())
        self.write_creds({"users": [{"username": "jeff"}]})
        ctx = self.from_env(OMARCHY_INSTALL_DEFER_PROVISIONING_FILE=str(self.dir / "missing-defer_provisioning"))
        self.assertFalse(ctx.defer_provisioning)
        self.assertEqual(ctx.username, "jeff")

    def test_bluetooth_unlock_marker_is_optional(self):
        self.write_config(self.base_config())
        self.write_creds({"users": [{"username": "jeff"}]})
        marker = self.dir / "bluetooth-unlock.json"
        marker.write_text("{}")
        ctx = self.from_env(OMARCHY_INSTALL_BLUETOOTH_UNLOCK_FILE=str(marker))
        self.assertEqual(ctx.bluetooth_unlock_path, marker)

        ctx = self.from_env(OMARCHY_INSTALL_BLUETOOTH_UNLOCK_FILE=str(self.dir / "missing.json"))
        self.assertIsNone(ctx.bluetooth_unlock_path)

    def test_missing_credentials_without_defer_provisioning_raises(self):
        self.write_config(self.base_config())
        with self.assertRaisesRegex(RuntimeError, "credentials file missing"):
            self.from_env()

    def test_deferred_provisioning_generates_throwaway_luks_passphrase(self):
        self.write_config(self.base_config(defer_provisioning=True, disk_encryption={
            "encryption_type": "luks", "partitions": ["x"],
        }))
        ctx = self.from_env()

        password = ctx.user_configuration["disk_config"]["disk_encryption"]["encryption_password"]
        self.assertTrue(password)
        self.assertEqual(ctx.user_credentials["encryption_password"], password)

        # archinstall reads both files from disk; the injected passphrase must
        # be present in each.
        arch_config = json.loads(ctx.arch_config_path.read_text())
        self.assertEqual(
            arch_config["disk_config"]["disk_encryption"]["encryption_password"], password
        )
        synthesized = json.loads(ctx.creds_path.read_text())
        self.assertEqual(synthesized["encryption_password"], password)

    def test_deferred_provisioning_reuses_rig_supplied_passphrase(self):
        self.write_config(self.base_config(defer_provisioning=True, disk_encryption={
            "encryption_type": "luks", "partitions": ["x"],
        }))
        self.write_creds({"users": [], "encryption_password": "rig-secret"})
        ctx = self.from_env()
        self.assertEqual(
            ctx.user_configuration["disk_config"]["disk_encryption"]["encryption_password"],
            "rig-secret",
        )

    def test_deferred_provisioning_discards_account_material(self):
        # A rig credentials file must not smuggle in users or a root password.
        self.write_config(self.base_config(defer_provisioning=True))
        self.write_creds({
            "users": [{"username": "backdoor", "enc_password": "x", "sudo": True}],
            "root_enc_password": "x",
            "encryption_password": "rig-secret",
        })
        ctx = self.from_env()
        self.assertEqual(ctx.user_credentials["users"], [])
        self.assertNotIn("root_enc_password", ctx.user_credentials)
        self.assertEqual(ctx.user_credentials["encryption_password"], "rig-secret")
        synthesized = json.loads(ctx.creds_path.read_text())
        self.assertEqual(synthesized["users"], [])
        self.assertNotIn("root_enc_password", synthesized)

    def test_defer_provisioning_strips_account_fields(self):
        config = self.base_config(defer_provisioning=True)
        config["!users"] = [{"username": "rig"}]
        config["!root-password"] = "hunter2"
        config["root_enc_password"] = "x"
        config["auth_config"] = {"users": [{"username": "rig"}], "root_enc_password": "x"}
        self.write_config(config)
        ctx = self.from_env()

        arch_config = json.loads(ctx.arch_config_path.read_text())
        for key in ("!users", "!root-password", "root_enc_password", "users"):
            self.assertNotIn(key, arch_config)
        self.assertEqual(arch_config["auth_config"], {})

    def test_deferred_provisioning_unencrypted_touches_nothing(self):
        self.write_config(self.base_config(defer_provisioning=True))
        ctx = self.from_env()
        self.assertNotIn("encryption_password", ctx.user_credentials)


def make_ctx(target, **overrides):
    defaults = dict(
        target=target,
        defer_provisioning=True,
        encrypt=False,
        username="",
        omarchy_install={"mode": "full_disk", "defer_provisioning": True, "storage": {}},
        user_configuration={"disk_config": {}},
        user_credentials={"users": []},
        state_dir=target / "state",
        authorized_keys_path=None,
    )
    defaults.update(overrides)
    return types.SimpleNamespace(**defaults)


class StageProvisioningStateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        self.target.mkdir()

        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

        # A fake bundled Node tarball on the "live ISO".
        self.packages = Path(self.tmp.name) / "opt-packages"
        self.packages.mkdir()
        (self.packages / "node-v24.0.0-linux-x64.tar.gz").write_bytes(b"node")
        node_patch = mock.patch.object(phases_impl, "NODE_PACKAGES_DIR", self.packages)
        node_patch.start()
        self.addCleanup(node_patch.stop)

    def install_runtime_provisioning_support(self):
        service = self.target / "usr/share/omarchy/install/provisioning/omarchy-provision-owner.service"
        service.parent.mkdir(parents=True, exist_ok=True)
        service.write_text("[Unit]\n")
        setup_bin = self.target / "usr/bin/omarchy-provision-owner"
        setup_bin.parent.mkdir(parents=True, exist_ok=True)
        setup_bin.write_text("#!/bin/bash\n")

    def provisioning_dir(self):
        return self.target / "var/lib/omarchy/provisioning"

    def test_normal_install_stages_only_the_node_tarball(self):
        ctx = make_ctx(self.target, defer_provisioning=False)
        phases_impl.stage_provisioning_state(ctx)

        self.assertTrue((self.provisioning_dir() / "packages/node-v24.0.0-linux-x64.tar.gz").exists())
        self.assertFalse((self.provisioning_dir() / "pending").exists())
        self.assertFalse((self.target / "etc/systemd/system/omarchy-provision-owner.service").exists())

    def test_deferred_provisioning_against_runtime_without_support_fails_clearly(self):
        ctx = make_ctx(self.target)
        with self.assertRaisesRegex(RuntimeError, "does not ship"):
            phases_impl.stage_provisioning_state(ctx)

    def test_deferred_provisioning_without_node_tarball_fails(self):
        for tarball in self.packages.glob("*.tar.gz"):
            tarball.unlink()
        self.install_runtime_provisioning_support()
        ctx = make_ctx(self.target)
        with self.assertRaisesRegex(RuntimeError, "Node tarball"):
            phases_impl.stage_provisioning_state(ctx)

    def test_missing_node_tarball_fails_normal_installs_too(self):
        # The stash is what makes a later factory reset work offline.
        for tarball in self.packages.glob("*.tar.gz"):
            tarball.unlink()
        ctx = make_ctx(self.target, defer_provisioning=False)
        with self.assertRaisesRegex(RuntimeError, "Node tarball"):
            phases_impl.stage_provisioning_state(ctx)

    def test_deferred_provisioning_arms_first_boot_setup(self):
        self.install_runtime_provisioning_support()
        ctx = make_ctx(self.target)
        phases_impl.stage_provisioning_state(ctx)

        self.assertTrue((self.provisioning_dir() / "pending").exists())
        self.assertTrue((self.target / "etc/systemd/system/omarchy-provision-owner.service").exists())
        link = self.target / "etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"
        self.assertTrue(link.is_symlink())
        self.assertEqual(
            os.readlink(link), "/etc/systemd/system/omarchy-provision-owner.service"
        )
        # Unencrypted: no LUKS staging.
        self.assertFalse((self.provisioning_dir() / "luks-key").exists())

    def test_deferred_provisioning_encrypted_stages_luks_auto_unlock(self):
        self.install_runtime_provisioning_support()
        ctx = make_ctx(
            self.target,
            user_configuration={"disk_config": {"disk_encryption": {
                "encryption_type": "luks",
                "encryption_password": "throwaway-secret",
            }}},
        )
        phases_impl.stage_provisioning_state(ctx)

        # Byte-for-byte the slot passphrase — no trailing newline.
        self.assertEqual((self.provisioning_dir() / "luks-key").read_text(), "throwaway-secret")
        keyfile = self.target / "etc/omarchy/provisioning.key"
        self.assertEqual(keyfile.read_text(), "throwaway-secret")
        self.assertEqual(keyfile.stat().st_mode & 0o777, 0o600)

        cmdline = (self.target / "etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf").read_text()
        self.assertIn("cryptkey=rootfs:/etc/omarchy/provisioning.key", cmdline)
        files = (self.target / "etc/mkinitcpio.conf.d/99-omarchy-provisioning-key.conf").read_text()
        self.assertIn("FILES+=(/etc/omarchy/provisioning.key)", files)

    def test_deferred_provisioning_pre_encrypted_without_passphrase_fails(self):
        self.install_runtime_provisioning_support()
        ctx = make_ctx(
            self.target,
            omarchy_install={"mode": "protected", "defer_provisioning": True, "storage": {"luks_uuid": "abc"}},
        )
        with self.assertRaisesRegex(RuntimeError, "passphrase"):
            phases_impl.stage_provisioning_state(ctx)


class ConfigureLoginDeferProvisioningTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name)
        self.calls = []

        run_patch = mock.patch.object(
            phases_impl.subprocess, "run",
            side_effect=lambda cmd, **kw: (self.calls.append(cmd), CompletedProcess(cmd, 0))[1],
        )
        run_patch.start()
        self.addCleanup(run_patch.stop)

    def test_deferred_provisioning_login_leaves_user_state_to_first_boot(self):
        ctx = make_ctx(self.target, encrypt=True)
        phases_impl.configure_login(ctx)

        self.assertTrue((self.target / "etc/sddm.conf.d/99-omarchy-login.conf").exists())
        self.assertFalse((self.target / "etc/sddm.conf.d/autologin.conf").exists())
        self.assertFalse((self.target / "var/lib/sddm/state.conf").exists())
        self.assertTrue(any("sddm.service" in cmd for cmd in self.calls))

    def test_normal_encrypted_login_still_autologs_in(self):
        ctx = make_ctx(self.target, defer_provisioning=False, encrypt=True, username="jeff")
        phases_impl.configure_login(ctx)

        autologin = (self.target / "etc/sddm.conf.d/autologin.conf").read_text()
        self.assertIn("User=jeff", autologin)
        state = (self.target / "var/lib/sddm/state.conf").read_text()
        self.assertIn("User=jeff", state)


class ConfigureSshAccessDeferProvisioningTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        self.target.mkdir()

        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

        def fake_run(cmd, **kwargs):
            self.calls.append(cmd)
            if "ufw" in cmd:
                rules = self.target / "etc/ufw/user.rules"
                rules.parent.mkdir(parents=True, exist_ok=True)
                rules.write_text("-A ufw-user-input -p tcp --dport 22 -j ACCEPT\n")
            return CompletedProcess(cmd, 0)

        self.calls = []
        run_patch = mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run)
        run_patch.start()
        self.addCleanup(run_patch.stop)

    def test_deferred_provisioning_stages_keys_for_first_boot(self):
        keys = Path(self.tmp.name) / "authorized_keys"
        keys.write_text("ssh-ed25519 AAAA rig@host\n")
        ctx = make_ctx(self.target, authorized_keys_path=keys)

        phases_impl.configure_ssh_access(ctx)

        staged = self.target / "var/lib/omarchy/provisioning/authorized_keys"
        self.assertEqual(staged.read_text(), "ssh-ed25519 AAAA rig@host\n")
        self.assertEqual(staged.stat().st_mode & 0o777, 0o600)
        # No user yet — nothing under /home, no chown.
        self.assertFalse((self.target / "home").exists())
        self.assertFalse(any("chown" in cmd for cmd in self.calls))
        # The door is still opened for first boot.
        self.assertTrue(any("sshd.service" in cmd for cmd in self.calls))


class CreateFactorySnapshotTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        self.target.mkdir()
        self.state_dir = Path(self.tmp.name) / "state"
        self.state_dir.mkdir()

        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

        self.findmnt = {
            "FSTYPE": "btrfs",
            "OPTIONS": "rw,noatime,compress=zstd:3,subvol=/@",
            "SOURCE": "/dev/mapper/omarchy_root[/@]",
        }
        self.calls = []

        def fake_run(cmd, **kwargs):
            self.calls.append(cmd)
            if cmd[0] == "findmnt":
                return CompletedProcess(cmd, 0, stdout=self.findmnt[cmd[2]] + "\n", stderr="")
            if cmd[0] == "mount":
                # Simulate the top level containing @.
                (Path(cmd[-1]) / "@").mkdir(parents=True, exist_ok=True)
            return CompletedProcess(cmd, 0, stdout="", stderr="")

        run_patch = mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run)
        run_patch.start()
        self.addCleanup(run_patch.stop)

    def ctx(self):
        return make_ctx(self.target, defer_provisioning=False, state_dir=self.state_dir)

    def test_snapshots_root_as_factory(self):
        phases_impl.create_factory_snapshot(self.ctx())

        top = str(self.state_dir / "factory-top")
        self.assertIn(["mount", "-o", "subvolid=5", "/dev/mapper/omarchy_root", top], self.calls)
        self.assertIn(
            ["btrfs", "subvolume", "snapshot", f"{top}/@", f"{top}/@factory"],
            self.calls,
        )
        self.assertIn(
            ["btrfs", "property", "set", "-ts", f"{top}/@factory", "ro", "true"],
            self.calls,
        )
        self.assertIn(["umount", top], self.calls)

    def test_factory_snapshot_scrubs_provisioning_credentials(self):
        # Simulate the snapshot carrying deployment credentials; the scrub
        # must drop them before the snapshot goes read-only.
        top = self.state_dir / "factory-top"
        factory = top / "@factory"
        secrets = [
            factory / "var/lib/omarchy/provisioning/authorized_keys",
            factory / "etc/tailscale/authkey",
            factory / "etc/omarchy/provisioning.key",
        ]
        keep = factory / "var/lib/omarchy/provisioning/groups"
        for path in [*secrets, keep]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("secret")

        phases_impl.create_factory_snapshot(self.ctx())

        for path in secrets:
            self.assertFalse(path.exists(), path)
        self.assertTrue(keep.exists())

    def test_non_btrfs_target_skips(self):
        self.findmnt["FSTYPE"] = "ext4"
        phases_impl.create_factory_snapshot(self.ctx())
        self.assertFalse(any(cmd[0] == "mount" for cmd in self.calls))

    def test_non_subvol_root_skips(self):
        self.findmnt["OPTIONS"] = "rw,noatime"
        phases_impl.create_factory_snapshot(self.ctx())
        self.assertFalse(any(cmd[0] == "mount" for cmd in self.calls))


if __name__ == "__main__":
    unittest.main()
