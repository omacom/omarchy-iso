#!/usr/bin/python

"""Undecodable bytes in command output, and where tolerating them stops.

The orchestrator reads firmware and filesystem metadata out of commands whose
output is not required to be UTF-8: noise in a boot entry must not stop an
install, while a mangled identifier must stop one. These tests run stand-in
commands emitting the bytes two HP firmwares actually put in a legacy BBS entry,
so they exercise the decode itself rather than a mocked result.
"""

import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

# phases_impl imports the archinstall adapter at module scope, which pulls in
# the archinstall library that only exists on the live ISO.
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402
from orchestrator.command import capture, capture_identifier  # noqa: E402

# Boot0000 is the entry that aborted the install: raw bytes inside a BBS device
# path, in a legacy entry nothing in the installer reads. 0x80 and 0xe0 are the
# bytes two different HP firmwares emitted.
EFIBOOTMGR_OUTPUT = (
    b"BootCurrent: 0003\n"
    b"Timeout: 0 seconds\n"
    b"BootOrder: 2001,0003,0000\n"
    b"Boot0000* Notebook Hard Drive\tBBS(HD,\x80\x7f\xff\x04\xe0\x7f,)\n"
    b"Boot0003* Omarchy\tHD(1,GPT,0d9c9d4f)/File(\\EFI\\limine\\BOOTX64.EFI)\n"
    b"Boot2001* USB Drive (UEFI)\tRC\n"
)


class CommandCaptureTest(unittest.TestCase):
    def setUp(self):
        self.bin_dir = None

    def fake_bin(self) -> Path:
        """A directory at the front of PATH, made once per test."""
        if self.bin_dir is None:
            tmp = tempfile.TemporaryDirectory()
            self.addCleanup(tmp.cleanup)
            self.bin_dir = Path(tmp.name)
            path = os.environ["PATH"]
            self.addCleanup(os.environ.__setitem__, "PATH", path)
            os.environ["PATH"] = f"{self.bin_dir}:{path}"
        return self.bin_dir

    def fake_script(self, name: str, body: str) -> None:
        script = self.fake_bin() / name
        script.write_text(f"#!/bin/sh\n{body}\n")
        script.chmod(0o755)

    def fake_command(self, name: str, output: bytes) -> None:
        """A command printing exactly these bytes, undecodable ones included."""
        payload = self.fake_bin() / f"{name}.out"
        payload.write_bytes(output)
        self.fake_script(name, f'cat "{payload}"')

    def fake_findmnt(self, source: bytes) -> None:
        """A findmnt answering per column, so the phase gets as far as SOURCE."""
        payload = self.fake_bin() / "findmnt.source"
        payload.write_bytes(source)
        self.fake_script(
            "findmnt",
            'case "$2" in\n'
            "  FSTYPE) echo btrfs ;;\n"
            "  OPTIONS) echo rw,subvol=/@ ;;\n"
            f'  SOURCE) cat "{payload}" ;;\n'
            "esac",
        )

    def test_undecodable_bytes_are_replaced_rather_than_raised(self):
        self.fake_command("omarchy-not-utf8", b"before\x80after\n")
        self.assertEqual(capture(["omarchy-not-utf8"]).stdout, "before�after\n")

    def test_efibootmgr_entries_parse_around_a_legacy_bbs_entry(self):
        self.fake_command("efibootmgr", EFIBOOTMGR_OUTPUT)

        state = phases_impl._read_efibootmgr()

        self.assertEqual(state["order"], ["2001", "0003", "0000"])
        self.assertEqual(phases_impl._find_label_entries(state["entries"], "Omarchy"), ["0003"])
        self.assertTrue(state["entries"]["0000"].startswith("Notebook Hard Drive"))

    def test_a_mangled_identifier_stops_the_install_rather_than_reaching_fstab(self):
        # _validate_pre_mounted_filesystems reads the UUID back from this same
        # command, so a replaced byte would agree with itself all the way to a
        # machine that cannot find its root.
        self.fake_command("blkid", b"1a2b3c4d-\x80-dead-beef\n")

        with self.assertRaises(RuntimeError) as raised:
            phases_impl._blkid_uuid("/dev/sda2")

        self.assertIn("the UUID of /dev/sda2 is not valid text", str(raised.exception))

    def test_a_mangled_btrfs_device_is_never_handed_to_mount(self):
        # create_factory_snapshot mounts this device and deletes subvolumes
        # under it; a replaced byte must stop the phase before that, not turn
        # into an opaque mount failure.
        self.fake_findmnt(source=b"/dev/sda\xe02[/@]")
        ctx = types.SimpleNamespace(target=Path("/mnt"), state_dir=Path("/run/omarchy"))

        with mock.patch.object(phases_impl, "info"), self.assertRaises(RuntimeError) as raised:
            phases_impl.create_factory_snapshot(ctx)

        self.assertIn("is not valid text", str(raised.exception))

    def test_a_clean_identifier_is_returned_unchanged(self):
        self.fake_command("blkid", b"1a2b3c4d-0e5f-dead-beef\n")
        self.assertEqual(
            capture_identifier(["blkid"], "the UUID"), "1a2b3c4d-0e5f-dead-beef"
        )


if __name__ == "__main__":
    unittest.main()
