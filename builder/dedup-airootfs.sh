#!/bin/bash
#
# Make the live system a layer over the root image: delete from the live
# system's tree every file the image holds byte for byte, so the ISO stores it
# once. The omarchy_try hook mounts the live system as that layer over the
# image (configs/airootfs/etc/initcpio/hooks/omarchy_try).
#
# Usage: dedup-airootfs.sh <omarchy-root.sfs> <airootfs dir> <pseudo file>
#
# builder/mksquashfs-shim runs it when mkarchiso squashes the live tree, and
# hands the pseudo file it writes (the opaque marks) to mksquashfs. Most of
# the live system is the image's own packages at the image's own versions,
# from the same build: 1,664 of its 2,383 MiB on the 2026-10-26 edge ISO.
#
# Kept whole, and marked opaque so the image's copies stay out of the live
# system: what makes a file act just by being there. /etc (unit enablement,
# configuration), /var (the pacman database and the offline mirror), /root,
# /boot, /usr/local, systemd's and udev's directories and the snippet
# directories systemd reads at boot.
#
# /usr/lib/firmware and /usr/share/fonts are trimmed for the live installer
# (customize_airootfs.sh), with /var/cache/fontconfig prebuilt for that tree.
# Instead of marking those whole trees opaque (which duplicates ~194 MiB of
# kept firmware and fonts already in the root image), identical kept files are
# deduplicated while pruned image-only files/directories get overlayfs whiteout
# pseudo entries (c 0000 0 0 0 0), and directory mtimes are preserved so the
# prebuilt fontconfig caches remain valid. Everywhere else a file goes when the
# image has the same path with the same type, mode, owner, xattrs and bytes,
# or the same symlink.
#
# Needs root: mounts the image. The marks go in as mksquashfs pseudo
# definitions: overlayfs refuses trusted.overlay xattrs on the build
# container's own overlay, where the tree is.

set -euo pipefail

sfs="${1:-}"
airootfs="${2:-}"
pseudo="${3:-}"
if [[ ! -f $sfs || ! -d $airootfs || -z $pseudo ]]; then
  echo "Usage: dedup-airootfs.sh <omarchy-root.sfs> <airootfs dir> <pseudo file>" >&2
  exit 1
fi

# Docker fills the container's /dev once, at start. A loop device the kernel
# creates afterwards (such as the second loop dedup needs while the squashfs is
# mounted) exists on the host but has no node in here, so make the node before
# attaching it.
attach_ro_loop() {
  local backing="$1" dev
  [[ -e /dev/loop-control ]] || mknod /dev/loop-control c 10 237 || return 1
  # losetup reports a device whose node is missing as "/dev/loopN (lost)".
  dev=$(losetup --find | awk '{ print $1 }')
  [[ $dev == /dev/loop[0-9]* ]] || { echo "ERROR: no free loop device: $dev" >&2; return 1; }
  [[ -b $dev ]] || mknod "$dev" b 7 "${dev#/dev/loop}" || return 1
  losetup --read-only "$dev" "$backing" || return 1
  printf '%s\n' "$dev"
}

work=$(mktemp -d /tmp/omarchy-dedup.XXXXXX)
sfs_loop=""
img_loop=""
cleanup() {
  set +e
  mountpoint -q "$work/image" && umount "$work/image"
  [[ -n $img_loop ]] && losetup -d "$img_loop"
  mountpoint -q "$work/sfs" && umount "$work/sfs"
  [[ -n $sfs_loop ]] && losetup -d "$sfs_loop"
  rmdir "$work/image" "$work/sfs" "$work"
}
trap cleanup EXIT
mkdir -p "$work/sfs" "$work/image"
sfs_loop=$(attach_ro_loop "$sfs")
mount -t squashfs -o ro,threads=multi "$sfs_loop" "$work/sfs" 2>/dev/null || mount -t squashfs -o ro "$sfs_loop" "$work/sfs"
img_loop=$(attach_ro_loop "$work/sfs/omarchy-root.img")
btrfs_threads=$(nproc)
(( btrfs_threads > 64 )) && btrfs_threads=64
(( btrfs_threads < 1 )) && btrfs_threads=1
mount -t btrfs -o "ro,subvol=omarchy-root,thread_pool=$btrfs_threads" "$img_loop" "$work/image" 2>/dev/null ||
  mount -t btrfs -o ro,subvol=omarchy-root "$img_loop" "$work/image"

