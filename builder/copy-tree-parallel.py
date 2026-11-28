#!/usr/bin/env python3
"""Copy a staged root filesystem tree into a mounted btrfs subvolume in parallel.

pacstrap extracts packages sequentially on one thread; into a btrfs mounted with
compress-force=zstd:15 that stalls on per-inode writeback using only ~2-3 CPUs
(~225 s on 16 cores). Staging uncompressed and copying files in parallel across
all CPUs (largest files first, triggering async writeback via sync_file_range)
saturates btrfs's zstd:15 workers across every CPU while preserving ownership,
mode (including setuid/setgid/sticky), xattrs/capabilities/ACLs, timestamps,
symlinks, special files and hardlinks.
"""

import ctypes
import errno
import os
import stat
import sys

CHUNK_SIZE = 1024 * 1024
SYNC_FILE_RANGE_WRITE = 2
# Flush every non-empty file asynchronously so btrfs compresses all files
# (including 1-2 KiB files) across thread_pool workers instead of accumulating
# uncommitted delalloc metadata reservations and stalling in handle_reserve_ticket.
SYNC_THRESHOLD = 1
FORK_MIN_FILES = 64

_libc = ctypes.CDLL(None, use_errno=True)
_sync_file_range = getattr(_libc, "sync_file_range", None)
if _sync_file_range is not None:
    _sync_file_range.argtypes = [ctypes.c_int, ctypes.c_longlong, ctypes.c_longlong, ctypes.c_uint]
    _sync_file_range.restype = ctypes.c_int


