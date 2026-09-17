"""Unit tests for the schema-1 fields the phase loop records in the install
timing document: a run id, a stable id per phase, monotonic nanoseconds per
phase and for the run as a whole. Runs the real phase loop over fake phases
against a temp target.
"""

import json
import sys
import tempfile
import types
import unittest
import uuid
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases  # noqa: E402


def slow_phase(ctx):
    pass


def quick_phase(ctx):
    pass


def failing_phase(ctx):
    raise RuntimeError("boom")


class PhaseLoopTimingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.target = root / "target"
        self.state_dir = root / "state"
        # Two installed packages, as far as the package count reads them.
        (self.target / "var/lib/pacman/local/omarchy-4.0.2-1").mkdir(parents=True)
        (self.target / "var/lib/pacman/local/omarchy-settings-4.0.2-1").mkdir()

    def ctx(self):
        return types.SimpleNamespace(target=self.target, state_dir=self.state_dir)

    def run_phases(self, phase_list=None):
        phase_list = phase_list or [
            ("Installing Arch + Omarchy", slow_phase),
            ("Configuring DNS resolver", quick_phase),
        ]
        with mock.patch("orchestrator.phases.info"):
            phases.run(self.ctx(), phase_list)

    def document(self):
        return json.loads((self.target / "var/log/omarchy-install-timing.json").read_text())

    def test_records_schema_run_id_ids_and_monotonic_ns(self):
        self.run_phases()
        doc = self.document()

        self.assertEqual(doc["schema"], 1)
        self.assertEqual(str(uuid.UUID(doc["run_id"])), doc["run_id"])
        self.assertEqual([p["id"] for p in doc["phases"]], ["slow_phase", "quick_phase"])
        for phase in doc["phases"]:
            self.assertIsInstance(phase["elapsed_ns"], int)
            self.assertGreaterEqual(phase["elapsed_ns"], 0)
            self.assertEqual(phase["status"], "ok")
        # The lap covers the run from before the first phase to after the last;
        # the sectors add up to no more than that.
        self.assertIsInstance(doc["total_elapsed_ns"], int)
        self.assertGreaterEqual(doc["total_elapsed_ns"], sum(p["elapsed_ns"] for p in doc["phases"]))

    def test_dashboard_fields_are_untouched(self):
        self.run_phases()
        doc = self.document()

        for key in ("started_at", "finished_at", "target", "total_phases", "current_index",
                    "current_phase", "installed_packages", "expected_packages"):
            self.assertIn(key, doc)
        self.assertEqual(doc["current_phase"], "Installation complete")
        self.assertEqual(doc["total_phases"], 2)
        self.assertEqual(doc["installed_packages"], 2)
        for phase in doc["phases"]:
            self.assertIsInstance(phase["elapsed"], float)
            self.assertIn("name", phase)

        # The live state the dashboard polls carries the same shape.
        live = json.loads((self.state_dir / "state.json").read_text())
        self.assertEqual(live["run_id"], doc["run_id"])
        self.assertEqual(live["total_elapsed_ns"], doc["total_elapsed_ns"])

    def test_failed_phase_is_recorded_with_its_id(self):
        with mock.patch("orchestrator.phases.info"), mock.patch("orchestrator.phases.error"), \
                mock.patch("orchestrator.phases.traceback"):
            with self.assertRaises(phases.PhaseError):
                phases.run(self.ctx(), [("Installing Arch + Omarchy", failing_phase)])
        live = json.loads((self.state_dir / "state.json").read_text())
        self.assertEqual(live["phases"][0]["id"], "failing_phase")
        self.assertEqual(live["phases"][0]["status"], "failed")
        self.assertIn("elapsed_ns", live["phases"][0])
        self.assertFalse((self.target / "var/log/omarchy-install-timing.json").exists())

    def test_phase_id_falls_back_to_a_slug_for_anonymous_callables(self):
        self.assertEqual(phases.phase_id("Installing Arch + Omarchy", lambda ctx: None), "installing_arch_omarchy")
        self.assertEqual(phases.phase_id("Installing Arch + Omarchy", mock.Mock()), "installing_arch_omarchy")
        self.assertEqual(phases.phase_id("Whatever", slow_phase), "slow_phase")


if __name__ == "__main__":
    unittest.main()
