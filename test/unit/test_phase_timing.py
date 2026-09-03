"""The persisted install duration must not depend on wall-clock stability."""

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import phases  # noqa: E402


class PhaseTimingTest(unittest.TestCase):
    def test_duration_and_phase_elapsed_use_the_monotonic_clock(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ctx = types.SimpleNamespace(
                state_dir=root / "state",
                target=root / "target",
                state={},
            )
            ctx.target.mkdir()

            # The wall clock moves backwards during the phase. It remains in
            # the diagnostic timestamps, while neither measured duration can
            # become negative or inherit that jump.
            with mock.patch.object(phases.time, "time", side_effect=[1000.0, 1001.0, 900.0]), \
                 mock.patch.object(phases.time, "monotonic", side_effect=[10.0, 10.5, 12.75, 13.0]):
                phases.run(ctx, [("Timed phase", lambda _ctx: None)])

            state = json.loads((ctx.target / "var/log/omarchy-install-timing.json").read_text())
            self.assertEqual(state["started_at"], 1000.0)
            self.assertEqual(state["finished_at"], 900.0)
            self.assertEqual(state["duration_seconds"], 3.0)
            self.assertEqual(state["phases"][0]["elapsed"], 2.25)

    def test_phase_substeps_are_persisted_and_cleared(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ctx = types.SimpleNamespace(
                state_dir=root / "state",
                target=root / "target",
                state={"phase_substeps": [{"name": "stale", "elapsed": 99}]},
            )
            ctx.target.mkdir()

            def measured(current_ctx):
                current_ctx.state["phase_substeps"] = [
                    {"name": "root image", "elapsed": 12.5}
                ]

            phases.run(ctx, [("Install", measured), ("Finish", lambda _ctx: None)])

            state = json.loads((ctx.target / "var/log/omarchy-install-timing.json").read_text())
            self.assertEqual(
                state["phases"][0]["substeps"],
                [{"name": "root image", "elapsed": 12.5}],
            )
            self.assertNotIn("substeps", state["phases"][1])
            self.assertNotIn("phase_substeps", ctx.state)


if __name__ == "__main__":
    unittest.main()