def _usable_cpus():
    try:
        ncpus = len(os.sched_getaffinity(0))
    except (AttributeError, OSError):
        ncpus = os.cpu_count() or 1
    try:
        with open("/sys/fs/cgroup/cpu.max", "r", encoding="utf-8") as f:
            parts = f.read().split()
        if len(parts) == 2 and parts[0] != "max":
            quota, period = int(parts[0]), int(parts[1])
            if quota > 0 and period > 0:
                ncpus = min(ncpus, max(1, quota // period))
    except (OSError, ValueError):
        try:
            with open("/sys/fs/cgroup/cpu/cpu.cfs_quota_us", "r", encoding="utf-8") as qf, \
                 open("/sys/fs/cgroup/cpu/cpu.cfs_period_us", "r", encoding="utf-8") as pf:
                quota = int(qf.read().strip())
                period = int(pf.read().strip())
            if quota > 0 and period > 0:
                ncpus = min(ncpus, max(1, quota // period))
        except (OSError, ValueError):
            pass
    return max(1, ncpus)


def _copy_xattrs(src, dst, *, follow_symlinks=True):
    kw = {} if isinstance(src, int) else {"follow_symlinks": follow_symlinks}
    try:
        names = os.listxattr(src, **kw)
    except OSError as exc:
        if exc.errno in (errno.ENOTSUP, errno.EOPNOTSUPP):
            return
        raise
    for name in names:
        if name.startswith("trusted.overlay."):
            continue
        val = os.getxattr(src, name, **kw)
        try:
            os.setxattr(dst, name, val, **kw)
        except OSError as exc:
            if exc.errno in (errno.ENOTSUP, errno.EOPNOTSUPP):
                continue
            raise


def _copy_regular_file(job, is_root=None):
    src, dst, st = job
    if is_root is None:
        is_root = os.geteuid() == 0
    sfd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        dfd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            written = 0
            flush_at = 0
            while True:
                buf = os.read(sfd, CHUNK_SIZE)
                if not buf:
                    break
                view = memoryview(buf)
                while view:
                    n = os.write(dfd, view)
                    view = view[n:]
                    written += n
                # Kick async btrfs zstd compression in 4 MiB slices on large
                # files so writeback starts immediately instead of waiting.
                if _sync_file_range is not None and written - flush_at >= 4 * CHUNK_SIZE:
                    _sync_file_range(dfd, flush_at, written - flush_at, SYNC_FILE_RANGE_WRITE)
                    flush_at = written

            if is_root:
                os.fchown(dfd, st.st_uid, st.st_gid)
            os.fchmod(dfd, stat.S_IMODE(st.st_mode))
            _copy_xattrs(sfd, dfd)
            os.utime(dfd, ns=(st.st_atime_ns, st.st_mtime_ns))
            if _sync_file_range is not None and written >= SYNC_THRESHOLD and written > flush_at:
                _sync_file_range(dfd, flush_at, written - flush_at, SYNC_FILE_RANGE_WRITE)
        finally:
            os.close(dfd)
    finally:
        os.close(sfd)


def _copy_regular_files_parallel(regulars, workers, is_root):
    if workers <= 1 or len(regulars) < FORK_MIN_FILES or not hasattr(os, "fork"):
        for job in regulars:
            _copy_regular_file(job, is_root)
        return

    nworkers = min(workers, len(regulars))
    sys.stdout.flush()
    sys.stderr.flush()
    pids = []
    for w in range(nworkers):
        pid = os.fork()
        if pid == 0:
            try:
                for job in regulars[w::nworkers]:
                    _copy_regular_file(job, is_root)
                os._exit(0)
            except BaseException as exc:
                try:
                    sys.stderr.write(f"copy-tree-parallel: worker {w} failed: {exc}\n")
                    sys.stderr.flush()
                except OSError:
                    pass
                os._exit(1)
        pids.append(pid)

    failed_status = None
    for pid in pids:
        _, status = os.waitpid(pid, 0)
        if status != 0 and failed_status is None:
            failed_status = status
    if failed_status is not None:
        raise RuntimeError(f"copy-tree-parallel: worker failed with wait status {failed_status}")


def copy_tree(src_root, dst_root, workers=None):
    src_root = os.path.abspath(src_root)
    dst_root = os.path.abspath(dst_root)
    is_root = os.geteuid() == 0
    os.makedirs(dst_root, exist_ok=True)

    dirs = []
    regulars = []
    hardlinks = []
    inodes = {}

    for dirpath, dirnames, filenames in os.walk(src_root, topdown=True, followlinks=False):
        rel_dir = os.path.relpath(dirpath, src_root)
        dst_dir = dst_root if rel_dir == "." else os.path.join(dst_root, rel_dir)
        dir_st = os.lstat(dirpath)
        if rel_dir != ".":
            os.mkdir(dst_dir, 0o700)
        dirs.append((dirpath, dst_dir, dir_st))

        # Symlinks to directories appear in dirnames when followlinks=False.
        real_dirs = []
        for d in dirnames:
            sp = os.path.join(dirpath, d)
            dp = os.path.join(dst_dir, d)
            st = os.lstat(sp)
            if stat.S_ISLNK(st.st_mode):
                os.symlink(os.readlink(sp), dp)
                if is_root:
                    os.lchown(dp, st.st_uid, st.st_gid)
                os.utime(dp, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)
            else:
                real_dirs.append(d)
        dirnames[:] = real_dirs

        for fn in filenames:
            sp = os.path.join(dirpath, fn)
            dp = os.path.join(dst_dir, fn)
            st = os.lstat(sp)
            mode = st.st_mode
            if stat.S_ISLNK(mode):
                os.symlink(os.readlink(sp), dp)
                if is_root:
                    os.lchown(dp, st.st_uid, st.st_gid)
                os.utime(dp, ns=(st.st_atime_ns, st.st_mtime_ns), follow_symlinks=False)
            elif stat.S_ISREG(mode):
                key = (st.st_dev, st.st_ino)
                if st.st_nlink > 1 and key in inodes:
                    hardlinks.append((inodes[key], dp))
                else:
                    if st.st_nlink > 1:
                        inodes[key] = dp
                    regulars.append((sp, dp, st))
            elif stat.S_ISFIFO(mode):
                os.mkfifo(dp, 0o600)
                if is_root:
                    os.lchown(dp, st.st_uid, st.st_gid)
                os.chmod(dp, stat.S_IMODE(mode))
                _copy_xattrs(sp, dp, follow_symlinks=False)
                os.utime(dp, ns=(st.st_atime_ns, st.st_mtime_ns))
            elif stat.S_ISCHR(mode) or stat.S_ISBLK(mode):
                os.mknod(dp, mode, st.st_rdev)
                if is_root:
                    os.lchown(dp, st.st_uid, st.st_gid)
                os.chmod(dp, stat.S_IMODE(mode))
                _copy_xattrs(sp, dp, follow_symlinks=False)
                os.utime(dp, ns=(st.st_atime_ns, st.st_mtime_ns))

    # Largest files first so huge binaries/fonts compress concurrently from t=0;
    # forked processes avoid Python GIL futex contention on small files.
    regulars.sort(key=lambda item: item[2].st_size, reverse=True)
    if workers is None:
        workers = _usable_cpus()
    _copy_regular_files_parallel(regulars, workers, is_root)

    for first_dst, extra_dst in hardlinks:
        os.link(first_dst, extra_dst)

    # Restore directory metadata bottom-up so child writes never clobber mtime.
    for sp, dp, st in reversed(dirs):
        if is_root:
            os.chown(dp, st.st_uid, st.st_gid)
        os.chmod(dp, stat.S_IMODE(st.st_mode))
        _copy_xattrs(sp, dp, follow_symlinks=False)
        os.utime(dp, ns=(st.st_atime_ns, st.st_mtime_ns))


def main():
    if len(sys.argv) not in (3, 4):
        print("Usage: copy-tree-parallel.py <src> <dst> [workers]", file=sys.stderr)
        sys.exit(2)
    workers = int(sys.argv[3]) if len(sys.argv) == 4 else None
    copy_tree(sys.argv[1], sys.argv[2], workers)


if __name__ == "__main__":
    main()
