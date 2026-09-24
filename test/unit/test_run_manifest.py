"""Unit tests for test/run-manifest.py, the lane runner behind test/all.

Every fixture is a throwaway script under a temp directory laid out like the
repository, so the runner is driven exactly as test/all drives it. The process
group cases matter most: a timed-out or cancelled test must take its children
with it, and a test that exits 0 while leaving a background process behind is
a failure, not a pass, because the next test would inherit it.
"""

from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "test/run-manifest.py"


def load_module():
    spec = importlib.util.spec_from_file_location("run_manifest", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RunManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_module()

    def make_script(self, root: Path, name: str, content: str) -> str:
        relative = f"test/unit/{name}"
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + content)
        return relative

    def assert_process_exits(self, pid: int) -> None:
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.02)
        self.fail(f"process {pid} survived test cancellation")

    def test_timeout_terminates_the_entire_fixture_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = self.make_script(
                root,
                "timeout-fixture-test.sh",
                'sleep 60 &\nchild=$!\nprintf "%s\\n" "$child" > test/unit/child.pid\nwait "$child"\n',
            )

            result = self.module.execute(
                root,
                relative,
                timeout_seconds=0.2,
            )

            self.assertEqual(result.status, "timed-out")
            self.assertEqual(result.returncode, self.module.TIMEOUT_RETURNCODE)
            child_pid = int((root / "test/unit/child.pid").read_text())
            self.assert_process_exits(child_pid)

    def test_timeout_escalates_to_kill_a_sigterm_resistant_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = self.make_script(
                root,
                "resistant-fixture-test.sh",
                "(\n"
                "  trap '' TERM\n"
                "  exec >/dev/null 2>&1\n"
                "  while true; do sleep 60; done\n"
                ") &\n"
                "child=$!\n"
                'printf "%s\\n" "$child" > test/unit/resistant.pid\n'
                'wait "$child"\n',
            )

            result = self.module.execute(
                root,
                relative,
                timeout_seconds=0.2,
            )

            self.assertEqual(result.status, "timed-out")
            child_pid = int((root / "test/unit/resistant.pid").read_text())
            self.assert_process_exits(child_pid)

    def test_parallel_failure_cancels_a_running_sibling_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            slow = self.make_script(
                root,
                "slow-fixture-test.sh",
                'sleep 60 &\nchild=$!\nprintf "%s\\n" "$child" > test/unit/sibling.pid\nwait "$child"\n',
            )
            failing = self.make_script(
                root,
                "failing-fixture-test.sh",
                "for ((attempt=0; attempt<200; attempt++)); do\n"
                "  [[ -s test/unit/sibling.pid ]] && exit 7\n"
                "  sleep 0.01\n"
                "done\n"
                "exit 8\n",
            )

            results = self.module.run_parallel(
                root,
                [slow, failing],
                jobs=2,
                timeout_seconds=5.0,
            )

            self.assertEqual([result.path for result in results], [slow, failing])
            self.assertEqual(results[0].status, "cancelled")
            self.assertEqual(results[1].status, "failed")
            sibling_pid = int((root / "test/unit/sibling.pid").read_text())
            self.assert_process_exits(sibling_pid)

    def test_successful_parent_cannot_leave_a_background_process(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = self.make_script(
                root,
                "leaking-success-fixture-test.sh",
                "(\n"
                "  trap '' TERM\n"
                "  exec </dev/null >/dev/null 2>&1\n"
                "  while true; do sleep 60; done\n"
                ") &\n"
                "child=$!\n"
                'printf "%s\n" "$child" > test/unit/leaked.pid\n'
                "exit 0\n",
            )

            result = self.module.execute(root, relative, timeout_seconds=2.0)
            leaked_pid = int((root / "test/unit/leaked.pid").read_text())
            try:
                self.assertEqual(result.status, "failed")
                self.assertIn("left a process group running", result.stderr)
                self.assert_process_exits(leaked_pid)
            finally:
                try:
                    leaked_group = os.getpgid(leaked_pid)
                except ProcessLookupError:
                    pass
                else:
                    os.killpg(leaked_group, signal.SIGKILL)

    def test_a_test_missing_from_both_manifests_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            listed = self.make_script(root, "listed-test.sh", "exit 0\n")
            self.make_script(root, "forgotten-test.sh", "exit 0\n")

            with self.assertRaisesRegex(self.module.ManifestError, "forgotten-test.sh"):
                self.module.validate(root, [listed], [])

    def test_a_manifest_entry_without_a_file_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            listed = self.make_script(root, "listed-test.sh", "exit 0\n")

            with self.assertRaisesRegex(self.module.ManifestError, "gone-test.sh"):
                self.module.validate(root, [listed], ["test/unit/gone-test.sh"])

    def test_a_test_in_both_manifests_is_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            listed = self.make_script(root, "listed-test.sh", "exit 0\n")

            with self.assertRaisesRegex(self.module.ManifestError, "duplicate"):
                self.module.validate(root, [listed], [listed])

    def test_the_checked_in_manifests_cover_every_unit_test(self) -> None:
        parallel = self.module.read_manifest(ROOT / "test/parallel-safe.tests")
        serial = self.module.read_manifest(ROOT / "test/serial.tests")

        self.module.validate(ROOT, parallel, serial)

    def test_ledger_is_ordered_and_contains_elapsed_result_and_worker_count(self) -> None:
        parallel_results = [
            self.module.Result("test/unit/b-test.sh", 0, "", "", 0.1254, "passed"),
            self.module.Result("test/unit/a-test.sh", 1, "", "", 0.3756, "failed"),
        ]
        serial_results = [
            self.module.Result("test/unit/c-test.sh", 130, "", "", 0.0, "cancelled")
        ]
        ledger = self.module.build_result_ledger(
            run_id="run-1",
            started_at="2026-08-29T00:00:00.000000Z",
            completed_at="2026-08-29T00:00:01.000000Z",
            requested_jobs=10,
            parallel_worker_count=2,
            timeout_seconds=300.0,
            parallel_results=parallel_results,
            serial_results=serial_results,
        )

        self.assertEqual(ledger["requested_worker_count"], 10)
        self.assertEqual(ledger["parallel_worker_count"], 2)
        self.assertEqual(ledger["schema_version"], 1)
        self.assertEqual(ledger["run_id"], "run-1")
        self.assertEqual(ledger["started_at"], "2026-08-29T00:00:00.000000Z")
        self.assertEqual(ledger["completed_at"], "2026-08-29T00:00:01.000000Z")
        self.assertEqual(ledger["result"], "failed")
        self.assertEqual(
            [record["path"] for record in ledger["tests"]],
            ["test/unit/b-test.sh", "test/unit/a-test.sh", "test/unit/c-test.sh"],
        )
        self.assertEqual(ledger["tests"][0]["elapsed_seconds"], 0.125)

        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ledger.json"
            self.module.write_result_ledger(path, ledger)
            self.assertEqual(json.loads(path.read_text()), ledger)

    def test_result_ledger_lease_blocks_a_concurrent_runner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ledger.json"
            first = self.module.acquire_result_ledger_lease(path, "run-1")
            try:
                with self.assertRaisesRegex(
                    RuntimeError,
                    "another test runner owns the result ledger",
                ):
                    self.module.acquire_result_ledger_lease(path, "run-2")
            finally:
                self.module.release_result_ledger_lease(first)

            second = self.module.acquire_result_ledger_lease(path, "run-3")
            self.module.release_result_ledger_lease(second)

    def test_python_fixture_with_no_collected_tests_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = "test/unit/test_empty_fixture.py"
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("VALUE = 1\n")

            result = self.module.execute(root, relative, timeout_seconds=2.0)

            self.assertEqual(result.status, "failed")
            self.assertEqual(result.returncode, 3)
            self.assertIn("no unittest cases collected", result.stderr)

    def test_python_fixture_with_a_collected_test_runs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            relative = "test/unit/test_collected_fixture.py"
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(
                "import unittest\n\n"
                "class CollectedTest(unittest.TestCase):\n"
                "    def test_runs(self):\n"
                "        self.assertTrue(True)\n"
            )

            result = self.module.execute(root, relative, timeout_seconds=2.0)

            self.assertEqual(result.status, "passed", result.stderr)
            self.assertEqual(result.returncode, 0)
            self.assertIn("Ran 1 test", result.stderr)

    def test_non_finite_timeouts_are_rejected(self) -> None:
        for value in ("nan", "inf", "-inf", "0", "-1"):
            with self.subTest(value=value):
                with self.assertRaises(Exception):
                    self.module.positive_float(value)


if __name__ == "__main__":
    unittest.main()