python3 - "$airootfs" "$work/image" "$pseudo" <<'PY'
import os, stat, struct, sys, tempfile

live, image, pseudo = sys.argv[1], sys.argv[2], sys.argv[3]
KEEP = ("etc", "var", "root", "boot", "usr/local", "usr/lib/systemd", "usr/lib/udev",
        "usr/share/dbus-1", "usr/share/polkit-1",
        "usr/lib/tmpfiles.d", "usr/lib/sysusers.d", "usr/lib/sysctl.d", "usr/lib/modprobe.d",
        "usr/lib/modules-load.d", "usr/lib/binfmt.d", "usr/lib/environment.d", "usr/share/factory")
WHITEOUT_TREES = ("usr/lib/firmware", "usr/share/fonts")
CMP_CHUNK = 262144
FORK_MIN_CANDIDATES = 64

def xattrs(path):
    return {k: os.getxattr(path, k, follow_symlinks=False) for k in os.listxattr(path, follow_symlinks=False)}

def pseudo_path(rel):
    p = "/" + rel
    if any(ch.isspace() or ch in '"\\' for ch in p):
        escaped = p.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return p

def is_real_dir(path):
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except FileNotFoundError:
        return False

def same(a, b):
    try:
        sa, sb = os.lstat(a), os.lstat(b)
    except FileNotFoundError:
        return False
    if (stat.S_IFMT(sa.st_mode), sa.st_mode, sa.st_uid, sa.st_gid) != (stat.S_IFMT(sb.st_mode), sb.st_mode, sb.st_uid, sb.st_gid):
        return False
    if stat.S_ISLNK(sa.st_mode):
        return os.readlink(a) == os.readlink(b)
    if not stat.S_ISREG(sa.st_mode) or sa.st_size != sb.st_size or xattrs(a) != xattrs(b):
        return False
    if sa.st_size == 0:
        return True
    with open(a, "rb", buffering=CMP_CHUNK) as fa, open(b, "rb", buffering=CMP_CHUNK) as fb:
        while True:
            ba = fa.read(CMP_CHUNK)
            bb = fb.read(CMP_CHUNK)
            if ba != bb:
                return False
            if not ba:
                return True

# Ensure every KEEP directory that exists in the image also exists in live so
# overlayfs marks it opaque instead of exposing the image's copy.
for rel in KEEP:
    live_dir = os.path.join(live, rel)
    image_dir = os.path.join(image, rel)
    if not os.path.lexists(live_dir) and os.path.isdir(image_dir):
        os.makedirs(live_dir, exist_ok=True)

removed = kept_bytes = removed_bytes = whiteouts = 0
pseudo_lines = []
candidates = []
whiteout_dir_stats = {}

def dedup_whiteout_tree(rel):
    global whiteouts
    live_dir = os.path.join(live, rel)
    image_dir = os.path.join(image, rel)
    if not os.path.lexists(live_dir):
        if is_real_dir(image_dir):
            os.makedirs(live_dir, exist_ok=True)
            pseudo_lines.append(f"{pseudo_path(rel)} x trusted.overlay.opaque=y\n")
        return
    if not is_real_dir(live_dir):
        return
    if not is_real_dir(image_dir):
        if os.path.lexists(image_dir):
            pseudo_lines.append(f"{pseudo_path(rel)} x trusted.overlay.opaque=y\n")
        return

    whiteout_dir_stats[live_dir] = os.lstat(live_dir)
    live_entries = sorted(os.listdir(live_dir))
    live_set = set(live_entries)
    image_entries = sorted(os.listdir(image_dir))

    for name in image_entries:
        if name not in live_set:
            pseudo_lines.append(f"{pseudo_path(os.path.join(rel, name))} c 0000 0 0 0 0\n")
            whiteouts += 1

    for name in live_entries:
        child_rel = os.path.join(rel, name)
        a = os.path.join(live_dir, name)
        b = os.path.join(image_dir, name)
        if is_real_dir(a):
            dedup_whiteout_tree(child_rel)
        else:
            candidates.append((a, b, os.lstat(a).st_size, live_dir))

