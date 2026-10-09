"""Unit tests for _run_timing_scripts: the finalizer's output is passed through
unchanged, and each Omarchy install script gets a [step] line with its
duration in microseconds, timed from run_logged's Starting/Completed lines.
A bash stand-in prints those lines around known sleeps."""

import io
import re
import subprocess
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402

FINALIZER = r'''
log() { echo "[$(printf "%(%Y-%m-%d %H:%M:%S)T" -1)] $1: /usr/share/omarchy/install/$2"; }
log Starting config/fast.sh
log Completed config/fast.sh
log Starting hardware/slow.sh
echo "pacman output inside the script"
sleep 0.2
log Completed hardware/slow.sh
log Starting config/broken.sh
log Failed config/broken.sh
echo "stderr line" >&2
exit ${EXIT:-0}
'''


class RunTimingScriptsTest(unittest.TestCase):
    def run_finalizer(self, exit_code=0):
        out = io.BytesIO()
        steps = []
        stdout = types.SimpleNamespace(buffer=out)
        with mock.patch.object(phases_impl.sys, "stdout", stdout), \
             mock.patch.object(phases_impl, "info", steps.append):
            try:
                phases_impl._run_timing_scripts(["bash", "-c", f"EXIT={exit_code}; {FINALIZER}"])
            finally:
                self.output = out.getvalue().decode()
        return steps

    def test_each_script_gets_a_microsecond_step_line(self):
        steps = self.run_finalizer()
        names = [re.match(r"\[step\] (\S+): \d+\.\d{6}s$", step).group(1) for step in steps]
        self.assertEqual(names, ["config/fast.sh", "hardware/slow.sh", "config/broken.sh"])
        slow = float(re.search(r": (\d+\.\d+)s", steps[1]).group(1))
        self.assertGreaterEqual(slow, 0.2)
        self.assertLess(slow, 1.0)

    def test_output_passes_through_unchanged(self):
        self.run_finalizer()
        self.assertIn("pacman output inside the script\n", self.output)
        self.assertIn("stderr line\n", self.output)
        self.assertEqual(self.output.count("Starting:"), 3)

    def test_a_failing_finalizer_raises(self):
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.run_finalizer(exit_code=3)
        self.assertEqual(caught.exception.returncode, 3)
        self.assertIn("stderr line\n", self.output)


if __name__ == "__main__":
    unittest.main()
