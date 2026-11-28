#!/usr/bin/env python3
"""Parallel single-pass tar extraction helpers for Snapdragon firmware staging."""

from concurrent.futures import ThreadPoolExecutor
import os
import re
import shutil
import subprocess
import sys
import tarfile

FIRMWARE_PREFIX = "usr/lib/firmware/"
PROVIDED_PREFIX = "usr/share/qcom-firmware-extract/provided.d/"
PROVIDED_PATTERN = re.compile(
    r"^usr/share/qcom-firmware-extract/provided\.d/[^/]+\.list$"
)


def _write_nofollow(dst, mode, write_fn):
    if os.path.lexists(dst):
        os.unlink(dst)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(dst, flags, mode & 0o777)
    with os.fdopen(fd, "wb") as out_f:
        write_fn(out_f)
    os.chmod(dst, mode & 0o777)


def _stream_tar(pkg, handler):
    proc = subprocess.Popen(
        ["bsdtar", "-cf", "-", f"@{pkg}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        try:
            with tarfile.open(fileobj=proc.stdout, mode="r|") as tf:
                for member in tf:
                    handler(tf, member)
            # tarfile stops at the two zero EOF blocks, before bsdtar flushes
            # the rest of its 10 KiB output block; drain so bsdtar never sees EPIPE.
            if proc.stdout:
                while proc.stdout.read(65536):
                    pass
        finally:
            if proc.stdout:
                proc.stdout.close()
    except BaseException:
        proc.kill()
        if proc.stderr:
            proc.stderr.close()
        proc.wait()
        raise

    stderr = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
    if proc.stderr:
        proc.stderr.close()
    rc = proc.wait()
    if rc != 0:
        raise RuntimeError(f"bsdtar failed on {pkg} (rc={rc}): {stderr.strip()}")


def extract_firmware(wanted_path, work_dir, out_dir, pkgs):
    wanted = set()
    with open(wanted_path, "r", encoding="utf-8") as f:
        for line in f:
            fw = line.strip()
            if not fw:
                continue
            wanted.add(FIRMWARE_PREFIX + fw)
            wanted.add(FIRMWARE_PREFIX + fw + ".xz")
            wanted.add(FIRMWARE_PREFIX + fw + ".zst")

    if not wanted or not pkgs:
        return

    def extract_one(item):
        idx, pkg = item
        pkg_dir = os.path.join(work_dir, f"pkg.{idx}")
        os.makedirs(pkg_dir, exist_ok=True)
        matched = False
        fallback_hardlinks = []

        def handle_member(tf, member):
            nonlocal matched
            name = member.name.lstrip("./")
            if name not in wanted:
                return
            rel = name[len(FIRMWARE_PREFIX):]
            dst = os.path.join(pkg_dir, rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if member.issym():
                raise RuntimeError(
                    f"stage-medium-firmware: firmware shipped as a symlink, "
                    f"which the medium cannot check: {rel}"
                )
            if member.islnk():
                target_name = member.linkname.lstrip("./")
                if target_name.startswith(FIRMWARE_PREFIX):
                    target_path = os.path.join(
                        pkg_dir, target_name[len(FIRMWARE_PREFIX):]
                    )
                    if os.path.isfile(target_path) and not os.path.islink(target_path):
                        with open(target_path, "rb") as src_f:
                            st = os.fstat(src_f.fileno())
                            _write_nofollow(
                                dst,
                                st.st_mode,
                                lambda out_f: shutil.copyfileobj(src_f, out_f, 262144),
                            )
                        matched = True
                        return
                # Hardlink points outside wanted; resolve via bsdtar below.
                fallback_hardlinks.append((member.name, member.linkname))
            elif member.isfile():
                src_f = tf.extractfile(member)
                if src_f is not None:
                    _write_nofollow(
                        dst,
                        member.mode,
                        lambda out_f: shutil.copyfileobj(src_f, out_f, 262144),
                    )
                    matched = True

        _stream_tar(pkg, handle_member)

        if fallback_hardlinks:
            target_names = sorted({target for _, target in fallback_hardlinks})
            hl_dir = os.path.join(work_dir, f"hl.{idx}")
            os.makedirs(hl_dir, exist_ok=True)
            subprocess.run(
                ["bsdtar", "-xf", pkg, "-C", hl_dir] + target_names, check=True
            )
            hl_real = os.path.realpath(hl_dir)
            for member_name, linkname in fallback_hardlinks:
                src_t = os.path.join(hl_dir, linkname.lstrip("./"))
                src_real = os.path.realpath(src_t)
                if os.path.islink(src_t) or not src_real.startswith(hl_real + os.sep):
                    raise RuntimeError(
                        f"stage-medium-firmware: firmware hardlink escapes package: {member_name}"
                    )
                rel = member_name.lstrip("./")[len(FIRMWARE_PREFIX):]
                dst = os.path.join(pkg_dir, rel)
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(src_t, "rb") as src_f:
                    st = os.fstat(src_f.fileno())
                    _write_nofollow(
                        dst,
                        st.st_mode,
                        lambda out_f: shutil.copyfileobj(src_f, out_f, 262144),
                    )
                matched = True
            shutil.rmtree(hl_dir, ignore_errors=True)

        return pkg_dir if matched else None

    workers = min(len(pkgs), max(1, os.cpu_count() or 1))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        pkg_dirs = list(pool.map(extract_one, enumerate(pkgs)))

    for pkg_dir in pkg_dirs:
        if pkg_dir is None:
            continue
        for dirpath, _, filenames in os.walk(pkg_dir):
            rel_dir = os.path.relpath(dirpath, pkg_dir)
            dst_dir = out_dir if rel_dir == "." else os.path.join(out_dir, rel_dir)
            os.makedirs(dst_dir, exist_ok=True)
            for fn in filenames:
                src_p = os.path.join(dirpath, fn)
                dst_p = os.path.join(dst_dir, fn)
                if os.path.lexists(dst_p):
                    os.unlink(dst_p)
                shutil.move(src_p, dst_p)


def extract_provided_lists(target_dir, pkgs):
    if not pkgs:
        return

    def scan_one(pkg):
        found = []

        def handle_member(tf, member):
            name = member.name.lstrip("./")
            if member.isfile() and PROVIDED_PATTERN.match(name):
                f = tf.extractfile(member)
                if f is not None:
                    found.append((name[len(PROVIDED_PREFIX):], f.read(), member.mode))

        _stream_tar(pkg, handle_member)
        return found

    workers = min(len(pkgs), max(1, os.cpu_count() or 1))
    with ThreadPoolExecutor(max_workers=workers) as pool:
        results = list(pool.map(scan_one, pkgs))

    dst_dir = os.path.join(target_dir, PROVIDED_PREFIX.rstrip("/"))
    for found in results:
        for rel, data, mode in found:
            os.makedirs(dst_dir, exist_ok=True)
            out = os.path.join(dst_dir, rel)
            _write_nofollow(out, mode, lambda out_f, buf=data: out_f.write(buf))


def main(argv):
    if len(argv) < 2:
        raise SystemExit(
            "usage: extract-firmware.py (firmware WANTED WORK OUT | provided-lists TARGET) PKG..."
        )
    mode = argv[1]
    if mode == "firmware":
        if len(argv) < 5:
            raise SystemExit(
                "usage: extract-firmware.py firmware WANTED WORK OUT PKG..."
            )
        extract_firmware(argv[2], argv[3], argv[4], argv[5:])
    elif mode == "provided-lists":
        if len(argv) < 3:
            raise SystemExit(
                "usage: extract-firmware.py provided-lists TARGET PKG..."
            )
        extract_provided_lists(argv[2], argv[3:])
    else:
        raise SystemExit(f"extract-firmware.py: unknown mode: {mode}")


if __name__ == "__main__":
    try:
        main(sys.argv)
    except (RuntimeError, tarfile.TarError) as exc:
        print(exc, file=sys.stderr)
        sys.exit(1)
