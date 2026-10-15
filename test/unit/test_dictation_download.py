"""A corrupt model download is never promoted to the bundled model."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class DictationDownloadTest(unittest.TestCase):
    def test_bad_checksum_stops_before_model_is_installed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / 'curl'
            curl.write_text('#!/bin/sh\nfor last; do :; done\nprintf corrupt > "$last"\n')
            curl.chmod(0o755)
            assets = root / 'assets'
            result = subprocess.run(['bash', str(ROOT / 'builder/download-dictation.sh'), str(assets)],
                                    env=dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}'),
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('FAILED', result.stdout)
            self.assertFalse((assets / 'ggml-small.bin').exists())
