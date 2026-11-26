"""The live system makes the installed system's pacman keyring while the
wizard is open; the installer takes it, waits for it, or makes its own."""

import importlib.util
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
ORCHESTRATOR = ROOT / "configs/airootfs/usr/share/omarchy-iso/orchestrator"
sys.path.insert(0, str(ORCHESTRATOR.parent))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import phases_impl  # noqa: E402


class FakeProc:
    def __init__(self, returncode=0):
        self.returncode = returncode
        self.killed = 0

    def communicate(self):
        return "", None

    def kill(self):
        self.killed += 1


class EarlyTargetKeyringTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.early = root / "early"
        self.target = root / "mnt"
        self.state_dir = root / "state"
        self.live_keyrings = root / "keyrings"
        for d in (self.early, self.target, self.state_dir, self.live_keyrings):
            d.mkdir()
        self.ctx = types.SimpleNamespace(target=self.target, state={}, state_dir=self.state_dir)
        self.staged = self.state_dir / "target-gnupg"
        self.unit_state = "inactive"
        self.runs, self.popens, self.procs = [], [], []

        def fake_run(cmd, **kwargs):
            self.runs.append(list(cmd))
            if cmd[:2] == ["systemctl", "is-active"]:
                return CompletedProcess(cmd, 3, stdout=self.unit_state + "\n", stderr="")
            return CompletedProcess(cmd, 0, stdout="", stderr="")

        def fake_popen(cmd, **kwargs):
            self.popens.append(list(cmd))
            proc = self.procs.pop(0) if self.procs else FakeProc()
            self.last_proc = proc
            return proc

        for patch in (
            mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run),
            mock.patch.object(phases_impl.subprocess, "Popen", side_effect=fake_popen),
            mock.patch.object(phases_impl, "info"),
            mock.patch.object(phases_impl, "EARLY_KEYRING_DIR", self.early),
            mock.patch.object(phases_impl.platform, "machine", return_value="x86_64"),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def finished_keyring(self):
        (self.early / "gnupg").mkdir()
        (self.early / "gnupg" / "pubring.gpg").write_text("made at boot")
        (self.early / "complete").write_text(f"{int(time.time()) - 60}\n")

    def start(self):
        phases_impl._start_target_keyring_init(self.ctx, keyrings_dir=self.live_keyrings)

    def test_a_finished_keyring_is_used_and_nothing_is_started(self):
        self.finished_keyring()
        self.start()
        self.assertEqual(self.popens, [["true"]])
        self.assertTrue(self.ctx.state["target_keyring_early"])
        self.assertEqual(self.ctx.state["target_keyring_stage"], self.staged)

    def test_a_unit_still_running_is_waited_for(self):
        self.unit_state = "activating"
        self.start()
        self.assertEqual(self.popens, [["systemctl", "start", "omarchy-target-keyring-early.service"]])
        self.assertTrue(self.ctx.state["target_keyring_early"])

    def test_without_one_the_install_makes_its_own(self):
        for state in ("inactive", "failed", ""):
            with self.subTest(state=state):
                self.ctx.state.clear()
                self.popens.clear()
                self.runs.clear()
                self.unit_state = state
                self.start()
                (cmd,) = self.popens
                self.assertEqual(cmd[0], "systemd-run")
                self.assertIn("--unit=omarchy-target-keyring", cmd)
                self.assertNotIn("target_keyring_early", self.ctx.state)
                # A unit still queued must not make a second keyring beside it.
                self.assertIn(["systemctl", "stop", "omarchy-target-keyring-early.service"], self.runs)

    def test_the_format_stops_a_unit_still_at_work(self):
        spec = importlib.util.spec_from_file_location("luks_calibration_under_test", ORCHESTRATOR / "luks_calibration.py")
        luks = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(luks)
        self.assertEqual(luks.EARLY_KEYRING_UNIT, phases_impl.EARLY_KEYRING_UNIT)
        stops = []
        with mock.patch.object(luks, "_calibration_pending", return_value=False), \
                mock.patch.object(luks.subprocess, "run", side_effect=lambda cmd, **kw: stops.append(list(cmd))):
            luks.stop_calibration(wait=0)
        self.assertEqual(stops, [["systemctl", "stop", luks.UNIT],
                                 ["systemctl", "stop", "omarchy-target-keyring-early.service"]])

    def test_the_start_from_the_targets_own_keyrings_never_takes_it(self):
        self.finished_keyring()
        phases_impl._start_target_keyring_init(self.ctx)
        (cmd,) = self.popens
        self.assertEqual(cmd[0], "systemd-run")
        self.assertTrue((self.early / "complete").exists())

    def test_the_join_moves_it_into_the_target(self):
        self.finished_keyring()
        self.start()
        with mock.patch.object(phases_impl, "_install_staged_target_keyring") as install:
            phases_impl._join_target_keyring_init(self.ctx)
        install.assert_called_once_with(self.staged, self.target / "etc" / "pacman.d" / "gnupg")
        self.assertEqual((self.staged / "pubring.gpg").read_text(), "made at boot")
        self.assertFalse((self.early / "complete").exists())
        self.assertFalse((self.early / "gnupg").exists())
        self.assertTrue(self.ctx.state["target_keyring_installed"])
        self.assertNotIn("target_keyring_early", self.ctx.state)

    def test_a_second_install_in_the_session_makes_its_own(self):
        self.finished_keyring()
        self.start()
        with mock.patch.object(phases_impl, "_install_staged_target_keyring"):
            phases_impl._join_target_keyring_init(self.ctx)
        self.ctx.state.clear()
        self.popens.clear()
        self.start()
        self.assertEqual(self.popens[0][0], "systemd-run")

    def test_a_unit_that_failed_while_waited_for_falls_back_to_the_installs_own(self):
        self.unit_state = "activating"
        self.procs = [FakeProc(returncode=1), FakeProc(returncode=0)]
        self.start()
        with mock.patch.object(phases_impl, "_install_staged_target_keyring") as install, \
                mock.patch.object(phases_impl, "_runtime_populates_target_keyring", return_value=False):
            phases_impl._join_target_keyring_init(self.ctx)
        self.assertEqual(self.popens[0], ["systemctl", "start", "omarchy-target-keyring-early.service"])
        self.assertEqual(self.popens[1][0], "systemd-run")
        install.assert_called_once()
        self.assertTrue(self.ctx.state["target_keyring_installed"])

    def test_a_keyring_that_vanished_falls_back_too(self):
        self.finished_keyring()
        self.start()
        (self.early / "complete").unlink()
        with mock.patch.object(phases_impl, "_install_staged_target_keyring") as install, \
                mock.patch.object(phases_impl, "_runtime_populates_target_keyring", return_value=False):
            phases_impl._join_target_keyring_init(self.ctx)
        self.assertEqual(self.popens[1][0], "systemd-run")
        install.assert_called_once()

    def test_a_unit_that_finished_between_the_two_checks_is_not_started_again(self):
        self.unit_state = "activating"
        real_run = phases_impl.subprocess.run

        def finish_during_the_check(cmd, **kwargs):
            if cmd[:2] == ["systemctl", "is-active"]:
                self.finished_keyring()
            return real_run(cmd, **kwargs)
        with mock.patch.object(phases_impl.subprocess, "run", side_effect=finish_during_the_check):
            self.start()
        self.assertEqual(self.popens, [["true"]])

    def test_a_keyring_dated_after_the_clock_is_removed_and_the_install_makes_its_own(self):
        self.finished_keyring()
        (self.early / "complete").write_text(f"{int(time.time()) + 3600}\n")
        self.start()
        self.assertEqual(self.popens[0][0], "systemd-run")
        self.assertFalse((self.early / "complete").exists())
        self.assertFalse((self.early / "gnupg").exists())
        self.assertNotIn("target_keyring_early", self.ctx.state)

    def test_a_clock_set_back_while_the_install_ran_is_caught_at_the_join(self):
        self.finished_keyring()
        self.start()
        (self.early / "complete").write_text(f"{int(time.time()) + 3600}\n")
        with mock.patch.object(phases_impl, "_install_staged_target_keyring") as install, \
                mock.patch.object(phases_impl, "_runtime_populates_target_keyring", return_value=False):
            phases_impl._join_target_keyring_init(self.ctx)
        self.assertEqual(self.popens[1][0], "systemd-run")
        install.assert_called_once()

    def test_a_marker_that_holds_no_time_is_not_trusted(self):
        self.finished_keyring()
        (self.early / "complete").write_text("")
        self.start()
        self.assertEqual(self.popens[0][0], "systemd-run")

    def test_the_exit_path_ends_the_wait_and_the_unit_and_keeps_a_finished_keyring(self):
        self.unit_state = "activating"
        self.start()
        waiter = self.last_proc
        self.finished_keyring()
        phases_impl.stop_target_keyring_init(self.ctx)
        self.assertEqual(waiter.killed, 1)
        self.assertIn(["systemctl", "stop", "omarchy-target-keyring-early.service"], self.runs)
        self.assertTrue((self.early / "complete").exists())
        self.assertTrue((self.early / "gnupg" / "pubring.gpg").exists())
        self.assertNotIn("target_keyring_proc", self.ctx.state)


if __name__ == "__main__":
    unittest.main()
