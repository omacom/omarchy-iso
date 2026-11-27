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
mount -t squashfs -o ro "$sfs_loop" "$work/sfs"
img_loop=$(attach_ro_loop "$work/sfs/omarchy-root.img")
mount -t btrfs -o ro,subvol=omarchy-root "$img_loop" "$work/image"

python3 - "$airootfs" "$work/image" "$pseudo" <<'PY'
import filecmp, os, stat, sys

live, image, pseudo = sys.argv[1], sys.argv[2], sys.argv[3]
KEEP = ("etc", "var", "root", "boot", "usr/local", "usr/lib/systemd", "usr/lib/udev",
        "usr/share/dbus-1", "usr/share/polkit-1",
        "usr/lib/tmpfiles.d", "usr/lib/sysusers.d", "usr/lib/sysctl.d", "usr/lib/modprobe.d",
        "usr/lib/modules-load.d", "usr/lib/binfmt.d", "usr/lib/environment.d", "usr/share/factory")
WHITEOUT_TREES = ("usr/lib/firmware", "usr/share/fonts")

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
    return filecmp.cmp(a, b, shallow=False)

# Ensure every KEEP directory that exists in the image also exists in live so
# overlayfs marks it opaque instead of exposing the image's copy.
for rel in KEEP:
    live_dir = os.path.join(live, rel)
    image_dir = os.path.join(image, rel)
    if not os.path.lexists(live_dir) and os.path.isdir(image_dir):
        os.makedirs(live_dir, exist_ok=True)

removed = kept_bytes = removed_bytes = whiteouts = 0
pseudo_lines = []

def dedup_whiteout_tree(rel):
    global removed, kept_bytes, removed_bytes, whiteouts
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

    dir_stat = os.lstat(live_dir)
    live_entries = sorted(os.listdir(live_dir))
    live_set = set(live_entries)
    image_entries = sorted(os.listdir(image_dir))

    for name in image_entries:
        if name not in live_set:
            pseudo_lines.append(f"{pseudo_path(os.path.join(rel, name))} c 0000 0 0 0 0\n")
            whiteouts += 1

    unlinked = False
    for name in live_entries:
        child_rel = os.path.join(rel, name)
        a = os.path.join(live_dir, name)
        b = os.path.join(image_dir, name)
        if is_real_dir(a):
            dedup_whiteout_tree(child_rel)
        else:
            size = os.lstat(a).st_size
            if same(a, b):
                os.unlink(a)
                removed += 1
                removed_bytes += size
                unlinked = True
            else:
                kept_bytes += size

    # Preserving directory mtimes keeps prebuilt /var/cache/fontconfig caches
    # valid after unlinking deduplicated font files.
    if unlinked:
        os.utime(live_dir, ns=(dir_stat.st_atime_ns, dir_stat.st_mtime_ns))

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
        size = os.lstat(a).st_size
        if same(a, b):
            os.unlink(a)
            removed += 1
            removed_bytes += size
        else:
            kept_bytes += size

with open(pseudo, "w") as f:
    f.writelines(pseudo_lines)
# The hook boots this tree over the image only when it finds this mark.
with open(os.path.join(live, "etc", "omarchy-iso-live-over-image"), "w") as f:
    f.write("The live system is a layer over omarchy-root.sfs (builder/dedup-airootfs.sh).\n")
print(f"dedup-airootfs: {removed} files ({removed_bytes / 1048576:.0f} MiB) are the image's; "
      f"{kept_bytes / 1048576:.0f} MiB stay outside the kept directories; {whiteouts} whiteouts")
PY
