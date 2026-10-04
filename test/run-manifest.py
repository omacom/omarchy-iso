#!/usr/bin/env python3
"""Run the unit tests in two lanes: parallel-safe first, then serial.

test/all used to run every test one after another. Most of them only touch a
throwaway directory and can share a machine, but a few own something global (a
pty, a fixed port, the docker socket) and only behave when nothing else runs
alongside. Rather than guess, every test is listed by hand in one of two
manifests:

  test/parallel-safe.tests  runs concurrently, up to --jobs at a time
  test/serial.tests         runs one at a time, after the parallel lane passed

The manifests are the source of truth, and they must be complete: a test that
exists under test/unit/ but sits in neither manifest is an error, not a silent
skip, so adding a test means deciding which lane it belongs to. Duplicates,
entries that point nowhere, and symlinks are rejected for the same reason.

Each test runs in its own session (process group) with a wall-clock budget. A
timeout or a failure takes the whole group down, including anything the test
left in the background, and cancels the tests that have not finished yet: the
first failure is the one worth reading, and a hung fixture must not keep CI
busy for an hour. A test that exits 0 but leaves a background process behind
is failed as well, since the next test in the same lane would inherit it.

Python tests run one module per process with test/unit on the module path.
That sidesteps `unittest discover`, which imports the modules as a `test.unit`
package and loses to the standard library's own `test` package on hosts that
ship it (macOS, Debian). A module that collects no test cases is a failure,
not a pass.

Every run writes a JSON ledger (default test-runs/unit-test-results.json)
naming each test, its lane, status and elapsed time, so a CI failure can be
read without scrolling through the log.
"""

from __future__ import annotations

import argparse
from concurrent.futures import FIRST_COMPLETED, Future, ThreadPoolExecutor, wait
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import json
import math
from pathlib import Path
import os
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
import uuid


DEFAULT_JOBS = 10
DEFAULT_TEST_TIMEOUT_SECONDS = 300.0
DEFAULT_RESULT_LEDGER = "test-runs/unit-test-results.json"
PROCESS_GROUP_TERMINATION_GRACE_SECONDS = 1.0
TIMEOUT_RETURNCODE = 124
CANCELLED_RETURNCODE = 130
RESULT_LEDGER_SCHEMA_VERSION = 1
TEST_PATTERNS = ("*-test.sh", "test_*.py")
PYTHON_UNITTEST_RUNNER = """
import importlib
import sys
import unittest

module = importlib.import_module(sys.argv[1])
suite = unittest.defaultTestLoader.loadTestsFromModule(module)
if suite.countTestCases() == 0:
    print(f"no unittest cases collected from {sys.argv[1]}", file=sys.stderr)
    raise SystemExit(3)
result = unittest.TextTestRunner().run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
"""


class ManifestError(Exception):
    """The lane manifests disagree with test/unit/; nothing has run."""


@dataclass(frozen=True)
class Result:
    path: str
    returncode: int
    stdout: str
    stderr: str
    elapsed_seconds: float
    status: str

    @property
    def passed(self) -> bool:
        return self.status == "passed"


