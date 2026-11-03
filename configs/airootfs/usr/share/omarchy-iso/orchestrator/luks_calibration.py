"""Boot-local Argon2id calibration; never stores a passphrase or a header."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

STATE = Path("/run/omarchy-luks-calibration/result.json")
UNIT = "omarchy-luks-calibrate.service"
ITER_TIME = 2000
KEY_SIZE = 512
MIN_MEMORY = 65536
MAX_MEMORY = 1048576
SECTOR_SIZE = 4096


def memory_total() -> int:
    return int(re.search(r"^MemTotal:\s+(\d+)", Path("/proc/meminfo").read_text(), re.M)[1])


def memory_available() -> int:
    return int(re.search(r"^MemAvailable:\s+(\d+)", Path("/proc/meminfo").read_text(), re.M)[1])


def parse_benchmark(output: str) -> dict:
    lines = [line for line in output.splitlines() if line.startswith("argon2id")]
    if len(lines) != 1:
        raise ValueError("expected one argon2id benchmark result")
    match = re.fullmatch(
        r"argon2id\s+(\d+) iterations, (\d+) memory, (\d+) parallel threads "
        r"\(CPUs\) for 512-bit key \(requested 2000 ms time\)", lines[0])
    if not match:
        raise ValueError("unrecognized argon2id benchmark result")
    result = dict(zip(("iterations", "memory", "parallel"), map(int, match.groups())))
    validate_cost(result)
    return result


def validate_cost(data: dict) -> None:
    for key, lower, upper in (("iterations", 4, 2**32 - 1),
                              ("memory", MIN_MEMORY, MAX_MEMORY),
                              ("parallel", 1, 4)):
        if type(data.get(key)) is not int or not lower <= data[key] <= upper:
            raise ValueError(f"invalid {key}")


def calibrate() -> None:
    STATE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    STATE.unlink(missing_ok=True)
    # Below 4 GiB without swap, cryptsetup caps Argon2 at half of *free*
    # RAM (not MemAvailable). The medium's page cache makes that cap change
    # between boot and format. Leave these machines to normal calibration.
    # Also avoid putting a 1 GiB background job onto a busy live environment.
    if memory_total() < 4 * 1024 * 1024 or memory_available() < 1536 * 1024:
        print("Skipping background LUKS calibration: insufficient memory headroom")
        return
    output = subprocess.run(
        ["cryptsetup", "benchmark", "--pbkdf", "argon2id", "--iter-time", str(ITER_TIME),
         "--key-size", str(KEY_SIZE)], check=True, capture_output=True, text=True,
        env={**os.environ, "LC_ALL": "C"}, timeout=60).stdout
    data = parse_benchmark(output)
    # Only reuse the full default memory cost. A benchmark that reduced it
    # (memory pressure or a slow CPU) is not evidence for a reusable policy.
    if data["memory"] != MAX_MEMORY:
        print("Skipping cached LUKS calibration: benchmark reduced the memory cost")
        return
    data.update(schema=1, iter_time=ITER_TIME, key_size=KEY_SIZE,
                cpus=os.cpu_count())
    # A reader sees either no result or the complete, root-owned result.
    fd, name = tempfile.mkstemp(dir=STATE.parent, prefix=".result-")
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream)
            stream.write("\n")
        os.replace(name, STATE)
    finally:
        Path(name).unlink(missing_ok=True)
    print(output.strip())


def stop_calibration() -> None:
    # Cancel a still-running (or queued) benchmark before format's own PBKDF
    # allocates memory. Never wait for calibration to finish. The unit keeps
    # completed state on stop, and systemd kills the benchmark's whole cgroup.
    try:
        subprocess.run(["systemctl", "stop", UNIT], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass


def cached_options(iter_time: int, key_size: int) -> list[str]:
    if iter_time != ITER_TIME or key_size != KEY_SIZE:
        return []
    try:
        # Do not follow symlinks or accept user-writable calibration data.
        fd = os.open(STATE, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd) as stream:
            st = os.fstat(stream.fileno())
            if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022 or st.st_size > 4096:
                return []
            data = json.load(stream)
        if not isinstance(data, dict):
            return []
        validate_cost(data)
        if (data.get("schema") != 1
                or data.get("iter_time") != iter_time or data.get("key_size") != key_size
                or data.get("cpus") != os.cpu_count()
                or data["memory"] != MAX_MEMORY
                or memory_total() < 4 * 1024 * 1024
                or data["memory"] + 256 * 1024 > memory_available()):
            return []
    except (OSError, ValueError, TypeError, KeyError):
        return []
    return ["--pbkdf-force-iterations", str(data["iterations"]),
            "--pbkdf-memory", str(data["memory"]), "--pbkdf-parallel", str(data["parallel"])]


def sector_size_fits(device: str) -> bool:
    """cryptsetup refuses a sector size that does not divide the device."""
    try:
        fd = os.open(device, os.O_RDONLY | os.O_CLOEXEC)
        try:
            size = os.lseek(fd, 0, os.SEEK_END)
        finally:
            os.close(fd)
    except OSError:
        return False
    return size > 0 and size % SECTOR_SIZE == 0


def with_sector_size(command: list[str]) -> list[str]:
    """Encrypt in 4096-byte sectors, btrfs's own block size: with
    cryptsetup's default of 512 every 4 KiB block is eight cipher requests,
    and the sector size cannot change after the format without rewriting
    the whole volume. The device follows luksFormat on both install paths.
    A device whose size 4096 does not divide keeps the default rather than
    failing the format.
    """
    if (not command or command[0] != "cryptsetup" or "luksFormat" not in command
            or "--sector-size" in command):
        return command
    index = command.index("luksFormat") + 1
    if index >= len(command) or not sector_size_fits(command[index]):
        return command
    return command[:index + 1] + ["--sector-size", str(SECTOR_SIZE)] + command[index + 1:]


def format_command(command: list[str]) -> list[str]:
    """The installer's luksFormat: 4096-byte sectors, then this boot's
    Argon2id calibration."""
    return calibrated_command(with_sector_size(command))


def calibrated_command(command: list[str]) -> list[str]:
    """Only the known LUKS2/Argon2id format contract may use this cache.

    Preserve custom policies and every non-format command verbatim. In
    particular archinstall defaults to 10 s unless the config asks for 2 s.
    --iter-time and --pbkdf-force-iterations cannot be combined.
    """
    if (not command or command[0] != "cryptsetup" or "luksFormat" not in command
            or any(flag in command for flag in
                   ("--pbkdf-force-iterations", "--pbkdf-memory", "--pbkdf-parallel"))):
        return command
    def value(flag):
        if command.count(flag) != 1:
            return None
        index = command.index(flag) + 1
        return command[index] if index < len(command) else None
    if value("--type") != "luks2" or value("--pbkdf") != "argon2id":
        return command
    try:
        options = cached_options(int(value("--iter-time")), int(value("--key-size")))
    except (ValueError, TypeError):
        return command
    if not options:
        return command
    index = command.index("--iter-time")
    print("Using this boot's LUKS calibration: " + " ".join(options), file=sys.stderr)
    return command[:index] + options + command[index + 2:]


def main() -> None:
    if sys.argv[1:] == ["calibrate"]:
        calibrate()
    elif len(sys.argv) == 3 and sys.argv[1] == "format":
        stop_calibration()
        # Same free-space format, with the existing defaults made explicit.
        command = ["cryptsetup", "luksFormat", sys.argv[2], "--type", "luks2", "--batch-mode",
                   "--pbkdf", "argon2id", "--key-size", "512", "--iter-time", "2000", "-"]
        os.execvp("cryptsetup", format_command(command))
    else:
        raise SystemExit("usage: omarchy-luks-calibrate calibrate | format DEVICE")


if __name__ == "__main__":
    main()
