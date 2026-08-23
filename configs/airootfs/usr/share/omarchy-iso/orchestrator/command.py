r"""Reading text out of the commands the installer shells out to.

Firmware and filesystem metadata reach the orchestrator as command output, and
neither is obliged to be UTF-8: an HP ProBook's NVRAM held a legacy BBS entry
whose device path began `BBS(HD,\x80\x7f\xff\x04`, efibootmgr printed those
bytes verbatim, and subprocess's strict text decoding turned a boot entry
nothing here reads into a failed install.

So capture() replaces what it cannot decode, and the boot-entry parsing that
reads its output stays tolerant on purpose: the decisions taken from a firmware
label are advisory, and refusing a junk one would abort the install this exists
to let finish. An identifier is the other case entirely — require_text() refuses
a UUID or a device name that came through mangled, because that one is written
into fstab and the kernel cmdline, or handed to mount.
"""

from __future__ import annotations

import subprocess

REPLACEMENT = "\ufffd"


def capture(cmd: list[str], *, check: bool = False) -> subprocess.CompletedProcess:
    """Run cmd and return it with stdout/stderr decoded, bad bytes replaced."""
    return subprocess.run(
        cmd,
        check=check,
        capture_output=True,
        text=True,
        errors="replace",
    )


def require_text(value: str, what: str) -> str:
    """Refuse a value the installed system depends on if bytes were replaced in it.

    Validation reads these back from the same command that wrote them, so a
    mangled UUID agrees with itself and ships a machine that cannot find its
    root at boot. Stopping here says why while someone is still watching.
    """
    if REPLACEMENT in value:
        raise RuntimeError(f"{what} is not valid text: {value!r}")
    return value


def capture_identifier(cmd: list[str], what: str) -> str:
    """Capture a single value the installed system will depend on."""
    return require_text(capture(cmd, check=True).stdout.strip(), what)
