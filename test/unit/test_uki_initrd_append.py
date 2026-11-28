"""Unit tests for appending small machine firmware CPIO archives to a UKI .initrd."""

import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def _make_fake_uki(
    initrd_payload: bytes = b"base-initrd-bytes",
    *,
    section_align: int = 0x1000,
    file_align: int = 0x200,
    signed: bool = False,
    trailing_section: bool = True,
) -> bytes:
    """Construct a minimal valid unsigned (or signed) PE32+ image with .linux and .initrd."""
    pe_off = 0x80
    opt_size = 240  # standard PE32+ OptionalHeader with 16 data directories
    sections_meta = [
        (b".linux\x00\x00", b"FAKEKERNEL" * 64),
        (b".initrd\x00", initrd_payload),
    ]
    if not trailing_section:
        sections_meta.append((b".extra\x00\x00", b"AFTER"))

    num_sections = len(sections_meta)
    headers_end = pe_off + 24 + opt_size + num_sections * 40
    first_raw = (headers_end + file_align - 1) & ~(file_align - 1)
    first_va = (headers_end + section_align - 1) & ~(section_align - 1)

    sec_headers = bytearray()
    sec_bodies = bytearray()
    cur_raw = first_raw
    cur_va = first_va
    for name, body in sections_meta:
        vsize = len(body)
        rsize = (vsize + file_align - 1) & ~(file_align - 1)
        if rsize == 0:
            rsize = file_align
        sec_headers.extend(
            name
            + struct.pack("<IIIIIIHHI", vsize, cur_va, rsize, cur_raw, 0, 0, 0, 0, 0x40000040)
        )
        sec_bodies.extend(body.ljust(rsize, b"\x00"))
        cur_raw += rsize
        cur_va += (max(vsize, rsize) + section_align - 1) & ~(section_align - 1)

    size_of_image = cur_va
    dos = bytearray(pe_off)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, pe_off)

    coff = b"PE\x00\x00" + struct.pack("<HHIIIHH", 0xAA64, num_sections, 0, 0, 0, opt_size, 0x2022)
    opt = bytearray(opt_size)
    struct.pack_into("<H", opt, 0, 0x20B)  # PE32+
    struct.pack_into("<II", opt, 32, section_align, file_align)
    struct.pack_into("<I", opt, 56, size_of_image)
    struct.pack_into("<I", opt, 60, first_raw)
    struct.pack_into("<I", opt, 64, 0x12345678)  # non-zero checksum to confirm clearing
    struct.pack_into("<I", opt, 108, 16)  # NumberOfRvaAndSizes
    if signed:
        struct.pack_into("<II", opt, 112 + 4 * 8, cur_raw, 256)

    blob = bytearray(dos + coff + opt + sec_headers)
    blob.extend(b"\x00" * (first_raw - len(blob)))
    blob.extend(sec_bodies)
    if signed:
        blob.extend(b"\xAA" * 256)
    return bytes(blob)


def _parse_newc_entries(buf: bytes) -> list[tuple[str, int, bytes]]:
    pos = 0
    out = []
    while pos < len(buf):
        while pos < len(buf) and buf[pos] == 0:
            pos += 1
        if pos >= len(buf):
            break
        assert buf[pos:pos + 6] == b"070701", f"bad magic at {pos}: {buf[pos:pos + 6]!r}"
        mode = int(buf[pos + 14:pos + 22], 16)
        filesize = int(buf[pos + 54:pos + 62], 16)
        namesize = int(buf[pos + 94:pos + 102], 16)
        name_start = pos + 110
        name = buf[name_start:name_start + namesize - 1].decode("utf-8")
        data_start = (name_start + namesize + 3) & ~3
        data = buf[data_start:data_start + filesize]
        pos = (data_start + filesize + 3) & ~3
        out.append((name, mode, data))
        if name == "TRAILER!!!":
            break
    return out


class UkiInitrdAppendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        orchestrator_root = str(ROOT / "configs/airootfs/usr/share/omarchy-iso")
        cls._added = orchestrator_root not in sys.path
        if cls._added:
            sys.path.insert(0, orchestrator_root)
            cls.addClassCleanup(lambda: sys.path.remove(orchestrator_root) if orchestrator_root in sys.path else None)
        from orchestrator import uki_initrd_append
        cls.mod = uki_initrd_append

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_appends_cpio_and_updates_pe_headers(self):
        uki = Path(self.tmp.name) / "test.efi"
        base_initrd = b"BASE_INITRD_DATA_123"  # 20 bytes (not 4-aligned? 20 is; make it 21!)
        base_initrd = b"BASE_INITRD_DATA_1234"
        uki.write_bytes(_make_fake_uki(base_initrd))

        self.assertTrue(self.mod.can_append_initrd(uki))
        fw_bytes = b"\xfd7zXZ\x00FAKE_ZAP_SHADER_PAYLOAD"
        arc = "usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-14-ux3480qa/qcdxkmsucpurwa.mbn.xz"
        self.assertTrue(self.mod.append_files_to_initrd(uki, [(arc, fw_bytes)]))

        # Re-parse resulting PE headers
        blob = uki.read_bytes()
        info = self.mod._parse_trailing_initrd(blob[:65536], len(blob))
        self.assertIsNotNone(info)
        self.assertEqual(info["rptr"] + info["rsize"], len(blob))
        self.assertEqual(struct.unpack_from("<I", blob, info["opt_off"] + 64)[0], 0)
        expected_soi = (info["vaddr"] + info["vsize"] + info["section_align"] - 1) & ~(info["section_align"] - 1)
        self.assertEqual(struct.unpack_from("<I", blob, info["opt_off"] + 56)[0], expected_soi)

        initrd_slice = blob[info["rptr"]:info["rptr"] + info["vsize"]]
        self.assertTrue(initrd_slice.startswith(base_initrd))
        appended = initrd_slice[(len(base_initrd) + 3) & ~3:]
        entries = _parse_newc_entries(appended)
        names = [n for n, _, _ in entries]
        self.assertIn("usr", names)
        self.assertIn("usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-14-ux3480qa", names)
        self.assertIn(arc, names)
        self.assertEqual(names[-1], "TRAILER!!!")
        file_entry = next(e for e in entries if e[0] == arc)
        self.assertEqual(file_entry[1], 0o100644)
        self.assertEqual(file_entry[2], fw_bytes)

    def test_refuses_signed_or_non_trailing_uki(self):
        signed = Path(self.tmp.name) / "signed.efi"
        signed_bytes = _make_fake_uki(signed=True)
        signed.write_bytes(signed_bytes)
        self.assertFalse(self.mod.can_append_initrd(signed))
        self.assertFalse(self.mod.append_files_to_initrd(signed, [("usr/lib/firmware/a.bin", b"x")]))
        self.assertEqual(signed.read_bytes(), signed_bytes)

        non_trailing = Path(self.tmp.name) / "nontrail.efi"
        nt_bytes = _make_fake_uki(trailing_section=False)
        non_trailing.write_bytes(nt_bytes)
        self.assertFalse(self.mod.can_append_initrd(non_trailing))
        self.assertFalse(self.mod.append_files_to_initrd(non_trailing, [("usr/lib/firmware/a.bin", b"x")]))
        self.assertEqual(non_trailing.read_bytes(), nt_bytes)

    def test_refuses_path_traversal(self):
        uki = Path(self.tmp.name) / "trav.efi"
        orig = _make_fake_uki()
        uki.write_bytes(orig)
        self.assertFalse(self.mod.append_files_to_initrd(uki, [("../etc/evil", b"x")]))
        self.assertEqual(uki.read_bytes(), orig)


if __name__ == "__main__":
    unittest.main()
