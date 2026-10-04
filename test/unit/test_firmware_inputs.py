"""Pinned acquisition must reject corrupt caches and incomplete board payloads."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('hardware_firmware', ROOT / 'builder/hardware/hp-t14/fetch-firmware.py')
firmware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(firmware)


class FirmwareInputsTest(unittest.TestCase):
    def test_verified_cache_never_downloads(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            (cache / 'vendor.bin').write_bytes(b'known firmware')
            source = {'filename': 'vendor.bin', 'sha256': hashlib.sha256(b'known firmware').hexdigest()}
            with patch.object(firmware, 'run') as run:
                self.assertEqual(firmware.fetch(source, cache), cache / 'vendor.bin')
                run.assert_not_called()

    def test_corrupt_cache_is_not_reused_or_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache = Path(tmp)
            (cache / 'vendor.bin').write_bytes(b'corrupt')
            source = {'filename': 'vendor.bin', 'sha256': '0' * 64}
            with patch.object(firmware, 'run') as run, self.assertRaisesRegex(ValueError, 'Cached input hash mismatch'):
                firmware.fetch(source, cache)
            run.assert_not_called()
            self.assertEqual((cache / 'vendor.bin').read_bytes(), b'corrupt')

    def test_missing_payload_fails_before_package_creation(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, 'Firmware mismatch'):
                firmware.verify_payload(Path(tmp))

    def test_payload_hash_and_unexpected_files_are_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'inputs').mkdir()
            sha = hashlib.sha256(b'firmware').hexdigest()
            for board in ('hp', 't14s'):
                (root / board).mkdir()
                (root / board / 'test.bin').write_bytes(b'firmware')
                (root / 'inputs' / f'{board}-files.sha256').write_text(f'{sha}  {firmware.PREFIX}test.bin\n')
            with patch.object(firmware, 'HERE', root):
                firmware.verify_payload(root)
                (root / 'hp/extra.bin').write_bytes(b'extra')
                with self.assertRaisesRegex(ValueError, 'Unexpected firmware inventory'):
                    firmware.verify_payload(root)
                (root / 'hp/extra.bin').unlink()
                (root / 'hp/test.bin').write_bytes(b'corrupt')
                with self.assertRaisesRegex(ValueError, 'Firmware mismatch'):
                    firmware.verify_payload(root)
