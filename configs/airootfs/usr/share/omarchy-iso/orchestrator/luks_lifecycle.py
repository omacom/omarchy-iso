"""Small, Archinstall-independent helpers for LUKS mapper lifetime."""

from __future__ import annotations

from collections.abc import Collection, Iterator
from contextlib import contextmanager
from typing import Any


@contextmanager
def defer_mapper_locks(luks_type: type, mapper_names: Collection[str]) -> Iterator[None]:
    """Keep selected, already-open mappers alive across a synchronous block.

    Archinstall creates a fresh LUKS mapping, closes it after formatting,
    reopens it to create Btrfs subvolumes, closes it again, and then reopens it
    for the installer.  Each reopen repeats the password KDF.  Temporarily
    deferring locks for only the new mapper names lets the later operations
    reuse the same mapping; unrelated/stale encrypted devices still close
    normally.

    This changes a class method briefly, so callers must use it only in the
    single-threaded filesystem-setup phase.
    """
    selected = frozenset(name for name in mapper_names if name)
    if not selected:
        yield
        return

    original_lock = luks_type.lock
    deferred_instances: dict[str, Any] = {}

    def lock_unless_selected(instance: Any) -> Any:
        mapper_name = getattr(instance, "mapper_name", None)
        if mapper_name in selected and instance.is_unlocked():
            deferred_instances[mapper_name] = instance
            return None
        return original_lock(instance)

    luks_type.lock = lock_unless_selected
    try:
        yield
    except BaseException as setup_error:
        # Normal setup hands the still-open mapping directly to Installer. If
        # setup itself fails, restore Archinstall's cleanup behavior so a retry
        # never inherits a half-prepared mapping.
        luks_type.lock = original_lock
        for instance in deferred_instances.values():
            try:
                if instance.is_unlocked():
                    original_lock(instance)
            except Exception as cleanup_error:
                setup_error.add_note(f"could not close deferred LUKS mapper: {cleanup_error}")
        raise
    finally:
        luks_type.lock = original_lock
