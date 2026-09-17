"""Phase state machine. Each phase is a (name, callable) pair; callables take
the InstallContext and either return cleanly or raise to abort the install."""

from __future__ import annotations

import json
import os
import re
import time
import traceback
import uuid
from collections.abc import Callable
from pathlib import Path

from . import leaderboard
from .context import InstallContext
from .ui import error, info

# Version of the timing document written to the target. Readers of the file
# key off this, so bump it when a field changes meaning, not when one is added.
TIMING_SCHEMA = 1


PhaseFn = Callable[[InstallContext], None]


class PhaseError(Exception):
    """Raised when a phase fails. Wrapped with the phase name."""


def run(ctx: InstallContext, phases: list[tuple[str, PhaseFn]]) -> None:
    ctx.state_dir.mkdir(parents=True, exist_ok=True)
    state_path = ctx.state_dir / "state.json"
    # The lap time is the span the finish screen has always shown, from here
    # to the end of the last phase, on a monotonic clock so an NTP step or a
    # timezone fix mid-install cannot shorten or lengthen it.
    run_started_ns = time.monotonic_ns()
    state = {
        "schema": TIMING_SCHEMA,
        # Minted before the first phase so a run that fails still has a name in
        # its log, and a run that finishes is matched to its screen by it.
        "run_id": str(uuid.uuid4()),
        "started_at": time.time(),
        # The dashboard counts packages under <target>/var/lib/pacman/local;
        # publish the path rather than have the UI assume /mnt.
        "target": str(ctx.target),
        "total_phases": len(phases),
        "current_index": 0,
        "current_phase": "Starting installation",
        "phases": [],
    }
    _write_state(state_path, state)

    for index, (name, fn) in enumerate(phases):
        state["current_index"] = index
        state["current_phase"] = name
        state["phase_started_at"] = time.time()
        _write_state(state_path, state)

        info(f"› {name}")
        # Wall clock stays for the dashboard and the log; the sectors are
        # monotonic like the lap.
        started = time.time()
        started_ns = time.monotonic_ns()
        try:
            fn(ctx)
        except Exception as exc:  # noqa: BLE001
            elapsed_ns = time.monotonic_ns() - started_ns
            elapsed = time.time() - started
            state["phases"].append({
                "name": name,
                "id": phase_id(name, fn),
                "status": "failed",
                "elapsed": elapsed,
                "elapsed_ns": elapsed_ns,
                "error": str(exc),
            })
            _write_state(state_path, state)

            error(f"Phase '{name}' failed after {elapsed:.1f}s: {exc}")
            traceback.print_exc()
            raise PhaseError(f"phase {name} failed: {exc}") from exc

        elapsed_ns = time.monotonic_ns() - started_ns
        elapsed = time.time() - started
        state["phases"].append({
            "name": name,
            "id": phase_id(name, fn),
            "status": "ok",
            "elapsed": elapsed,
            "elapsed_ns": elapsed_ns,
        })
        _write_state(state_path, state)

    state["current_index"] = max(len(phases) - 1, 0)
    state["current_phase"] = "Installation complete"
    state["finished_at"] = time.time()
    # The lap, not the sum of the sectors: the phases add up to slightly less,
    # and the difference is the orchestrator's own overhead between them.
    state["total_elapsed_ns"] = time.monotonic_ns() - run_started_ns
    # Expected vs actual for the bar's denominator, so drift is visible in
    # acceptance runs rather than only by watching a bar creep.
    state["installed_packages"] = _installed_package_count(ctx.target)
    state["expected_packages"] = _expected_package_count()
    _write_state(state_path, state)

    try:
        leaderboard.finalize(ctx, state)
    except Exception as exc:  # noqa: BLE001 — the timing file never fails an install
        info(f"› leaderboard: artifact not written ({exc}); keeping the plain timing file")
        timing_path = ctx.target / leaderboard.TIMING_LOG
        timing_path.parent.mkdir(parents=True, exist_ok=True)
        _write_state(timing_path, state)


def phase_id(name: str, fn: PhaseFn) -> str:
    """A stable identifier for a phase: the callable's name, which survives a
    reworded display name. Anything without a name gets a slug of the name it
    was shown under."""
    ident = getattr(fn, "__name__", None)
    if isinstance(ident, str) and ident.isidentifier() and not ident.startswith("<"):
        return ident
    return re.sub(r"[^a-z0-9]+", "_", name.lower()).strip("_") or "phase"


def _installed_package_count(target: Path) -> int:
    """Packages libalpm installed into the target — one directory each under
    local/, which is what the dashboard counts live."""
    local_db = target / "var" / "lib" / "pacman" / "local"
    try:
        with os.scandir(local_db) as entries:
            return sum(1 for entry in entries if entry.is_dir())
    except OSError:
        return 0


def _expected_package_count() -> int:
    path = Path("/usr/share/omarchy-iso/expected-packages")
    try:
        return int(path.read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return 0


def _write_state(path: Path, state: dict) -> None:
    # Dashboard polls this file while phases update it. Write atomically so the
    # reader never observes a truncated/partial JSON document and resets UI.
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(state, indent=2, default=str))
    tmp.replace(path)
