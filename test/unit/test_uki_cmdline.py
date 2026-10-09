"""The pre-built UKI gets this install's cmdline in place.

It has to boot without a boot loader handing it a cmdline: EFI/Linux/*.efi is
offered as directly bootable by rEFInd, systemd-boot and firmware entries, and
a free-space install booted that way hangs for 90 s on /dev/gpt-auto-root with
no passphrase prompt. The installer writes the real cmdline into the room the
image build reserved. Tested on a synthesised PE image: the embed is in place
(nothing moves, neighbours untouched), it refuses instead of corrupting, the
build reserves the room, and the embed runs before limine-entry-tool pins the
UKI's hash.
"""

import struct
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
from orchestrator.uki_cmdline import PLACEHOLDER, embed_cmdline  # noqa: E402

SECTION = 0x400  # where the synthesised image's .cmdline starts
ROOM = 1800
REAL = ("cryptdevice=UUID=8a7c:omarchy_root root=/dev/mapper/omarchy_root rw  quiet splash\n"
        "rd.luks.name=8a7c=omarchy_root")


def uki(cmdline: bytes) -> bytes:
    """A PE image with a .cmdline section followed by a .linux section."""
    pe = 0x80
    header = bytearray(SECTION)
    header[:2] = b"MZ"
    struct.pack_into("<I", header, 0x3C, pe)
    header[pe:pe + 4] = b"PE\0\0"
    struct.pack_into("<H", header, pe + 6, 2)        # two sections
    struct.pack_into("<H", header, pe + 20, 0xF0)    # optional header size
    table = pe + 24 + 0xF0
    raw = (len(cmdline) + 0x1FF) & ~0x1FF
    sections = [(b".cmdline", len(cmdline), raw, SECTION), (b".linux", 16, 0x200, SECTION + raw)]
    for i, (name, vsize, rsize, roff) in enumerate(sections):
        entry = table + 40 * i
        header[entry:entry + 8] = name.ljust(8, b"\0")
        struct.pack_into("<IIII", header, entry + 8, vsize, 0x1000 * (i + 1), rsize, roff)
    return bytes(header) + cmdline.ljust(raw, b"\0") + b"KERNEL-BYTES-16b".ljust(0x200, b"\0")


def with_room() -> bytes:
    generic = b"rw quiet splash " + PLACEHOLDER.encode()
    return uki(generic + b"0" * (ROOM - len(generic)))


class EmbedCmdlineTest(unittest.TestCase):
    def setUp(self):
        self.path = Path(self.enterContext(tempfile.TemporaryDirectory())) / "uki.efi"

    def test_the_cmdline_is_written_in_place(self):
        before = with_room()
        self.path.write_bytes(before)
        self.assertTrue(embed_cmdline(self.path, REAL))
        after = self.path.read_bytes()
        self.assertEqual(len(after), len(before), "sections after .cmdline moved")
        section = after[SECTION:SECTION + ROOM]
        self.assertEqual(section.decode().rstrip(" "), " ".join(REAL.split()))
        self.assertNotIn(PLACEHOLDER.encode(), section)
        self.assertEqual(after[:SECTION], before[:SECTION], "PE headers were rewritten")
        self.assertEqual(after[SECTION + ROOM:], before[SECTION + ROOM:], "bytes after .cmdline were touched")

    def test_an_oversized_cmdline_is_refused(self):
        before = with_room()
        self.path.write_bytes(before)
        self.assertFalse(embed_cmdline(self.path, "x" * (ROOM + 1)))
        self.assertEqual(self.path.read_bytes(), before)

    def test_a_uki_without_reserved_room_is_left_alone(self):
        before = uki(b"rw quiet splash")
        self.path.write_bytes(before)
        self.assertFalse(embed_cmdline(self.path, REAL))
        self.assertEqual(self.path.read_bytes(), before)

    def test_something_that_is_not_a_pe_image_is_refused(self):
        self.path.write_bytes(b"not a PE image" * 10)
        self.assertFalse(embed_cmdline(self.path, REAL))

    def test_the_image_build_reserves_the_room(self):
        build = (ROOT / "builder/build-root-image.sh").read_text()
        self.assertIn(PLACEHOLDER, build)
        self.assertIn("--cmdline /etc/kernel/cmdline.prebuilt-uki", build)


class EmbedBeforeTheHashTest(unittest.TestCase):
    """limine-entry-tool --add-uki records the UKI's BLAKE2B hash in the boot
    entry, so the cmdline has to be in the file by then."""

    CMDLINE = "root=UUID=dead-beef rw quiet"

    def test_the_uki_carries_the_cmdline_when_limine_hashes_it(self):
        target = Path(self.enterContext(tempfile.TemporaryDirectory()))
        for path, text in {
            "usr/bin/limine-update": "",
            "etc/default/limine": f'ESP_PATH="/boot"\nKERNEL_CMDLINE[default]+="{self.CMDLINE}"\n',
            "etc/snapper/configs/root": "",
            "boot/limine.conf": "/+Omarchy\n",
            "var/lib/omarchy-iso/prebuilt-uki.kernel": "linux-omarchy\n",
        }.items():
            (target / path).parent.mkdir(parents=True, exist_ok=True)
            (target / path).write_text(text)
        (target / "var/lib/omarchy-iso/prebuilt-uki.efi").write_bytes(with_room())
        esp_uki = target / "boot/EFI/Linux/omarchy_linux-omarchy.efi"

        hashed = []

        def run(cmd, **_kwargs):
            if "--add-uki" in cmd:
                hashed.append(esp_uki.read_bytes())
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")

        ctx = types.SimpleNamespace(target=target, user_configuration={"kernels": ["linux-omarchy"]})
        firmware = types.SimpleNamespace(has_uefi=lambda: True)
        with mock.patch.object(phases_impl.subprocess, "run", run), \
             mock.patch.object(phases_impl, "arch", firmware), \
             mock.patch.object(phases_impl, "info", lambda *_: None), \
             mock.patch.object(phases_impl, "_is_apple_t2_hardware", lambda: False):
            phases_impl.finalize_limine_boot(ctx)

        self.assertEqual(len(hashed), 1, "limine-entry-tool --add-uki did not run once")
        self.assertIn(self.CMDLINE.encode(), hashed[0][SECTION:SECTION + ROOM])


if __name__ == "__main__":
    unittest.main()
