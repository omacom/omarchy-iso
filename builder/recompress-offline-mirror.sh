#!/bin/bash
#
# Recompress low-level zstd packages in the staged shipped offline mirror
# using heavy-CI zstd settings (--ultra -22 --long=27, 128 MiB decode window)
# so the ISO ships fewer bytes and omarchy-mirror-verify.service hashes less
# data on every boot, without modifying the persistent pacman download cache.
#
# Usage: recompress-offline-mirror.sh <staged-mirror-dir>
#
# Only packages whose zstd frame window is under 32 MiB (e.g. default level 3
# with a 2 MiB window) are recompressed; packages already packed at Arch's
# 32-128 MiB window settings are left untouched, as is archlinuxarm-keyring
# whose upstream .sig is verified at install time on aarch64. When a package
# shrinks, its now-stale .sig is removed and offline.db.tar.gz is updated via
# repo-add so %CSIZE% and %SHA256SUM% match.
#
# Candidates run largest-first (LPT) in parallel within strict CPU and memory
# budgets (measured ~760 MiB RSS per active --ultra -22 --long=27 thread,
# capped to <=25% of usable RAM and <=12 GiB on <64 GiB hosts so 16-32 GiB CI
# runners never OOM alongside build-root-image.sh's tmpfs staging tree).
# Multi-threaded jobs use -B64M --zstd=overlapLog=8 so large archives like
# nvidia-utils scale across threads instead of stalling on zstd's default
# 512 MiB jobSize.
#
# Skipped under OMARCHY_FAST_COMPRESSION=1 so --fast builds stay quick.

set -euo pipefail

dir="${1:-}"
if [[ ! -d $dir ]]; then
  echo "Usage: recompress-offline-mirror.sh <staged-mirror-dir>" >&2
  exit 1
fi

if [[ ${OMARCHY_FAST_COMPRESSION:-} == 1 ]]; then
  echo "recompress-offline-mirror: skipped under OMARCHY_FAST_COMPRESSION=1"
  exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-recompress.XXXXXX")
trap 'rm -rf "$work"' EXIT

repacked_list="$work/repacked.nul"
stats_file="$work/stats.txt"

python3 - "$dir" "$work" "$repacked_list" "$stats_file" <<'PY'
from concurrent.futures import ThreadPoolExecutor
import os
import shutil
import struct
import subprocess
import sys
import threading

mirror_dir, work_dir, repacked_list_path, stats_path = sys.argv[1:5]

WINDOW_THRESHOLD = 32 * 1024 * 1024
ZSTD_MAGIC = b"\x28\xb5\x2f\xfd"
# Measured peak RSS for zstd --ultra -22 --long=27 -B64M --zstd=overlapLog=8 is
# ~730-760 MiB per active thread; 800 MiB/thread leaves safe headroom.
PER_THREAD_MEM_BYTES = 800 * 1024 * 1024
MAX_MEM_BUDGET_BYTES = 12 * 1024 * 1024 * 1024
HIGH_MEM_HOST_THRESHOLD_BYTES = 64 * 1024 * 1024 * 1024
HIGH_MEM_BUDGET_BYTES = 20 * 1024 * 1024 * 1024


