"""Boot-local Argon2id calibration; never stores a passphrase or a header."""
from __future__ import annotations

from collections.abc import Callable
import json
import mmap
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import threading
import time
from typing import TypeVar

_T = TypeVar("_T")

STATE = Path("/run/omarchy-luks-calibration/result.json")
# The live system's other boot-time install jobs, stopped before luksFormat
# so neither gpg nor multi-GB cache warm-up competes with Argon2id.
EARLY_KEYRING_UNIT = "omarchy-target-keyring-early.service"
CACHE_WARM_UNIT = "omarchy-cache-warm.service"
UNIT = "omarchy-luks-calibrate.service"
ITER_TIME = 2000
KEY_SIZE = 512
MIN_MEMORY = 65536
MAX_MEMORY = 1048576
PRETOUCH_MEMORY = MAX_MEMORY + 128 * 1024  # 1152 MiB: clears 1 GiB + kswapd watermark headroom
FREE_HEADROOM = MAX_MEMORY + 384 * 1024    # 1408 MiB: skip pretouch when MemFree already exceeds this
SECTOR_SIZE = 4096
VOLUME_KEY_DIR = Path("/run")
ASYNC_MIN_CPUS = 4
ASYNC_MIN_MEMORY = 2560 * 1024  # 2.5 GiB available so 1 GiB Argon2id never pressures install
ATOM_CPUS_PATH = Path("/sys/devices/cpu_atom/cpus")
ONLINE_CPUS_PATH = Path("/sys/devices/system/cpu/online")
CPUINFO_PATH = Path("/proc/cpuinfo")
# Without AES instructions, AES-XTS runs in software at a fraction of the
# disk's speed and through table lookups that leak timing. Adiantum is built
# for those CPUs: XChaCha12 and NH do the bulk work, and AES runs once per
# sector. Its key is 256 bits; aes-xts-plain64 takes 512.
ADIANTUM_CIPHER = "xchacha12,aes-adiantum-plain64"
ADIANTUM_KEY_SIZE = 256


def _parse_cpu_set(spec: str) -> set[int]:
    cpus: set[int] = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            lo, hi = part.split("-", 1)
            cpus.update(range(int(lo), int(hi) + 1))
        else:
            cpus.add(int(part))
    return cpus


def _format_cpu_set(cpus: set[int]) -> str:
    if not cpus:
        return ""
    ordered = sorted(cpus)
    ranges: list[str] = []
    start = prev = ordered[0]
    for cpu in ordered[1:]:
        if cpu == prev + 1:
            prev = cpu
        else:
            ranges.append(f"{start}-{prev}" if start != prev else str(start))
            start = prev = cpu
    ranges.append(f"{start}-{prev}" if start != prev else str(start))
    return ",".join(ranges)


def _enroll_parallel(cmd: list[str]) -> int:
    for idx, arg in enumerate(cmd):
        if arg == "--pbkdf-parallel" and idx + 1 < len(cmd):
            try:
                return max(1, int(cmd[idx + 1]))
            except ValueError:
                return 4
    return 4


def memory_total() -> int:
    return int(re.search(r"^MemTotal:\s+(\d+)", Path("/proc/meminfo").read_text(), re.M)[1])


def memory_available() -> int:
    return int(re.search(r"^MemAvailable:\s+(\d+)", Path("/proc/meminfo").read_text(), re.M)[1])


def memory_free() -> int:
    return int(re.search(r"^MemFree:\s+(\d+)", Path("/proc/meminfo").read_text(), re.M)[1])


