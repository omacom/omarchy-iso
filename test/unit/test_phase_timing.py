"""Unit tests for monotonic phase and install duration timing in orchestrator/phases.py."""

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import phases  # noqa: E402


class PhaseMonotonicTimingTest(unittest.TestCase):
    def test_duration_ignores_forward_wall_clock_step(self):
        # Wall clock jumps +3600s during phase 1 (e.g. NTP sync), while
        # monotonic advances 0.25s in phase 1 and 0.75s in phase 2.
        mono_now = [100.0]

        def make_phase(dt):
            def _fn(_ctx):
                mono_now[0] += dt
            return _fn

        wall_calls = [0]

        def fake_wall():
            wall_calls[0] += 1
            return 1700000000.0 if wall_calls[0] <= 2 else 1700003600.0

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ctx = types.SimpleNamespace(state_dir=root / "state", target=root / "mnt")
            with mock.patch.object(phases.time, "time", side_effect=fake_wall), \
                 mock.patch.object(phases.time, "monotonic", side_effect=lambda: mono_now[0]), \
                 mock.patch.object(phases, "info"), \
                 mock.patch.object(phases, "error"):
                phases.run(ctx, [("p1", make_phase(0.25)), ("p2", make_phase(0.75))])
            timing = json.loads((ctx.target / "var/log/omarchy-install-timing.json").read_text())

        self.assertAlmostEqual(timing["phases"][0]["elapsed"], 0.25, places=6)
        self.assertAlmostEqual(timing["phases"][1]["elapsed"], 0.75, places=6)
        self.assertAlmostEqual(timing["duration"], 1.0, places=6)
        self.assertAlmostEqual(timing["finished_at"] - timing["started_at"], 1.0, places=6)

    def test_duration_ignores_backward_wall_clock_step(self):
        # Wall clock jumps -600s mid-install; monotonic advances 2.5s total.
        mono_now = [500.0]

        def phase_fn(_ctx):
            mono_now[0] += 2.5

        wall_calls = [0]

        def fake_wall():
            wall_calls[0] += 1
            return 1700001000.0 if wall_calls[0] <= 2 else 1700000400.0

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ctx = types.SimpleNamespace(state_dir=root / "state", target=root / "mnt")
            with mock.patch.object(phases.time, "time", side_effect=fake_wall), \
                 mock.patch.object(phases.time, "monotonic", side_effect=lambda: mono_now[0]), \
                 mock.patch.object(phases, "info"), \
                 mock.patch.object(phases, "error"):
                phases.run(ctx, [("only", phase_fn)])
            timing = json.loads((ctx.target / "var/log/omarchy-install-timing.json").read_text())

        self.assertAlmostEqual(timing["phases"][0]["elapsed"], 2.5, places=6)
        self.assertAlmostEqual(timing["duration"], 2.5, places=6)
        self.assertAlmostEqual(timing["finished_at"] - timing["started_at"], 2.5, places=6)

    def test_failed_phase_records_monotonic_elapsed(self):
        mono_now = [10.0]

        def failing_phase(_ctx):
            mono_now[0] += 1.25
            raise RuntimeError("boom")

        wall_calls = [0]

        def fake_wall():
            wall_calls[0] += 1
            return 1700000000.0 if wall_calls[0] <= 2 else 1700007200.0

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ctx = types.SimpleNamespace(state_dir=root / "state", target=root / "mnt")
            with mock.patch.object(phases.time, "time", side_effect=fake_wall), \
                 mock.patch.object(phases.time, "monotonic", side_effect=lambda: mono_now[0]), \
                 mock.patch.object(phases, "info"), \
                 mock.patch.object(phases, "error"), \
                 mock.patch.object(phases.traceback, "print_exc"):
                with self.assertRaises(phases.PhaseError):
                    phases.run(ctx, [("broken", failing_phase)])
            state = json.loads((ctx.state_dir / "state.json").read_text())

        self.assertEqual(state["phases"][0]["status"], "failed")
        self.assertAlmostEqual(state["phases"][0]["elapsed"], 1.25, places=6)


if __name__ == "__main__":
    unittest.main()
