"""Unit tests for the orchestrator's configure_tailscale phase.

Same harness as the SSH access tests: the phase touches the target only
through the filesystem and arch-chroot, so it runs against a temp directory
with subprocess.run recorded and the ufw side effect (writing user.rules)
simulated by the fake.
"""

import stat
import sys
import tempfile
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

# phases_impl imports the archinstall adapter at module scope, which pulls in
# the archinstall library that only exists on the live ISO. configure_tailscale
# never touches it, so stub the adapter out before the import.
sys.modules["orchestrator.archinstall_adapter"] = types.ModuleType("orchestrator.archinstall_adapter")

from orchestrator import phases_impl  # noqa: E402

UFW_RULE = "-A ufw-user-input -i tailscale0 -j ACCEPT\n"


class ConfigureTailscaleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name)
        self.calls = []

        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

        run_patch = mock.patch.object(phases_impl.subprocess, "run", side_effect=self.fake_run)
        run_patch.start()
        self.addCleanup(run_patch.stop)

        self.ufw_writes_rule = True

    def fake_run(self, cmd, **kwargs):
        self.calls.append(cmd)
        if "ufw" in cmd:
            if self.ufw_writes_rule:
                rules = self.target / "etc" / "ufw" / "user.rules"
                rules.parent.mkdir(parents=True, exist_ok=True)
                rules.write_text(UFW_RULE)
            # ufw cannot reach netfilter inside a chroot and exits non-zero
            # even when it recorded the rule; the phase must not trust this.
            return CompletedProcess(cmd, 1)
        return CompletedProcess(cmd, 0)

    def ctx(self, authkey=None, tailscale_installed=True):
        authkey_path = None
        if authkey is not None:
            authkey_path = self.target / "tailscale_authkey"
            authkey_path.write_text(authkey)
        if tailscale_installed:
            binary = self.target / "usr" / "bin" / "tailscale"
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.touch()
        return types.SimpleNamespace(target=self.target, tailscale_authkey_path=authkey_path)

    def configure(self, **kwargs):
        phases_impl.configure_tailscale(self.ctx(**kwargs))

    def staged_key(self):
        return self.target / "etc" / "tailscale" / "authkey"

    def unit(self):
        return self.target / "etc" / "systemd" / "system" / "omarchy-tailscale-join.service"

    def chrooted(self, program):
        prefix = phases_impl._private_arch_chroot_command(
            types.SimpleNamespace(target=self.target)
        )
        return [
            cmd for cmd in self.calls
            if cmd[:len(prefix)] == prefix and cmd[len(prefix)] == program
        ]

    def chroot_command(self, *args):
        return [
            *phases_impl._private_arch_chroot_command(
                types.SimpleNamespace(target=self.target)
            ),
            *args,
        ]

    def test_no_authkey_is_a_no_op(self):
        self.configure()
        self.assertEqual(self.calls, [])
        self.assertFalse((self.target / "etc" / "tailscale").exists())

    def test_stages_the_key(self):
        self.configure(authkey="tskey-auth-kFAKEKEY\n")
        self.assertEqual(self.staged_key().read_text(), "tskey-auth-kFAKEKEY\n")

    def test_drops_blank_lines_and_comments(self):
        self.configure(authkey="# reusable, tagged\n\n  tskey-auth-kFAKEKEY  \n")
        self.assertEqual(self.staged_key().read_text(), "tskey-auth-kFAKEKEY\n")

    def test_key_dir_and_file_are_root_private(self):
        self.configure(authkey="tskey-auth-kFAKEKEY\n")
        self.assertEqual(stat.S_IMODE((self.target / "etc" / "tailscale").stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.staged_key().stat().st_mode), 0o600)

    def test_installs_the_join_unit(self):
        self.configure(authkey="tskey-auth-kFAKEKEY\n")
        text = self.unit().read_text()
        self.assertIn("ConditionPathExists=/etc/tailscale/authkey", text)
        # The key must not outlive a successful join, the unit must not run
        # again after one, and cleanup must be sequenced after the join
        # succeeds -- inside the script, not in ExecStartPost.
        self.assertIn(
            "ExecStart=/usr/bin/sh -c 'until tailscale up --auth-key file:/etc/tailscale/authkey;"
            " do sleep 15; done; rm -f /etc/tailscale/authkey;"
            " systemctl disable omarchy-tailscale-join.service'",
            text,
        )

    def test_join_unit_does_not_hold_up_boot(self):
        # A Type=oneshot wanted by multi-user.target holds the whole boot
        # (SDDM included) hostage until the join finishes or times out --
        # target units implicitly gain After= for their Wants=.
        self.configure(authkey="tskey-auth-kFAKEKEY\n")
        text = self.unit().read_text()
        self.assertIn("Type=simple", text)
        self.assertNotIn("Type=oneshot", text)
        self.assertNotIn("TimeoutStartSec", text)

    def test_unit_avoids_systemd_variable_expansion(self):
        self.configure(authkey="tskey-auth-kFAKEKEY\n")
        self.assertNotIn("$", self.unit().read_text())

    def test_enables_tailscaled_and_the_join(self):
        self.configure(authkey="tskey-auth-kFAKEKEY\n")
        self.assertEqual(self.chrooted("systemctl"), [
            self.chroot_command(
                "systemctl", "enable", "tailscaled.service",
                "omarchy-tailscale-join.service",
            ),
        ])

    def test_allows_tailnet_traffic_through_ufw_despite_chroot_exit_status(self):
        self.configure(authkey="tskey-auth-kFAKEKEY\n")
        self.assertEqual(self.chrooted("ufw"), [
            self.chroot_command("ufw", "allow", "in", "on", "tailscale0"),
        ])

    def test_fails_when_ufw_does_not_record_the_rule(self):
        self.ufw_writes_rule = False
        with self.assertRaisesRegex(RuntimeError, "allow rule for tailscale0"):
            self.configure(authkey="tskey-auth-kFAKEKEY\n")

    def test_fails_when_tailscale_is_not_on_the_target(self):
        with self.assertRaisesRegex(RuntimeError, "not installed on the target"):
            self.configure(authkey="tskey-auth-kFAKEKEY\n", tailscale_installed=False)

    def test_empty_file_fails_the_phase(self):
        with self.assertRaisesRegex(RuntimeError, "contains no auth key"):
            self.configure(authkey="")

    def test_comment_only_file_fails_the_phase(self):
        with self.assertRaisesRegex(RuntimeError, "contains no auth key"):
            self.configure(authkey="# no key here\n")

    def test_multiple_keys_fail_the_phase(self):
        with self.assertRaisesRegex(RuntimeError, "expected exactly one"):
            self.configure(authkey="tskey-auth-kONE\ntskey-auth-kTWO\n")


if __name__ == "__main__":
    unittest.main()
