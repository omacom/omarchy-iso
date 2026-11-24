"""Unit tests for builder/copy-tree-parallel.py."""

import errno
import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("copy_tree_parallel", ROOT / "builder/copy-tree-parallel.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class CopyTreeParallelTest(unittest.TestCase):
    def test_preserves_files_hardlinks_symlinks_modes_timestamps_and_xattrs(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "src"
            dst = Path(tmp) / "dst"
            (src / "sub" / "ro_dir").mkdir(parents=True)
            (src / "dir_target").mkdir()

            # Regular files: empty, small, multi-chunk (> 4 MiB to exercise sync_file_range slices).
            (src / "empty").write_bytes(b"")
            (src / "small.txt").write_bytes(b"hello omarchy\n")
            big = src / "big.bin"
            big.write_bytes(b"A" * (5 * 1024 * 1024 + 123))

            # Hardlink pair across subdirectories.
            hl1 = src / "sub" / "hardlink_a"
            hl2 = src / "sub" / "ro_dir" / "hardlink_b"
            hl1.write_bytes(b"shared inode bytes")
            os.link(hl1, hl2)
            os.chmod(hl1, 0o640)

            # Read-only file inside a read-only directory.
            ro_file = src / "sub" / "ro_dir" / "readonly"
            ro_file.write_bytes(b"secret")
            os.chmod(ro_file, 0o400)

            # Symlinks (file, directory, dangling).
            os.symlink("small.txt", src / "link_to_file")
            os.symlink("dir_target", src / "link_to_dir")
            os.symlink("nonexistent", src / "dangling")

            # Custom mtime and optional user xattr.
            ts = (1700000000_000_000_000, 1700000123_456_000_000)
            os.utime(src / "small.txt", ns=ts)
            xattr_supported = True
            try:
                os.setxattr(src / "small.txt", "user.omarchy_test", b"ok")
            except OSError as exc:
                if exc.errno in (errno.ENOTSUP, errno.EOPNOTSUPP):
                    xattr_supported = False
                else:
                    raise

            # Make ro_dir read-only after populating it; restore in finally for cleanup.
            os.chmod(src / "sub" / "ro_dir", 0o555)
            try:
                MOD.copy_tree(src, dst, workers=4)

                self.assertEqual((dst / "empty").read_bytes(), b"")
                self.assertEqual((dst / "small.txt").read_bytes(), b"hello omarchy\n")
                self.assertEqual((dst / "big.bin").read_bytes(), big.read_bytes())
                self.assertEqual(os.stat(dst / "small.txt").st_mtime_ns, ts[1])
                if xattr_supported:
                    self.assertEqual(os.getxattr(dst / "small.txt", "user.omarchy_test"), b"ok")

                # Hardlink preserved as one inode with nlink == 2.
                st_a = os.lstat(dst / "sub" / "hardlink_a")
                st_b = os.lstat(dst / "sub" / "ro_dir" / "hardlink_b")
                self.assertEqual(st_a.st_ino, st_b.st_ino)
                self.assertEqual(st_a.st_nlink, 2)
                self.assertEqual(stat.S_IMODE(st_a.st_mode), 0o640)

                # Read-only dir and file modes preserved.
                self.assertEqual(stat.S_IMODE(os.lstat(dst / "sub" / "ro_dir").st_mode), 0o555)
                self.assertEqual(stat.S_IMODE(os.lstat(dst / "sub" / "ro_dir" / "readonly").st_mode), 0o400)

                # Symlinks preserved as symlinks (not dereferenced).
                self.assertEqual(os.readlink(dst / "link_to_file"), "small.txt")
                self.assertEqual(os.readlink(dst / "link_to_dir"), "dir_target")
                self.assertEqual(os.readlink(dst / "dangling"), "nonexistent")
            finally:
                os.chmod(src / "sub" / "ro_dir", 0o755)
                if (dst / "sub" / "ro_dir").exists():
                    os.chmod(dst / "sub" / "ro_dir", 0o755)


if __name__ == "__main__":
    unittest.main()