def zstd_window_size(path):
    with open(path, "rb") as f:
        hdr = f.read(18)
    if len(hdr) < 6 or hdr[:4] != ZSTD_MAGIC:
        return None
    fhd = hdr[4]
    single_segment = (fhd >> 5) & 1
    fcs_flag = (fhd >> 6) & 3
    if not single_segment:
        wd = hdr[5]
        exponent = wd >> 3
        mantissa = wd & 7
        base = 1 << (10 + exponent)
        return base + (base // 8) * mantissa
    dict_id_flag = fhd & 3
    dict_id_len = (0, 1, 2, 4)[dict_id_flag]
    fcs_off = 5 + dict_id_len
    if fcs_flag == 0:
        return hdr[fcs_off] if len(hdr) > fcs_off else None
    if fcs_flag == 1:
        return (struct.unpack_from("<H", hdr, fcs_off)[0] + 256) if len(hdr) >= fcs_off + 2 else None
    if fcs_flag == 2:
        return struct.unpack_from("<I", hdr, fcs_off)[0] if len(hdr) >= fcs_off + 4 else None
    return struct.unpack_from("<Q", hdr, fcs_off)[0] if len(hdr) >= fcs_off + 8 else None


def read_usable_memory_bytes():
    mem_avail = None
    mem_total = None
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemAvailable:"):
                    mem_avail = int(line.split()[1]) * 1024
                elif line.startswith("MemTotal:"):
                    mem_total = int(line.split()[1]) * 1024
    except OSError:
        pass
    usable = mem_avail if mem_avail is not None else mem_total

    # Respect cgroup v2 memory.max (when finite, not "max") and cgroup v1 limit.
    cgroup_free = None
    try:
        with open("/sys/fs/cgroup/memory.max", "r", encoding="utf-8") as f:
            raw = f.read().strip()
        if raw and raw != "max":
            limit = int(raw)
            cur = 0
            try:
                with open("/sys/fs/cgroup/memory.current", "r", encoding="utf-8") as cf:
                    cur = int(cf.read().strip())
            except OSError:
                pass
            cgroup_free = max(0, limit - cur)
    except (OSError, ValueError):
        try:
            with open("/sys/fs/cgroup/memory/memory.limit_in_bytes", "r", encoding="utf-8") as f:
                limit = int(f.read().strip())
            if mem_total is None or limit < mem_total:
                cur = 0
                try:
                    with open("/sys/fs/cgroup/memory/memory.usage_in_bytes", "r", encoding="utf-8") as cf:
                        cur = int(cf.read().strip())
                except OSError:
                    pass
                cgroup_free = max(0, limit - cur)
        except (OSError, ValueError):
            pass

    if cgroup_free is not None:
        usable = cgroup_free if usable is None else min(usable, cgroup_free)
    return usable if usable is not None else (4 * 1024 * 1024 * 1024)


candidates = []
for name in sorted(os.listdir(mirror_dir)):
    if not name.endswith(".pkg.tar.zst"):
        continue
    if name.startswith("archlinuxarm-keyring-"):
        continue
    path = os.path.join(mirror_dir, name)
    if not os.path.isfile(path):
        continue
    win = zstd_window_size(path)
    if win is not None and win < WINDOW_THRESHOLD:
        candidates.append((os.path.getsize(path), name, path))

if not candidates:
    with open(repacked_list_path, "wb") as f:
        pass
    with open(stats_path, "w", encoding="utf-8") as f:
        f.write("0 0 0 0 0\n")
    sys.exit(0)

# LPT (largest-first) so huge packages start at t=0 across parallel workers.
candidates.sort(key=lambda item: (-item[0], item[1]))

ncpus = max(1, os.cpu_count() or 1)
usable_mem = read_usable_memory_bytes()
mem_cap = HIGH_MEM_BUDGET_BYTES if usable_mem >= HIGH_MEM_HOST_THRESHOLD_BYTES else MAX_MEM_BUDGET_BYTES
mem_budget = min(usable_mem // 4, mem_cap)
total_threads = min(ncpus, max(1, mem_budget // PER_THREAD_MEM_BYTES))
env_threads = os.environ.get("OMARCHY_RECOMPRESS_THREADS")
if env_threads:
    try:
        total_threads = max(1, min(total_threads, int(env_threads)))
    except ValueError:
        pass


def threads_for_package(orig_size):
    if total_threads <= 1:
        return 1
    if orig_size >= 256 * 1024 * 1024:
        return min(total_threads, 16, max(1, (total_threads * 2) // 3))
    if orig_size >= 64 * 1024 * 1024:
        return min(total_threads, 4, max(1, total_threads // 4))
    if orig_size >= 32 * 1024 * 1024:
        return min(total_threads, 2, max(1, total_threads // 6))
    return 1


token_cond = threading.Condition()
free_tokens = total_threads


def process_one(item):
    global free_tokens
    orig_size, name, pkg = item
    threads = threads_for_package(orig_size)
    if threads > 1:
        zstd_args = [
            "zstd", "-q", f"-T{threads}", "--ultra", "-22", "--long=27",
            "-B64M", "--zstd=overlapLog=8",
        ]
    else:
        zstd_args = ["zstd", "-q", "-T1", "--ultra", "-22", "--long=27"]

    tmp = os.path.join(work_dir, name)
    with token_cond:
        while free_tokens < threads:
            token_cond.wait()
        free_tokens -= threads
    try:
        # Decompress and recompress in a streaming pipeline so large packages
        # never materialize an uncompressed tarball on disk.
        dec = subprocess.Popen(["zstd", "-dc", pkg], stdout=subprocess.PIPE)
        try:
            comp = subprocess.Popen(zstd_args + ["-o", tmp], stdin=dec.stdout)
        except Exception:
            dec.stdout.close()
            dec.kill()
            dec.wait()
            raise
        dec.stdout.close()
        comp_rc = comp.wait()
        dec_rc = dec.wait()
        if comp_rc != 0 or dec_rc != 0:
            raise RuntimeError(
                f"recompress failed for {name}: dec_rc={dec_rc}, comp_rc={comp_rc}"
            )
    finally:
        with token_cond:
            free_tokens += threads
            token_cond.notify_all()

    new_size = os.path.getsize(tmp)
    if new_size < orig_size:
        # Replace directory entry atomically on the destination filesystem rather
        # than mutating in place so reflink or hardlink copies from the persistent
        # download cache stay untouched.
        staged = os.path.join(mirror_dir, f".omarchy-recompress.{os.getpid()}.{name}")
        try:
            shutil.move(tmp, staged)
            os.replace(staged, pkg)
        except Exception:
            try:
                os.unlink(staged)
            except OSError:
                pass
            raise
        sig = f"{pkg}.sig"
        if os.path.lexists(sig):
            os.unlink(sig)
        return (True, orig_size, new_size, name, pkg)

    try:
        os.unlink(tmp)
    except OSError:
        pass
    return (False, orig_size, new_size, name, pkg)


max_workers = min(len(candidates), total_threads)
with ThreadPoolExecutor(max_workers=max_workers) as pool:
    results = list(pool.map(process_one, candidates))

repacked = sorted((r[3], r[4]) for r in results if r[0])
before_bytes = sum(r[1] for r in results if r[0])
after_bytes = sum(r[2] for r in results if r[0])

with open(repacked_list_path, "wb") as f:
    for _, pkg_path in repacked:
        f.write(pkg_path.encode("utf-8") + b"\0")

with open(stats_path, "w", encoding="utf-8") as f:
    f.write(f"{len(candidates)} {len(repacked)} {before_bytes} {after_bytes} {total_threads}\n")
PY

read -r candidate_count repacked_count before_bytes after_bytes total_threads <"$stats_file"

if (( candidate_count == 0 )); then
  echo "recompress-offline-mirror: no small-window .pkg.tar.zst candidates in $dir"
  exit 0
fi

if (( repacked_count == 0 )); then
  echo "recompress-offline-mirror: $candidate_count candidates checked, none shrank"
  exit 0
fi

mapfile -d '' -t repacked <"$repacked_list"

if [[ -f "$dir/offline.db.tar.gz" ]]; then
  repo-add -q "$dir/offline.db.tar.gz" "${repacked[@]}" >/dev/null
  rm -f "$dir"/offline.db*.old "$dir"/offline.files*.old
fi

saved_bytes=$((before_bytes - after_bytes))
echo "recompress-offline-mirror: repacked $repacked_count of $candidate_count packages (${total_threads}t budget): $((before_bytes >> 20)) MiB -> $((after_bytes >> 20)) MiB (-$((saved_bytes >> 20)) MiB)"
