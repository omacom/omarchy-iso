"""Describe a SquashFS live layer over the installed Btrfs image."""

import filecmp
import os
import stat
import sys
from collections import defaultdict


def identical(live, base, a, b):
    if (a.st_mode, a.st_uid, a.st_gid, int(a.st_mtime), a.st_size, a.st_nlink) != (
        b.st_mode, b.st_uid, b.st_gid, int(b.st_mtime), b.st_size, b.st_nlink
    ):
        return False
    if not (stat.S_ISREG(a.st_mode) or stat.S_ISLNK(a.st_mode)):
        return False
    attrs = set(os.listxattr(live, follow_symlinks=False))
    if attrs != set(os.listxattr(base, follow_symlinks=False)) or any(
        os.getxattr(live, key, follow_symlinks=False) != os.getxattr(base, key, follow_symlinks=False)
        for key in attrs
    ):
        return False
    if stat.S_ISLNK(a.st_mode):
        return os.readlink(live) == os.readlink(base)
    return filecmp.cmp(live, base, shallow=False)


def pseudo_path(path):
    return '"' + path.replace('\\', '\\\\').replace('"', '\\"') + '"'


def describe_layer(live_root, base_root, exclude, whiteouts):
    hardlinks = defaultdict(list)
    shared = hidden = 0
    epoch = os.environ.get("SOURCE_DATE_EPOCH")
    latest_mtime = int(epoch) if epoch is not None else None
    stack = [""]
    while stack:
        directory = stack.pop()
        live_dir = os.path.join(live_root, directory)
        base_dir = os.path.join(base_root, directory)
        live_names = set(os.listdir(live_dir))
        with os.scandir(base_dir) as entries:
            base = {entry.name: entry for entry in entries}
        # The SquashFS lists are line-oriented. Keep this directory complete
        # if one of its names cannot be represented in them.
        if any("\n" in name or "\r" in name for name in live_names | base.keys()):
            print(pseudo_path(directory or "/"), "x trusted.overlay.opaque=y", file=whiteouts)
            continue
        for name in sorted(base):
            relative = os.path.join(directory, name)
            if name not in live_names:
                # OverlayFS recognises a 0:0 character device as a whiteout.
                # Hide installed-only files, including units and device rules.
                print(pseudo_path(relative), "c 0000 0 0 0 0", file=whiteouts)
                hidden += 1
                continue
            live = os.path.join(live_dir, name)
            a = os.lstat(live)
            b = base[name].stat(follow_symlinks=False)
            if stat.S_ISDIR(a.st_mode) and stat.S_ISDIR(b.st_mode):
                stack.append(relative)
                continue
            if relative != relative.strip() or relative.startswith(("#", "\\")) or relative.endswith("\\"):
                continue
            # Let mksquashfs clamp newer timestamps in reproducible builds.
            if latest_mtime is not None and int(a.st_mtime) > latest_mtime:
                continue
            if not identical(live, base[name].path, a, b):
                continue
            if a.st_nlink == 1:
                print(relative, file=exclude)
                shared += 1
            else:
                hardlinks[a.st_dev, a.st_ino].append((relative, a.st_nlink, b.st_dev, b.st_ino))

    # mksquashfs's literal exclude list operates on inodes. Excluding just
    # one alias would also drop a live-only alias of the same file.
    for matches in hardlinks.values():
        first, links, dev, inode = matches[0]
        if len(matches) == links and all((other_dev, other_inode) == (dev, inode)
                                         for _, _, other_dev, other_inode in matches):
            print(first, file=exclude)
            shared += links
    print(f"Live layer uses {shared} files from the installed image and hides {hidden} installed-only entries.")


if __name__ == "__main__":
    live, base, excludes, masks = sys.argv[1:]
    with open(excludes, "w", errors="surrogateescape") as exclude, open(masks, "w", errors="surrogateescape") as whiteouts:
        describe_layer(live, base, exclude, whiteouts)
