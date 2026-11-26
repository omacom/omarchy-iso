"""Unit tests for the post-install trim: phases_impl.trim_target runs fstrim
on the target, never fails the install, and main() calls it only after
run() has stopped the install timer."""

import subprocess
import sys
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import main, phases_impl  # noqa: E402
from orchestrator.phases import PhaseError  # noqa: E402


class TrimTargetTest(unittest.TestCase):
    def trim(self, **run):
        lines = []
        with mock.patch.object(phases_impl, "info", lines.append), \
                mock.patch.object(phases_impl.subprocess, "run", **run) as fake:
            phases_impl.trim_target(types.SimpleNamespace(target=Path("/mnt")))
        return fake, lines

    def test_trims_the_mounted_target_within_its_budget(self):
        fake, lines = self.trim(return_value=CompletedProcess(
            [], 0, "/mnt: 36.5 GiB (39187726336 bytes) trimmed\n", ""))
        args, kwargs = fake.call_args
        self.assertEqual(args[0], ["fstrim", "--verbose", "/mnt"])
        self.assertEqual(kwargs["timeout"], phases_impl.TRIM_BUDGET)
        self.assertRegex(lines[-1], r"^› trim: /mnt: 36\.5 GiB \(39187726336 bytes\) trimmed in \d+\.\d\ds$")

    def test_a_failed_trim_is_logged_and_does_not_raise(self):
        _, lines = self.trim(return_value=CompletedProcess(
            [], 1, "", "fstrim: /mnt: the discard operation is not supported\n"))
        self.assertIn("WARNING: fstrim /mnt exited 1", lines[-1])
        self.assertIn("not supported", lines[-1])
        self.assertNotIn("trimmed in", lines[-1])

    def test_a_slow_trim_is_stopped_at_its_budget(self):
        _, lines = self.trim(side_effect=subprocess.TimeoutExpired(["fstrim"], phases_impl.TRIM_BUDGET))
        self.assertIn(f"still running after {phases_impl.TRIM_BUDGET}s", lines[-1])

    def test_an_interrupted_trim_leaves_the_finished_install_alone(self):
        _, lines = self.trim(side_effect=KeyboardInterrupt)
        self.assertIn("was interrupted", lines[-1])

    def test_a_missing_fstrim_does_not_raise(self):
        _, lines = self.trim(side_effect=FileNotFoundError("fstrim"))
        self.assertIn("could not run fstrim", lines[-1])


class MainTrimsAfterTheTimerTest(unittest.TestCase):
    """run() writes finished_at, which the finish screen's time is read from,
    before it returns. The trim must come after it, and only on success."""

    def main(self, run_error=None):
        events = []

        def fake_run(ctx, phases):
            events.append("run")
            if run_error:
                raise run_error

        ctx = types.SimpleNamespace(username="omarchy", target=Path("/mnt"))
        helpers = dict.fromkeys(
            ["boost_cpu_governor", "cleanup_bind_mounts", "cleanup_protected_state",
             "cleanup_target_hook_masks", "restore_cpu_governors", "stop_library_warmup",
             "stop_luks_keyslot_enroll", "stop_target_keyring_init"], mock.DEFAULT)
        with mock.patch.object(main.InstallContext, "from_env", return_value=ctx), \
                mock.patch.object(main, "run", fake_run), \
                mock.patch.object(main, "build_phases", return_value=[]), \
                mock.patch.object(phases_impl, "trim_target", lambda c: events.append("trim")), \
                mock.patch.multiple(phases_impl, **helpers), \
                mock.patch.object(main, "info"), mock.patch.object(main, "error"):
            status = main.main()
        return status, events

    def test_a_finished_install_is_trimmed_after_run_returns(self):
        self.assertEqual(self.main(), (0, ["run", "trim"]))

    def test_a_failed_install_is_not_trimmed(self):
        self.assertEqual(self.main(PhaseError("boom")), (1, ["run"]))


if __name__ == "__main__":
    unittest.main()