def _pretouch_benchmark_memory(target_kib: int = PRETOUCH_MEMORY) -> None:
    """Reclaim clean page cache before cryptsetup starts its wall-clock timer.

    The verify units fill RAM with clean page cache right before this service
    runs, leaving MemFree around 200-300 MiB on an 8 GiB machine. Without free
    pages ready, cryptsetup's first 1 GiB Argon2id trial pays 1-2 s of kswapd
    reclaim and THP compaction inside clock_gettime(), which can push a low
    iteration count into cryptsetup's [1900, 2200] ms acceptance window or end
    Phase 1 early at 4 iterations. Allocating and faulting ~1.1 GiB once
    beforehand moves that reclaim outside the benchmark window; on machines
    that already have enough MemFree it is a no-op, and unlike drop_caches it
    only evicts the oldest LRU pages that cryptsetup itself is about to evict.
    """
    if memory_free() >= FREE_HEADROOM:
        return
    size = target_kib * 1024
    page = os.sysconf("SC_PAGESIZE")
    try:
        with mmap.mmap(-1, size, flags=mmap.MAP_PRIVATE) as buf:
            view = memoryview(buf)
            try:
                view[::page] = b"\x01" * (size // page)
            finally:
                view.release()
    except (MemoryError, OSError):
        pass


def _has_fixed_iterations(command: list[str]) -> bool:
    return any(arg == "--pbkdf-force-iterations" or arg.startswith("--pbkdf-force-iterations=")
               for arg in command)


def stop_early_keyring() -> None:
    """Stop omarchy-target-keyring-early.service so gpg does not share CPUs
    with a live Argon2id benchmark. A finished keyring stays in place."""
    try:
        subprocess.run(["systemctl", "stop", EARLY_KEYRING_UNIT], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass


def pretouch_for_format(command: list[str]) -> None:
    """Prepare the live system before an uncached Argon2id luksFormat
    benchmark: stop any in-flight early keyring (including for custom
    --iter-time/--key-size policies that bypass the standard cache) and
    reclaim clean page cache outside cryptsetup's wall-clock timer."""
    if "luksFormat" not in command:
        return
    if _has_fixed_iterations(command):
        return
    stop_early_keyring()
    if memory_total() < 4 * 1024 * 1024 or memory_available() < 1536 * 1024:
        return
    _pretouch_benchmark_memory()


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
    _pretouch_benchmark_memory()
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


def _calibration_pending() -> bool:
    """Whether the unit's benchmark is running, or queued to run."""
    output = subprocess.run(["systemctl", "show", UNIT, "--property=ActiveState,Job"],
                            check=False, capture_output=True, text=True, timeout=5).stdout
    state = dict(line.split("=", 1) for line in output.splitlines() if "=" in line)
    return state.get("ActiveState") in ("active", "activating") or bool(state.get("Job"))


def stop_calibration(wait: float = 20) -> None:
    """Before the format: let a benchmark that is under way finish, then stop
    the unit, so the format's own PBKDF never allocates memory beside it.

    The unit starts when the hashes of the medium end, which is also when an
    install that was waiting for them begins: an unattended one, or a wizard
    answered before the stick was read. Cancelling the benchmark there threw
    its work away and had the format run the same search from the start (a
    7.6 s format against 1.5 s with the costs known, where the benchmark
    itself takes 5 s). The wait is bounded: a benchmark that outlasts it is
    stopped, and the format calibrates as it always could. The unit keeps
    completed state on stop, and systemd kills the benchmark's whole cgroup.
    """
    try:
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline and _calibration_pending():
            time.sleep(0.2)
    except (OSError, subprocess.TimeoutExpired):
        pass  # a poll that fails ends the wait, not the stop
    # Always stop calibration and page-cache warm-up before luksFormat so
    # neither a running benchmark nor multi-GB reads compete with formatting.
    # Only stop early keyring generation when no cached calibration is ready:
    # a cached format uses fixed --pbkdf-force-iterations (no live benchmark),
    # so killing an in-flight keyring throws away seconds of gpg work for no
    # gain and forces a synchronous rebuild at the end of the install.
    for unit in (UNIT, CACHE_WARM_UNIT):
        try:
            subprocess.run(["systemctl", "stop", unit], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            pass
    if not cached_options(ITER_TIME, KEY_SIZE):
        stop_early_keyring()


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


def has_aes_acceleration() -> bool:
    """Whether every CPU has AES instructions: `aes` in `flags` (x86 AES-NI)
    or `Features` (arm64 crypto extensions), or `zknd`+`zkne` / `zvkned` in
    `isa` (RISC-V crypto extensions). Unreadable cpuinfo or other
    architectures count as accelerated and keep cryptsetup's default."""
    try:
        text = CPUINFO_PATH.read_text(errors="replace")
    except OSError:
        return True
    for line in text.splitlines():
        field, sep, value = line.partition(":")
        if not sep:
            continue
        field, value = field.strip(), value.strip()
        if field in ("flags", "Features") and "aes" not in value.split():
            return False
        if field == "isa" and value.lower().startswith("rv"):
            exts = set(value.lower().split("_")[1:])
            if not ({"zknd", "zkne"} <= exts or exts & {"zkn", "zk", "zvkned", "zvkn", "zvk"}):
                return False
    return True


def volume_key_size() -> int:
    """Bits of the volume key the installer's format uses on this CPU."""
    return KEY_SIZE if has_aes_acceleration() else ADIANTUM_KEY_SIZE


def with_cipher(command: list[str]) -> list[str]:
    """Format with Adiantum (256-bit key) on CPUs without AES instructions.
    Leaves commands with an explicit cipher and non-format commands unchanged."""
    if (not command or command[0] != "cryptsetup" or "luksFormat" not in command
            or any(arg in ("--cipher", "-c") or arg.startswith("--cipher=") for arg in command)
            or has_aes_acceleration()):
        return command
    print(f"No AES instructions on this CPU: formatting with {ADIANTUM_CIPHER}", file=sys.stderr)
    out = [command[0], "--cipher", ADIANTUM_CIPHER, "--key-size", str(ADIANTUM_KEY_SIZE)]
    args = iter(command[1:])
    for arg in args:
        if arg in ("--key-size", "-s"):
            next(args, None)
        elif not arg.startswith("--key-size="):
            out.append(arg)
    return out


def new_volume_key(key_size: int | None = None) -> Path:
    """A random volume key in a root-only file on tmpfs, for luksFormat
    --volume-key-file. Opening the new volume with the same file takes no key
    derivation, where opening it by passphrase repeats the Argon2id the
    format just did (2 s at the installer's iter-time). The kernel's
    generator, as luksFormat --use-urandom would use; the caller removes the
    file once the volume is open. Sized for this CPU's cipher by default."""
    if key_size is None:
        key_size = volume_key_size()
    fd, name = tempfile.mkstemp(dir=VOLUME_KEY_DIR, prefix="omarchy-volume-key-")
    with os.fdopen(fd, "wb") as stream:
        stream.write(os.urandom(key_size // 8))
    return Path(name)


def format_command(command: list[str], volume_key: Path | None = None) -> list[str]:
    """The installer's luksFormat: 4096-byte sectors, this boot's Argon2id
    calibration, Adiantum on a CPU without AES instructions, and the volume
    key the open will use. The cipher comes after the calibration, whose
    cache is keyed on the request's 512-bit --key-size."""
    command = with_cipher(calibrated_command(with_sector_size(command)))
    if volume_key is not None:
        command = command[:1] + ["--volume-key-file", str(volume_key)] + command[1:]
    return command


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


def can_defer_keyslot() -> bool:
    """Whether this machine has enough CPUs and memory headroom to overlap
    Argon2id slot-0 enrollment with post-image-write setup."""
    return (
        os.environ.get("OMARCHY_LUKS_ASYNC_KEYSLOT", "1") == "1"
        and (os.cpu_count() or 1) >= ASYNC_MIN_CPUS
        and memory_total() >= 4 * 1024 * 1024
        and memory_available() >= ASYNC_MIN_MEMORY
    )


def deferred_format_command(
    command: list[str],
    volume_key: Path,
    temp_keyfile: Path,
) -> tuple[list[str], list[str], list[str]] | None:
    """Split a LUKS2/Argon2id format into a fast temporary slot-1 format
    (~20 ms) plus background slot-0 Argon2id enrollment and slot-1 removal.

    The fast format installs a random tmpfs keyfile into slot 1 with minimal
    PBKDF2 cost so the installer can unlock immediately via --volume-key-file
    and run omarchy-image-write at full speed. Once the image write finishes,
    the background job enrolls the user's real passphrase into slot 0 with the
    boot's calibrated Argon2id parameters (or --iter-time when boot calibration
    had not finished before format) and kills slot 1. Returns None when
    conditions are not met, leaving the caller on the synchronous path.
    """
    if not can_defer_keyslot():
        return None
    if (not command or command[0] != "cryptsetup" or "luksFormat" not in command
            or _has_fixed_iterations(command)
            or any(flag in command for flag in (
                "--pbkdf-memory", "--pbkdf-parallel",
                "--key-slot", "--key-file", "-d"))):
        return None
    luks_index = command.index("luksFormat")
    if luks_index + 2 != len(command):
        return None
    device = command[luks_index + 1]

    def value(flag: str) -> str | None:
        if command.count(flag) != 1:
            return None
        idx = command.index(flag) + 1
        return command[idx] if idx < len(command) else None

    if value("--type") != "luks2" or value("--pbkdf") != "argon2id":
        return None
    try:
        iter_time = int(value("--iter-time"))
        key_size = int(value("--key-size"))
    except (ValueError, TypeError):
        return None
    if iter_time != ITER_TIME or key_size != KEY_SIZE:
        return None
    options = cached_options(iter_time, key_size) or ["--iter-time", str(iter_time)]

    hash_alg = value("--hash")
    fast_cmd = with_cipher(with_sector_size(command))
    pbkdf_idx = fast_cmd.index("--pbkdf")
    fast_cmd = fast_cmd[:pbkdf_idx] + ["--pbkdf", "pbkdf2"] + fast_cmd[pbkdf_idx + 2:]
    iter_idx = fast_cmd.index("--iter-time")
    fast_cmd = fast_cmd[:iter_idx] + ["--pbkdf-force-iterations", "1000"] + fast_cmd[iter_idx + 2:]
    fast_cmd = (
        fast_cmd[:1]
        + ["--volume-key-file", str(volume_key), "--key-slot", "1"]
        + fast_cmd[1:]
        + [str(temp_keyfile)]
    )

    enroll_cmd = [
        "cryptsetup", "--batch-mode", "luksAddKey",
        "--key-slot", "0",
        "--volume-key-file", str(volume_key),
        "--pbkdf", "argon2id", *options,
    ]
    if hash_alg:
        enroll_cmd += ["--hash", hash_alg]
    enroll_cmd += [device, "-"]

    kill_cmd = ["cryptsetup", "--batch-mode", "luksKillSlot", device, "1"]
    print("Deferring LUKS Argon2id keyslot (slot 0): " + " ".join(options), file=sys.stderr)
    return fast_cmd, enroll_cmd, kill_cmd


class DeferredKeyslot:
    """Background Argon2id slot-0 enrollment paired with slot-1 removal.

    Always removes both temporary key files from /run in its finally path,
    whether enrollment succeeded, failed, or was aborted.
    """

    def __init__(
        self,
        device: str,
        volume_key: Path,
        temp_keyfile: Path,
        enroll_cmd: list[str],
        kill_cmd: list[str],
        passphrase: bytes,
    ) -> None:
        self.device = device
        self.volume_key = volume_key
        self.temp_keyfile = temp_keyfile
        self.enroll_cmd = enroll_cmd
        self.kill_cmd = kill_cmd
        self._passphrase = bytes(passphrase)
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._proc: subprocess.Popen | None = None
        self._aborted = False
        self._done = False
        self.error: str | None = None

    def _cleanup_files(self) -> None:
        self._passphrase = b""
        self.volume_key.unlink(missing_ok=True)
        self.temp_keyfile.unlink(missing_ok=True)

    def _run_step(self, cmd: list[str], *, input_data: bytes | None = None) -> tuple[int, str]:
        with self._lock:
            if self._aborted:
                return 1, "aborted"
            proc = subprocess.Popen(
                cmd,
                stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            self._proc = proc
        try:
            out, _ = proc.communicate(input=input_data)
            return proc.returncode, (out or b"").decode(errors="replace").strip()
        finally:
            with self._lock:
                if self._proc is proc:
                    self._proc = None

    @staticmethod
    def _online_atom_cpus(cmd: list[str], all_cpus: str) -> str:
        try:
            if not ATOM_CPUS_PATH.is_file():
                return ""
            atom = _parse_cpu_set(ATOM_CPUS_PATH.read_text().strip())
            atom &= _parse_cpu_set(all_cpus)
            if ONLINE_CPUS_PATH.is_file():
                atom &= _parse_cpu_set(ONLINE_CPUS_PATH.read_text().strip())
            if len(atom) >= _enroll_parallel(cmd):
                return _format_cpu_set(atom)
        except (OSError, ValueError):
            pass
        return ""

    def _worker(self) -> None:
        # On a hybrid CPU omarchy-iso-install pins the installer to performance
        # cores and records the original mask in OMARCHY_INSTALLER_ALL_CPUS.
        # Running the Argon2id threads on cpu_atom (when enough E-cores are
        # online) keeps P-cores free for image write and setup; otherwise fall
        # back to all installer CPUs (and retry there if taskset fails affinity).
        try:
            all_cpus = os.environ.get("OMARCHY_INSTALLER_ALL_CPUS")
            atom = self._online_atom_cpus(self.enroll_cmd, all_cpus) if all_cpus else ""
            if atom:
                rc, out = self._run_step(["taskset", "-c", atom, *self.enroll_cmd], input_data=self._passphrase)
                if rc != 0 and "affinity" in out.lower():
                    rc, out = self._run_step(["taskset", "-c", all_cpus, *self.enroll_cmd], input_data=self._passphrase)
            else:
                rc, out = self._run_step(
                    ["taskset", "-c", all_cpus, *self.enroll_cmd] if all_cpus else self.enroll_cmd,
                    input_data=self._passphrase,
                )
            if rc != 0:
                self.error = f"cryptsetup luksAddKey failed (exit {rc}): {out}"
                return
            rc, out = self._run_step(self.kill_cmd)
            if rc != 0:
                self.error = f"cryptsetup luksKillSlot failed (exit {rc}): {out}"
        except OSError as exc:
            self.error = f"cryptsetup keyslot enrollment failed: {exc}"
        finally:
            self._cleanup_files()
            self._done = True

    def start(self) -> None:
        if self._thread is not None or self._done:
            return
        self._thread = threading.Thread(target=self._worker, name="omarchy-luks-keyslot", daemon=True)
        self._thread.start()

    def join(self, *, raise_on_error: bool = True) -> None:
        if self._thread is None and not self._done:
            if not raise_on_error:
                self._cleanup_files()
                self._done = True
                return
            self.start()
        if self._thread is not None:
            self._thread.join()
        self._cleanup_files()
        if raise_on_error and self.error is not None:
            raise RuntimeError(self.error)

    def abort(self) -> None:
        with self._lock:
            self._aborted = True
            proc = self._proc
        if proc is not None:
            try:
                proc.terminate()
            except OSError:
                pass
        if self._thread is not None:
            self._thread.join(timeout=5)
        self._cleanup_files()
        self._done = True


OPEN_FLAGS = ("--persistent", "--allow-discards", "--perf-no_read_workqueue")


def run_luks_format(
    command: list[str],
    *,
    volume_key: Path,
    passphrase: bytes | bytearray | None,
    run_deferred: Callable[[list[str]], _T],
    run_sync: Callable[[list[str]], _T],
    allow_defer: bool = True,
    sync_command: list[str] | None = None,
    stop_calibration_first: bool = True,
) -> tuple[_T, DeferredKeyslot | None]:
    """Run a LUKS2 format on either the deferred or calibrated synchronous path.

    Shared by both full-disk (`luks_tuning._with_calibration`) and free-space
    (`format_and_open_luks`) installers.

    When `allow_defer` is True, `passphrase` is non-empty bytes, and
    `can_defer_keyslot()` holds, stops calibration without waiting and attempts
    `deferred_format_command()`. On success, stops the early keyring when the
    deferred enrollment will run an uncached benchmark, executes `fast_cmd` via
    `run_deferred`, and returns `(result, DeferredKeyslot)`. If anything raises
    (including `KeyboardInterrupt`) before `DeferredKeyslot` takes ownership,
    the temporary slot-1 keyfile is unlinked before re-raising.

    Otherwise stops calibration (if not already stopped), formats via
    `format_command()` + `pretouch_for_format()` using `run_sync`, and returns
    `(result, None)`.
    """
    calibration_stopped = False
    can_try_defer = (
        allow_defer
        and isinstance(passphrase, (bytes, bytearray))
        and bool(passphrase)
        and can_defer_keyslot()
    )
    if can_try_defer:
        if stop_calibration_first:
            stop_calibration(wait=0)
            calibration_stopped = True
        temp_keyfile = new_volume_key(256)
        try:
            split = deferred_format_command(command, volume_key, temp_keyfile)
            if split is not None:
                fast_cmd, enroll_cmd, kill_cmd = split
                if not _has_fixed_iterations(enroll_cmd):
                    stop_early_keyring()
                device = command[command.index("luksFormat") + 1]
                result = run_deferred(fast_cmd)
                entry = DeferredKeyslot(
                    device=device,
                    volume_key=volume_key,
                    temp_keyfile=temp_keyfile,
                    enroll_cmd=enroll_cmd,
                    kill_cmd=kill_cmd,
                    passphrase=bytes(passphrase),
                )
                return result, entry
        except BaseException:
            temp_keyfile.unlink(missing_ok=True)
            raise
        temp_keyfile.unlink(missing_ok=True)

    if stop_calibration_first and not calibration_stopped:
        stop_calibration()
    argv = format_command(command if sync_command is None else sync_command, volume_key)
    pretouch_for_format(argv)
    return run_sync(argv), None


def format_and_open_luks(
    device: str,
    mapper_name: str,
    passphrase: bytes,
    *,
    open_flags: tuple[str, ...] = OPEN_FLAGS,
) -> DeferredKeyslot | None:
    """Format `device` as LUKS2 (4096-byte sectors when size divides 4096) and
    open it at `/dev/mapper/<mapper_name>` with the generated volume key.

    When `can_defer_keyslot()` holds, formats with a fast temporary PBKDF2
    slot 1 (~20 ms), opens via `--volume-key-file` (keeping the volume key
    alive), and returns a `DeferredKeyslot` ready to enroll Argon2id slot 0
    and kill slot 1 in the background. Otherwise runs calibrated synchronous
    Argon2id `luksFormat`, opens via `--volume-key-file`, deletes the volume
    key, and returns None.

    Passphrase bytes are piped on stdin and never appear in argv. Temporary
    key files are always unlinked on error before re-raising.
    """
    if not isinstance(passphrase, (bytes, bytearray)) or not passphrase:
        raise RuntimeError("LUKS encryption requires a non-empty passphrase")
    passphrase_bytes = bytes(passphrase)
    volume_key = new_volume_key()
    deferred_entry: DeferredKeyslot | None = None
    try:
        base_cmd = [
            "cryptsetup", "--type", "luks2", "--batch-mode",
            "--pbkdf", "argon2id", "--key-size", str(KEY_SIZE),
            "--iter-time", str(ITER_TIME), "luksFormat", device,
        ]
        sync_base_cmd = [
            "cryptsetup", "luksFormat", device, "--type", "luks2",
            "--batch-mode", "--pbkdf", "argon2id",
            "--key-size", str(KEY_SIZE), "--iter-time", str(ITER_TIME), "-",
        ]
        _, deferred_entry = run_luks_format(
            base_cmd,
            volume_key=volume_key,
            passphrase=passphrase_bytes,
            run_deferred=lambda cmd: subprocess.run(cmd, check=True),
            run_sync=lambda cmd: subprocess.run(cmd, input=passphrase_bytes, check=True),
            sync_command=sync_base_cmd,
        )
        subprocess.run(
            [
                "cryptsetup", "open", *open_flags,
                "--volume-key-file", str(volume_key), device, mapper_name,
            ],
            check=True,
        )
    except BaseException:
        if deferred_entry is not None:
            deferred_entry.abort()
        else:
            volume_key.unlink(missing_ok=True)
        raise
    if deferred_entry is None:
        volume_key.unlink(missing_ok=True)
    return deferred_entry


def main() -> None:
    if sys.argv[1:] == ["calibrate"]:
        calibrate()
    elif sys.argv[1:] == ["volume-key"]:
        print(new_volume_key())
    elif len(sys.argv) in (3, 4) and sys.argv[1] == "format":
        stop_calibration()
        # Same free-space format, with the existing defaults made explicit.
        command = ["cryptsetup", "luksFormat", sys.argv[2], "--type", "luks2", "--batch-mode",
                   "--pbkdf", "argon2id", "--key-size", "512", "--iter-time", "2000", "-"]
        argv = format_command(command, Path(sys.argv[3]) if len(sys.argv) == 4 else None)
        pretouch_for_format(argv)
        os.execvp("cryptsetup", argv)
    else:
        raise SystemExit("usage: omarchy-luks-calibrate calibrate | volume-key | format DEVICE [VOLUME-KEY]")


if __name__ == "__main__":
    main()