def read_manifest(path: Path) -> list[str]:
    return [
        line.strip()
        for line in path.read_text().splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def discover(root: Path) -> list[str]:
    return sorted(
        path.relative_to(root).as_posix()
        for pattern in TEST_PATTERNS
        for path in (root / "test/unit").glob(pattern)
    )


def validate(root: Path, parallel: list[str], serial: list[str]) -> None:
    declared = [*parallel, *serial]
    duplicates = sorted({value for value in declared if declared.count(value) > 1})
    if duplicates:
        raise ManifestError("duplicate test manifest entries: " + ", ".join(duplicates))
    discovered = discover(root)
    if sorted(declared) != discovered:
        missing = sorted(set(discovered) - set(declared))
        extra = sorted(set(declared) - set(discovered))
        detail = []
        if missing:
            detail.append(
                "not in test/parallel-safe.tests or test/serial.tests: " + ", ".join(missing)
            )
        if extra:
            detail.append("listed but not under test/unit/: " + ", ".join(extra))
        raise ManifestError("test manifests are incomplete; " + "; ".join(detail))
    for value in declared:
        path = root / value
        if not path.is_file() or path.is_symlink():
            raise ManifestError(f"test path is missing or unsafe: {value}")


def _cancelled_result(relative: str, reason: str) -> Result:
    return Result(
        path=relative,
        returncode=CANCELLED_RETURNCODE,
        stdout="",
        stderr=f"cancelled: {reason}\n",
        elapsed_seconds=0.0,
        status="cancelled",
    )


def _process_group_exists(process_group_id: int) -> bool:
    try:
        os.killpg(process_group_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _terminate_process_group(
    process: subprocess.Popen[str],
    *,
    grace_seconds: float = PROCESS_GROUP_TERMINATION_GRACE_SECONDS,
) -> tuple[str, str]:
    """Stop the test and everything it started; SIGTERM first, SIGKILL after."""

    deadline = time.monotonic() + grace_seconds
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        output: tuple[str, str] | None = process.communicate(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        output = None

    while _process_group_exists(process.pid) and time.monotonic() < deadline:
        time.sleep(0.01)
    if _process_group_exists(process.pid):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if output is None:
        output = process.communicate()

    kill_deadline = time.monotonic() + grace_seconds
    while _process_group_exists(process.pid) and time.monotonic() < kill_deadline:
        time.sleep(0.01)
    if _process_group_exists(process.pid):
        raise RuntimeError(f"process group {process.pid} survived SIGKILL")
    return output


def execute(
    root: Path,
    relative: str,
    *,
    timeout_seconds: float,
    cancel_event: threading.Event | None = None,
) -> Result:
    cancellation = cancel_event or threading.Event()
    if cancellation.is_set():
        return _cancelled_result(relative, "another test failed")

    path = root / relative
    environment = os.environ.copy()
    # test/all exports the bash it was started with, so the tests run under the
    # same interpreter on hosts where /bin/bash is too old (macOS ships 3.2).
    # Its directory goes first on PATH so a test that calls plain `bash` gets
    # that one as well.
    bash = environment.get("OMARCHY_TEST_BASH") or shutil.which("bash")
    if bash is None:
        raise RuntimeError("bash is unavailable")
    bash = str(Path(bash).resolve())
    environment["OMARCHY_TEST_BASH"] = bash
    environment["PATH"] = os.pathsep.join(
        [str(Path(bash).parent), environment.get("PATH", "")]
    )
    if path.suffix == ".py":
        environment["PYTHONPATH"] = os.pathsep.join(
            [str(root / "test/unit"), environment.get("PYTHONPATH", "")]
        )
        command = [sys.executable, "-c", PYTHON_UNITTEST_RUNNER, path.stem]
    else:
        command = [bash, str(path)]

    started = time.monotonic()
    try:
        process = subprocess.Popen(
            command,
            cwd=root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            start_new_session=True,
        )
    except OSError as error:
        cancellation.set()
        return Result(
            path=relative,
            returncode=1,
            stdout="",
            stderr=f"could not start test: {error}\n",
            elapsed_seconds=time.monotonic() - started,
            status="failed",
        )

    deadline = started + timeout_seconds
    while True:
        if cancellation.is_set():
            stdout, stderr = _terminate_process_group(process)
            return Result(
                path=relative,
                returncode=CANCELLED_RETURNCODE,
                stdout=stdout,
                stderr=stderr + "cancelled: another test failed\n",
                elapsed_seconds=time.monotonic() - started,
                status="cancelled",
            )

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            cancellation.set()
            stdout, stderr = _terminate_process_group(process)
            return Result(
                path=relative,
                returncode=TIMEOUT_RETURNCODE,
                stdout=stdout,
                stderr=stderr + f"timed out after {timeout_seconds:g} seconds\n",
                elapsed_seconds=time.monotonic() - started,
                status="timed-out",
            )

        try:
            stdout, stderr = process.communicate(timeout=min(0.1, remaining))
        except subprocess.TimeoutExpired:
            continue

        if _process_group_exists(process.pid):
            _terminate_process_group(process)
            cancellation.set()
            return Result(
                path=relative,
                returncode=1,
                stdout=stdout,
                stderr=stderr + "test left a process group running after exit\n",
                elapsed_seconds=time.monotonic() - started,
                status="failed",
            )

        status = "passed" if process.returncode == 0 else "failed"
        if status != "passed":
            cancellation.set()
        return Result(
            path=relative,
            returncode=process.returncode,
            stdout=stdout,
            stderr=stderr,
            elapsed_seconds=time.monotonic() - started,
            status=status,
        )


def _future_result(future: Future[Result], relative: str) -> Result:
    try:
        return future.result()
    except Exception as error:  # pragma: no cover - defensive worker boundary
        return Result(
            path=relative,
            returncode=1,
            stdout="",
            stderr=f"test runner worker failed: {error}\n",
            elapsed_seconds=0.0,
            status="failed",
        )


def run_parallel(
    root: Path,
    tests: list[str],
    *,
    jobs: int,
    timeout_seconds: float,
) -> list[Result]:
    if not tests:
        return []

    cancellation = threading.Event()
    results: dict[str, Result] = {}
    executor = ThreadPoolExecutor(max_workers=min(jobs, len(tests)))
    futures = {
        executor.submit(
            execute,
            root,
            relative,
            timeout_seconds=timeout_seconds,
            cancel_event=cancellation,
        ): relative
        for relative in tests
    }
    pending = set(futures)
    try:
        while pending:
            completed, pending = wait(pending, return_when=FIRST_COMPLETED)
            for future in completed:
                relative = futures[future]
                results[relative] = _future_result(future, relative)
            if any(not results[futures[future]].passed for future in completed):
                cancellation.set()
                for future in list(pending):
                    if future.cancel():
                        relative = futures[future]
                        results[relative] = _cancelled_result(
                            relative,
                            "another parallel-safe test failed",
                        )
                        pending.remove(future)
    except BaseException:
        cancellation.set()
        for future in pending:
            future.cancel()
        raise
    finally:
        executor.shutdown(wait=True, cancel_futures=True)

    # Report in manifest order regardless of which finished first.
    return [results[relative] for relative in tests]


def run_serial(
    root: Path,
    tests: list[str],
    *,
    timeout_seconds: float,
) -> list[Result]:
    cancellation = threading.Event()
    results: list[Result] = []
    for index, relative in enumerate(tests):
        result = execute(
            root,
            relative,
            timeout_seconds=timeout_seconds,
            cancel_event=cancellation,
        )
        results.append(result)
        if not result.passed:
            results.extend(
                _cancelled_result(value, "an earlier serial test failed")
                for value in tests[index + 1 :]
            )
            break
    return results


def emit(result: Result) -> None:
    print(f"==> {result.path} [{result.status}; {result.elapsed_seconds:.3f}s]")
    if result.stdout:
        print(result.stdout, end="" if result.stdout.endswith("\n") else "\n")
    if result.stderr:
        print(result.stderr, end="" if result.stderr.endswith("\n") else "\n", file=sys.stderr)
    sys.stdout.flush()
    sys.stderr.flush()


def _ledger(
    *,
    run_id: str,
    started_at: str,
    completed_at: str | None,
    result: str,
    requested_jobs: int,
    parallel_worker_count: int,
    timeout_seconds: float,
    tests: list[dict[str, object]],
) -> dict[str, object]:
    return {
        "completed_at": completed_at,
        "kind": "omarchy-unit-test-result-ledger",
        "parallel_worker_count": parallel_worker_count,
        "requested_worker_count": requested_jobs,
        "result": result,
        "run_id": run_id,
        "schema_version": RESULT_LEDGER_SCHEMA_VERSION,
        "started_at": started_at,
        "test_timeout_seconds": timeout_seconds,
        "tests": tests,
    }


def build_result_ledger(
    *,
    run_id: str,
    started_at: str,
    completed_at: str,
    requested_jobs: int,
    parallel_worker_count: int,
    timeout_seconds: float,
    parallel_results: list[Result],
    serial_results: list[Result],
) -> dict[str, object]:
    records: list[dict[str, object]] = [
        {
            "elapsed_seconds": round(result.elapsed_seconds, 3),
            "lane": lane,
            "path": result.path,
            "result": result.status,
            "returncode": result.returncode,
        }
        for lane, results in (
            ("parallel-safe", parallel_results),
            ("serial", serial_results),
        )
        for result in results
    ]
    return _ledger(
        run_id=run_id,
        started_at=started_at,
        completed_at=completed_at,
        result="passed" if all(record["result"] == "passed" for record in records) else "failed",
        requested_jobs=requested_jobs,
        parallel_worker_count=parallel_worker_count,
        timeout_seconds=timeout_seconds,
        tests=records,
    )


def build_incomplete_ledger(
    *,
    run_id: str,
    started_at: str,
    requested_jobs: int,
    parallel_worker_count: int,
    timeout_seconds: float,
    parallel_tests: list[str],
    serial_tests: list[str],
) -> dict[str, object]:
    # Written before anything runs, so a runner that dies mid-way (killed CI
    # job, power loss) leaves a ledger that says "incomplete" rather than the
    # previous run's "passed".
    records: list[dict[str, object]] = [
        {
            "elapsed_seconds": 0.0,
            "lane": lane,
            "path": path,
            "result": "not-run",
            "returncode": None,
        }
        for lane, tests in (
            ("parallel-safe", parallel_tests),
            ("serial", serial_tests),
        )
        for path in tests
    ]
    return _ledger(
        run_id=run_id,
        started_at=started_at,
        completed_at=None,
        result="incomplete",
        requested_jobs=requested_jobs,
        parallel_worker_count=parallel_worker_count,
        timeout_seconds=timeout_seconds,
        tests=records,
    )


def write_result_ledger(path: Path, ledger: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise RuntimeError(f"result ledger path is an unsafe symlink: {path}")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace(
        "+00:00", "Z"
    )


def acquire_result_ledger_lease(path: Path, run_id: str) -> int:
    """Take an exclusive lock next to the ledger so two runners cannot interleave.

    Two `test/all` invocations at once would race each other's ledger writes
    and, worse, each other's serial lane. The lock file is opened O_NOFOLLOW
    and checked to be a plain private file so a symlink dropped in test-runs/
    cannot redirect the write.
    """

    if not run_id or "\n" in run_id:
        raise RuntimeError("test result run identity is invalid")
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(f".{path.name}.lock")
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    cloexec = getattr(os, "O_CLOEXEC", 0)
    if not nofollow:
        raise RuntimeError("safe test result locking is unsupported")
    try:
        descriptor = os.open(
            lock_path,
            os.O_RDWR | os.O_CREAT | nofollow | cloexec,
            0o600,
        )
    except OSError as error:
        raise RuntimeError(f"test result lease is unsafe: {lock_path}") from error
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
            raise RuntimeError(f"test result lease must be a private file: {lock_path}")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError(
                f"another test runner owns the result ledger: {path}"
            ) from error
        payload = f"{run_id}\n".encode()
        os.ftruncate(descriptor, 0)
        os.lseek(descriptor, 0, os.SEEK_SET)
        written = 0
        while written < len(payload):
            count = os.write(descriptor, payload[written:])
            if count <= 0:
                raise RuntimeError("test result lease write made no progress")
            written += count
        os.fsync(descriptor)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def release_result_ledger_lease(descriptor: int) -> None:
    try:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def run_registered_tests(
    *,
    root: Path,
    parallel: list[str],
    serial: list[str],
    jobs: int,
    timeout_seconds: float,
    result_ledger: Path,
    run_id: str,
    started_at: str,
) -> int:
    parallel_worker_count = min(jobs, len(parallel))
    write_result_ledger(
        result_ledger,
        build_incomplete_ledger(
            run_id=run_id,
            started_at=started_at,
            requested_jobs=jobs,
            parallel_worker_count=parallel_worker_count,
            timeout_seconds=timeout_seconds,
            parallel_tests=parallel,
            serial_tests=serial,
        ),
    )

    parallel_results = run_parallel(
        root,
        parallel,
        jobs=jobs,
        timeout_seconds=timeout_seconds,
    )
    for result in parallel_results:
        emit(result)

    if any(not result.passed for result in parallel_results):
        serial_results = [
            _cancelled_result(relative, "a parallel-safe test failed")
            for relative in serial
        ]
    else:
        serial_results = run_serial(
            root,
            serial,
            timeout_seconds=timeout_seconds,
        )
        for result in serial_results:
            emit(result)

    ledger = build_result_ledger(
        run_id=run_id,
        started_at=started_at,
        completed_at=utc_now(),
        requested_jobs=jobs,
        parallel_worker_count=parallel_worker_count,
        timeout_seconds=timeout_seconds,
        parallel_results=parallel_results,
        serial_results=serial_results,
    )
    write_result_ledger(result_ledger, ledger)
    print(f"test result ledger: {result_ledger}")

    failures = [
        result for result in [*parallel_results, *serial_results] if not result.passed
    ]
    if failures:
        print(
            "test failures: "
            + ", ".join(f"{result.path} ({result.status})" for result in failures),
            file=sys.stderr,
        )
        return 1
    return 0


def positive_float(value: str) -> float:
    parsed = float(value)
    if not math.isfinite(parsed) or parsed <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return parsed


def positive_int(value: str) -> int:
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--jobs",
        type=positive_int,
        default=positive_int(os.environ.get("OMARCHY_TEST_JOBS", str(DEFAULT_JOBS))),
        help="parallel-safe tests to run at once (default: %(default)s)",
    )
    parser.add_argument(
        "--test-timeout-seconds",
        type=positive_float,
        default=positive_float(
            os.environ.get("OMARCHY_TEST_TIMEOUT_SECONDS", str(DEFAULT_TEST_TIMEOUT_SECONDS))
        ),
        help="wall-clock budget per test (default: %(default)s)",
    )
    parser.add_argument(
        "--result-ledger",
        type=Path,
        default=Path(os.environ.get("OMARCHY_TEST_RESULT_LEDGER", DEFAULT_RESULT_LEDGER)),
        help="where to write the JSON summary (default: %(default)s)",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="check the manifests against test/unit/ and exit without running",
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    try:
        parallel = read_manifest(root / "test/parallel-safe.tests")
        serial = read_manifest(root / "test/serial.tests")
        validate(root, parallel, serial)
    except (ManifestError, OSError) as error:
        print(f"test runner refused to start: {error}", file=sys.stderr)
        return 2
    if args.validate_only:
        print(f"validated {len(parallel)} parallel-safe and {len(serial)} serial tests")
        return 0

    result_ledger = args.result_ledger
    if not result_ledger.is_absolute():
        result_ledger = root / result_ledger
    run_id = uuid.uuid4().hex
    started_at = utc_now()
    try:
        lease = acquire_result_ledger_lease(result_ledger, run_id)
    except RuntimeError as error:
        print(f"test runner refused to start: {error}", file=sys.stderr)
        return 2
    try:
        return run_registered_tests(
            root=root,
            parallel=parallel,
            serial=serial,
            jobs=args.jobs,
            timeout_seconds=args.test_timeout_seconds,
            result_ledger=result_ledger,
            run_id=run_id,
            started_at=started_at,
        )
    finally:
        release_result_ledger_lease(lease)


if __name__ == "__main__":
    raise SystemExit(main())
