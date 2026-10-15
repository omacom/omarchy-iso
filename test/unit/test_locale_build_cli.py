"""Exercise the public build CLI without Docker or package-cache mutations."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class LocaleBuildCliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for directory in ('bin', 'builder', 'configs', 'locales'):
            shutil.copytree(ROOT / directory, self.root / directory)
        fake = self.root / 'fake-bin'
        fake.mkdir()
        tools = {
            'git': '#!/bin/sh\nexit 0\n',
            'docker': '''#!/bin/sh
if [ "$1" = version ]; then exit 0; fi
printf '%s\\n' "$@" > "$TEST_ROOT/docker-args"
mkdir -p "$TEST_ROOT/release"
touch "$TEST_ROOT/release/omarchy-test.iso"
''',
            'sudo': '#!/bin/sh\necho unexpected sudo >&2\nexit 99\n',
        }
        for name, content in tools.items():
            path = fake / name
            path.write_text(content)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{fake}:{os.environ["PATH"]}', TEST_ROOT=str(self.root))
        for key in ('OMARCHY_ISO_REF', 'OMARCHY_MIRROR', 'OMARCHY_LOCALE', 'OMARCHY_WITH_DICTATION'):
            self.env.pop(key, None)

    def run_cli(self, *args):
        return subprocess.run(['bash', 'bin/omarchy-iso-make', '--no-cache', '--keep-pkg-cache', '--no-boot-offer', *args],
                              cwd=self.root, env=self.env, text=True, capture_output=True)

    def test_locale_and_dictation_reach_container_with_distinct_filename(self):
        result = self.run_cli('--locale', 'ja', '--with-dictation')
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        args = (self.root / 'docker-args').read_text()
        self.assertIn('OMARCHY_LOCALE=ja\n', args)
        self.assertIn('OMARCHY_WITH_DICTATION=1\n', args)
        self.assertIn('/locales:ro', args)
        self.assertTrue((self.root / 'release/omarchy-test-quattro-ja-dictation.iso').exists())

    def test_default_build_keeps_original_filename(self):
        result = self.run_cli()
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertTrue((self.root / 'release/omarchy-test-quattro.iso').exists())

    def test_invalid_selection_stops_before_docker(self):
        for args in (('--locale',), ('--locale', '../ja'), ('--locale', 'unknown'), ('--with-dictation',)):
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / 'docker-args').exists())
