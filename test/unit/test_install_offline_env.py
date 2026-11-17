"""The install must not wait on a network it may not have.

mise reshim resolves the version list of every tool declared in
/etc/mise/conf.d/omarchy-tools.toml, all of them version = "latest". Offline,
each lookup waits out mise's HTTP timeout first: 40.10 s of a 65 s install.
MISE_OFFLINE=1 blocks every HTTP request, and the tools are lazy, so reshim
still only needs the declarations.
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


class MiseOfflineTest(unittest.TestCase):
    def test_user_finalizer_runs_mise_offline(self):
        ctx = mock.Mock(username="user", full_name="User", email="user@example.com",
                        defer_provisioning=False, state={})
        ctx.target = Path(tempfile.mkdtemp())
        ctx.log_path = ctx.target / "install.log"

        with mock.patch.object(phases_impl, "_prepare_target_setup"), \
                mock.patch.object(phases_impl, "_ensure_finalizer_log_started",
                                  return_value=("0", "0")), \
                mock.patch.object(phases_impl.subprocess, "run"), \
                mock.patch.object(phases_impl, "_run_timing_scripts") as timing:
            phases_impl.run_chroot_finalizer(ctx)

        # The finalizer's arch-chroot goes through the step-timing runner.
        command = timing.call_args.args[0]
        self.assertIn("arch-chroot", command)
        self.assertIn("MISE_OFFLINE=1", command)


if __name__ == "__main__":
    unittest.main()
