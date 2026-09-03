"""The independent Limine and user tails must overlap without chroot races."""

import sys
import threading
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


class ParallelFinalizationTest(unittest.TestCase):
    def setUp(self):
        self.ctx = types.SimpleNamespace(target=Path("/mnt"), state={})
        self.patches = []
        self.addCleanup(self.stop_patches)

    def stop_patches(self):
        for patch in reversed(self.patches):
            patch.stop()

    def replace(self, name, value):
        patch = mock.patch.object(phases_impl, name, side_effect=value)
        self.patches.append(patch)
        patch.start()

    def test_limine_overlaps_the_ordered_user_branch(self):
        limine_started = threading.Event()
        user_started = threading.Event()
        calls = []

        def limine(_ctx):
            limine_started.set()
            if not user_started.wait(2):
                raise RuntimeError("user branch did not overlap Limine")
            calls.append("limine")

        def user(_ctx):
            user_started.set()
            if not limine_started.wait(2):
                raise RuntimeError("Limine branch did not overlap user")
            calls.append("user")

        self.replace("finalize_limine_boot", limine)
        self.replace("run_chroot_finalizer", user)
        for name in (
            "configure_login", "configure_ssh_access", "configure_tailscale",
            "configure_dns_resolver",
        ):
            self.replace(name, lambda _ctx, step=name: calls.append(step))

        with mock.patch.object(phases_impl.shutil, "which", return_value="/usr/bin/unshare"), \
             mock.patch.object(phases_impl, "info"):
            phases_impl.finalize_boot_and_user_setup(self.ctx)

        self.assertEqual([call for call in calls if call != "limine"], [
            "user", "configure_login", "configure_ssh_access",
            "configure_tailscale", "configure_dns_resolver",
        ])
        records = self.ctx.state["phase_substeps"]
        self.assertEqual([record["name"] for record in records], [
            "Finalizing Limine boot", "Finalizing user", "Configuring login",
            "Configuring SSH access", "Configuring Tailscale",
            "Configuring DNS resolver",
        ])
        self.assertTrue(all(record["status"] == "ok" for record in records))

    def test_failure_waits_for_both_branches_and_names_the_failed_step(self):
        user_finished = threading.Event()

        def fail_limine(_ctx):
            raise RuntimeError("bad UKI")

        self.replace("finalize_limine_boot", fail_limine)
        self.replace("run_chroot_finalizer", lambda _ctx: user_finished.set())
        for name in (
            "configure_login", "configure_ssh_access", "configure_tailscale",
            "configure_dns_resolver",
        ):
            self.replace(name, lambda _ctx: None)

        with mock.patch.object(phases_impl.shutil, "which", return_value="/usr/bin/unshare"), \
             mock.patch.object(phases_impl, "info"), \
             self.assertRaisesRegex(RuntimeError, "Finalizing Limine boot: bad UKI"):
            phases_impl.finalize_boot_and_user_setup(self.ctx)

        self.assertTrue(user_finished.is_set())
        self.assertEqual(self.ctx.state["phase_substeps"][0]["status"], "failed")

    def test_missing_unshare_preserves_safe_serial_order(self):
        calls = []
        for name in (
            "finalize_limine_boot", "run_chroot_finalizer", "configure_login",
            "configure_ssh_access", "configure_tailscale", "configure_dns_resolver",
        ):
            self.replace(name, lambda _ctx, step=name: calls.append(step))

        with mock.patch.object(phases_impl.shutil, "which", return_value=None), \
             mock.patch.object(phases_impl, "info"):
            phases_impl.finalize_boot_and_user_setup(self.ctx)

        self.assertEqual(calls, [
            "finalize_limine_boot", "run_chroot_finalizer", "configure_login",
            "configure_ssh_access", "configure_tailscale", "configure_dns_resolver",
        ])


class PrivateArchChrootTest(unittest.TestCase):
    def test_unshare_wraps_the_chroot_and_user_selection(self):
        ctx = types.SimpleNamespace(target=Path("/mnt"))
        with mock.patch.object(phases_impl.shutil, "which", return_value="/usr/bin/unshare"):
            command = phases_impl._private_arch_chroot_command(
                ctx, "env", "true", user="jeff",
            )

        self.assertEqual(command, [
            "unshare", "--mount", "--propagation", "private", "--",
            "arch-chroot", "-u", "jeff", "/mnt", "env", "true",
        ])

    def test_missing_unshare_uses_plain_arch_chroot(self):
        ctx = types.SimpleNamespace(target=Path("/mnt"))
        with mock.patch.object(phases_impl.shutil, "which", return_value=None):
            command = phases_impl._private_arch_chroot_command(ctx, "true")

        self.assertEqual(command, ["arch-chroot", "/mnt", "true"])


if __name__ == "__main__":
    unittest.main()
