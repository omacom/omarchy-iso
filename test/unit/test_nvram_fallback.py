#!/usr/bin/python

"""Limine NVRAM-entry registration when the firmware's NVRAM is full.

The installer must not abort an otherwise-good install just because it cannot
add a Limine boot entry. The path it takes instead — reclaim a dangling entry,
retry, and if that still fails install the removable fallback — is the subject
of these tests. They drive the real _register_limine_efi_entry with a fake
efibootmgr that refuses every --create, so they exercise the reclaim + retry +
raise logic rather than a mocked result.
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

sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402


def _ldisk_efibootmgr() -> bytes:
    return (
        b"BootCurrent: 0003\n"
        b"Timeout: 0 seconds\n"
        b"BootOrder: 0003,0001,0002\n"
        # Dangling: this GPT partition UUID no longer exists on any device.
        b"Boot0001* Old Linux\tHD(1,GPT,00000000-0000-0000-0000-000000000000)/File(\\EFI\\grub\\grubx64.efi)\n"
        # Live: this UUID is still present, so it must never be touched.
        b"Boot0002* Removable\tHD(2,GPT,11111111-1111-1111-1111-111111111111)/File(\\EFI\\BOOT\\BOOTX64.EFI)\n"
        b"Boot0003* Windows Boot Manager\tHD(1,GPT,22222222-2222-2222-2222-222222222222)/File(\\EFI\\Microsoft\\Boot\\bootmgfw.efi)\n"
    )


class NvramFallbackTest(unittest.TestCase):
    def setUp(self):
        self.bin_dir = None
        self.created_count = 0

    def fake_bin(self) -> Path:
        if self.bin_dir is None:
            tmp = tempfile.TemporaryDirectory()
            self.addCleanup(tmp.cleanup)
            self.bin_dir = Path(tmp.name)
            path = os.environ["PATH"]
            self.addCleanup(os.environ.__setitem__, "PATH", path)
            os.environ["PATH"] = f"{self.bin_dir}:{path}"
        return self.bin_dir

    def fake_script(self, name, body):
        script = self.fake_bin() / name
        script.write_text(f"#!/bin/sh\n{body}\n")
        script.chmod(0o755)

    def fake_efibootmgr(self, *, create_returns=0):
        out = self.fake_bin() / "efibootmgr.payload"
        out.write_bytes(_ldisk_efibootmgr())
        self.fake_script(
            "efibootmgr",
            'if [ "${1:-}" = "--create" ]; then\n'
            '  echo "could not create boot entry: No space left on device" >&2\n'
            f'  exit {create_returns}\n'
            "fi\n"
            f'cat "{out}"\n',
        )

    def test_partition_uuid_is_parsed_from_hd_path(self):
        self.assertEqual(
            phases_impl._entry_partition_uuid(
                "Old Linux\tHD(1,GPT,00000000-0000-0000-0000-000000000000)/File(\\x)"),
            "00000000-0000-0000-0000-000000000000",
        )
        # Paths without an HD() node (e.g. legacy BBS entries) are untouchable.
        self.assertIsNone(phases_impl._entry_partition_uuid("Removable\tRC"))

    def test_dangling_entries_are_reclaimed_but_live_ones_survive(self):
        self.fake_efibootmgr()
        self.fake_script(
            "lsblk",
            'echo "11111111-1111-1111-1111-111111111111"\n'
            'echo "22222222-2222-2222-2222-222222222222"\n',
        )
        deleted = []

        real_run = subprocess_run = __import__("subprocess").run

        def fake_run(cmd, *a, **k):
            if cmd[:1] == ["efibootmgr"] and "--delete-bootnum" in cmd:
                deleted.append(cmd[cmd.index("--bootnum") + 1])
                return types.SimpleNamespace(returncode=0)
            return real_run(cmd, *a, **k)

        with mock.patch("orchestrator.phases_impl.subprocess.run", side_effect=fake_run):
            pre = phases_impl._read_efibootmgr()
            removed = phases_impl._purge_dangling_boot_entries(pre)

        # Only the dangling "Old Linux" (UUID 0000..) is removed; the live
        # Windows and Removable entries are left alone.
        self.assertEqual(removed, 1)
        self.assertEqual(deleted, ["0001"])

    def test_create_failure_after_reclaim_raises_nvram_error(self):
        self.fake_efibootmgr(create_returns=1)
        # No live partition carries the dangling UUID, so reclaim is allowed;
        # lsblk lists only the live ones.
        self.fake_script(
            "lsblk",
            'echo "11111111-1111-1111-1111-111111111111"\n'
            'echo "22222222-2222-2222-2222-222222222222"\n',
        )
        with mock.patch("orchestrator.phases_impl.subprocess.run", wraps=__import__("subprocess").run):
            with self.assertRaises(phases_impl._NvramWriteError) as raised:
                phases_impl._register_limine_efi_entry(Path("/dev/sda"), 1, "\\EFI\\limine\\BOOTX64.EFI")
        # The reason efibootmgr gave must survive to the log (issue #127: the
        # refusal reason was previously discarded by a bare CalledProcessError).
        self.assertIn("No space left on device", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