for rel in WHITEOUT_TREES:
    dedup_whiteout_tree(rel)

skip_trees = set(KEEP) | set(WHITEOUT_TREES)
for top, dirs, files in os.walk(live):
    rel = os.path.relpath(top, live)
    if rel in skip_trees:
        if rel in KEEP:
            pseudo_lines.append(f"{pseudo_path(rel)} x trusted.overlay.opaque=y\n")
        dirs.clear()
        continue
    for name in files:
        a, b = os.path.join(top, name), os.path.join(image, rel, name)
        candidates.append((a, b, os.lstat(a).st_size, None))

try:
    ncpus = len(os.sched_getaffinity(0))
except (AttributeError, OSError):
    ncpus = os.cpu_count() or 1
workers = min(32, max(1, ncpus))

matched_indices = set()
if workers <= 1 or len(candidates) < FORK_MIN_CANDIDATES or not hasattr(os, "fork"):
    for idx, (a, b, _, _) in enumerate(candidates):
        if same(a, b):
            matched_indices.add(idx)
else:
    nworkers = min(workers, len(candidates))
    sys.stdout.flush()
    sys.stderr.flush()
    worker_files = []
    pids = []
    try:
        for w in range(nworkers):
            out_f = tempfile.TemporaryFile()
            worker_files.append(out_f)
            pid = os.fork()
            if pid == 0:
                try:
                    buf = bytearray()
                    for idx in range(w, len(candidates), nworkers):
                        a, b, _, _ = candidates[idx]
                        if same(a, b):
                            buf.extend(struct.pack("<I", idx))
                    if buf:
                        out_f.write(buf)
                        out_f.flush()
                    os._exit(0)
                except BaseException as exc:
                    try:
                        sys.stderr.write(f"dedup-airootfs: worker {w} failed: {exc}\n")
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
            raise RuntimeError(f"dedup-airootfs: worker failed with wait status {failed_status}")

        for out_f in worker_files:
            out_f.seek(0)
            raw = out_f.read()
            for (idx,) in struct.iter_unpack("<I", raw):
                matched_indices.add(idx)
    finally:
        for out_f in worker_files:
            out_f.close()

unlinked_dirs = set()
for idx, (a, _, size, whiteout_dir) in enumerate(candidates):
    if idx in matched_indices:
        os.unlink(a)
        removed += 1
        removed_bytes += size
        if whiteout_dir is not None:
            unlinked_dirs.add(whiteout_dir)
    else:
        kept_bytes += size

# Preserving directory mtimes keeps prebuilt /var/cache/fontconfig caches
# valid after unlinking deduplicated font files.
for live_dir in unlinked_dirs:
    dir_stat = whiteout_dir_stats[live_dir]
    os.utime(live_dir, ns=(dir_stat.st_atime_ns, dir_stat.st_mtime_ns))

with open(pseudo, "w") as f:
    f.writelines(pseudo_lines)
# The hook boots this tree over the image only when it finds this mark.
with open(os.path.join(live, "etc", "omarchy-iso-live-over-image"), "w") as f:
    f.write("The live system is a layer over omarchy-root.sfs (builder/dedup-airootfs.sh).\n")
print(f"dedup-airootfs: {removed} files ({removed_bytes / 1048576:.0f} MiB) are the image's; "
      f"{kept_bytes / 1048576:.0f} MiB stay outside the kept directories; {whiteouts} whiteouts")
PY
