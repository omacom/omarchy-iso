"""Source-only preparation must not build an ISO; builds use the standard launcher."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SnapdragonLauncherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'bin').mkdir()
        (self.root / 'builder').mkdir()
        shutil.copyfile(ROOT / 'bin/omarchy-iso-make-snapdragon', self.root / 'bin/launcher')
        (self.root / 'builder/prepare-snapdragon-sources.sh').write_text(
            '#!/bin/bash\nmkdir -p "$1/omarchy" "$1/omarchy-pkgs"\n')
        launcher = self.root / 'bin/omarchy-iso-make'
        launcher.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$CALL_LOG"\n')
        launcher.chmod(0o755)
        self.log = self.root / 'calls'

    def run_launcher(self, *args):
        return subprocess.run(['bash', str(self.root / 'bin/launcher'), *args],
                              env=dict(os.environ, CALL_LOG=str(self.log)),
                              capture_output=True, text=True, check=True)

    def test_prepare_only_does_not_invoke_iso_builder(self):
        self.run_launcher('--prepare-only')
        self.assertFalse(self.log.exists())
        self.assertEqual(len(list((self.root / 'build').glob('*/source/omarchy'))), 1)

    def test_clean_build_uses_existing_local_source_contract(self):
        self.run_launcher('--no-cache')
        args = self.log.read_text().splitlines()
        self.assertEqual(args[:4], ['--arch', 'aarch64', '--media-target', 'aarch64/snapdragon'])
        at = args.index('--local-source')
        self.assertTrue(Path(args[at + 1]).is_dir())
        self.assertTrue(Path(args[at + 2]).is_dir())
        self.assertIn('--no-boot-offer', args)
        self.assertEqual(args[-1], '--no-cache')
