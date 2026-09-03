"""Phase state machine. Each phase is a (name, callable) pair; callables take
the InstallContext and either return cleanly or raise to abort the install."""

from __future__ import annotations

import json
import os
import time
import traceback
from collections.abc import Callable
from pathlib import Path

from .context import InstallContext
from .ui import error, info


PhaseFn = Callable[[InstallContext], None]


class PhaseError(Exception):
    """Raised when a phase fails. Wrapped with the phase name."""


def run(ctx: InstallContext, phases: list[tuple[str, PhaseFn]]) -> None:
    ctx.state_dir.mkdir(parents=True, exist_ok=True)
    state_path = ctx.state_dir / "state.json"
    install_started = time.monotonic()
    state = {
        "started_at": time.time(),
        # The dashboard counts packages under <target>/var/lib/pacman/local;
        # publish the path rather than have the UI assume /mnt.
        "target": str(ctx.target),
        "total_phases": len(phases),
        "current_index": 0,
        "current_phase": "Starting installation",
        "phases": [],
    }
    write_state(state_path, state)

    for index, (name, fn) in enumerate(phases):
        state["current_index"] = index
        state["current_phase"] = name
        state["phase_started_at"] = time.time()
        # Phases that can measure themselves (the root image unpack) publish
        # phase_progress for the dashboard; it means nothing across phases.
        state.pop("phase_progress", None)
        # Concrete phases can publish finer-grained monotonic timings through
        # ctx.state. Start every phase with an empty list so an interrupted
        # phase can never inherit measurements from the previous one.
        ctx.state.pop("phase_substeps", None)
        write_state(state_path, state)

        info(f"› {name}")
        started = time.monotonic()
        try:
            fn(ctx)
        except Exception as exc:  # noqa: BLE001
            elapsed = time.monotonic() - started
            entry = {
                "name": name,
                "status": "failed",
                "elapsed": elapsed,
                "error": str(exc),
            }
            if substeps := ctx.state.pop("phase_substeps", []):
                entry["substeps"] = substeps
            state["phases"].append(entry)
            write_state(state_path, state)

            error(f"Phase '{name}' failed after {elapsed:.1f}s: {exc}")
            traceback.print_exc()
            raise PhaseError(f"phase {name} failed: {exc}") from exc

        elapsed = time.monotonic() - started
        entry = {"name": name, "status": "ok", "elapsed": elapsed}
        if substeps := ctx.state.pop("phase_substeps", []):
            entry["substeps"] = substeps
        state["phases"].append(entry)
        write_state(state_path, state)

    state["current_index"] = max(len(phases) - 1, 0)
    state["current_phase"] = "Installation complete"
    state["finished_at"] = time.time()
    # Wall time is useful when correlating the install with other logs, but it
    # can jump when firmware time is wrong or a live-system clock is corrected.
    # The monotonic duration is the authoritative performance measurement.
    state["duration_seconds"] = time.monotonic() - install_started
    # Expected vs actual for the bar's denominator, so drift is visible in
    # acceptance runs rather than only by watching a bar creep.
    state["installed_packages"] = _installed_package_count(ctx.target)
    state["expected_packages"] = _expected_package_count()
    write_state(state_path, state)

    timing_path = ctx.target / "var" / "log" / "omarchy-install-timing.json"
    timing_path.parent.mkdir(parents=True, exist_ok=True)
    write_state(timing_path, state)


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


def write_state(path: Path, state: dict) -> None:
    # Dashboard polls this file while phases update it. Write atomically so the
    # reader never observes a truncated/partial JSON document and resets UI.
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text(json.dumps(state, indent=2, default=str))
    tmp.replace(path)
