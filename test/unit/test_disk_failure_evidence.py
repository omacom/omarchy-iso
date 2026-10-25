"""The disk state the install log keeps when archinstall gives up on a disk.

A failed install reaches a maintainer as its support log, after the machine has
been rebooted out of the state that explains it. These lift the logging out of
the adapter without importing archinstall and run it against stand-in tools.
"""

import ast
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator.command import capture  # noqa: E402

source = ROOT / "configs/airootfs/usr/share/omarchy-iso/orchestrator/archinstall_adapter.py"
tree = ast.parse(source.read_text())
functions = [
    node for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name in {"_log_disk_state", "_log_one_disk_state"}
]

TOOLS = {
    # The kernel still lists vda1; vda2 is gone from its table.
    "lsblk": """case "$1" in
  -rnpo) printf '%s disk\\n%s1 part\\n' "$3" "$3" ;;
  *) printf 'NAME TYPE SIZE FSTYPE MOUNTPOINTS\\nvda disk 40G\\n' ;;
esac""",
    "wipefs": 'echo "DEVICE OFFSET TYPE"; echo "${2##*/} 0x1000 linux_raid_member"',
    "dmesg": 'echo "BTRFS error (device vda2): superblock checksum mismatch"',
}


class DiskFailureEvidenceTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        bin_dir = Path(tmp.name) / "bin"
        bin_dir.mkdir()
        # Stands in for /dev: vda2 is what archinstall leaves when it writes 1 KiB
        # to a partition path the kernel has already dropped.
        self.dev = Path(tmp.name) / "dev"
        self.dev.mkdir()
        (self.dev / "vda2").write_bytes(bytes(1024))
        for name, body in TOOLS.items():
            (bin_dir / name).write_text(f"#!/bin/sh\n{body}\n")
            (bin_dir / name).chmod(0o755)
        path = mock.patch.dict(os.environ, {"PATH": f"{bin_dir}:{os.environ['PATH']}"})
        path.start()
        self.addCleanup(path.stop)

        self.logged = []
        self.namespace = {"Path": Path, "capture": capture, "info": self.logged.append, "ArchConfig": object}
        exec(compile(ast.Module(body=functions, type_ignores=[]), str(source), "exec"), self.namespace)

    def arch_config(self, *disks):
        mods = [types.SimpleNamespace(device=types.SimpleNamespace(device_info=types.SimpleNamespace(path=Path(d)))) for d in disks]
        return types.SimpleNamespace(disk_config=types.SimpleNamespace(device_modifications=mods))

    def test_records_what_is_at_each_partition_path_and_what_the_kernel_said(self):
        disk = self.dev / "vda"
        self.namespace["_log_disk_state"](self.arch_config(disk))

        self.assertEqual(len(self.logged), 1, "one block, not a line per call")
        log = self.logged[0]
        self.assertIn(f"disk state after the failure on {disk}", log)
        self.assertIn(f"{disk}2: regular file", log, "a file in /dev that lsblk never lists")
        self.assertIn(f"$ stat -c %n: %F {disk}1", log)
        self.assertIn("vda1 0x1000 linux_raid_member", log)
        self.assertIn("$ ls /sys/class/block/vda1/holders", log)
        self.assertIn("BTRFS error (device vda2)", log)

    def test_a_failure_to_record_never_replaces_the_install_failure(self):
        broken = types.SimpleNamespace(disk_config=types.SimpleNamespace(device_modifications=[object()]))

        self.namespace["_log_disk_state"](broken)

        self.assertEqual(len(self.logged), 1)
        self.assertIn("could not record the disk state", self.logged[0])


if __name__ == "__main__":
    unittest.main()
