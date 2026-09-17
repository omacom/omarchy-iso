import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def decode(data):
    def item(i):
        if data[i:i+1] == b'i':
            end = data.index(b'e', i)
            return int(data[i+1:end]), end+1
        if data[i:i+1] in (b'd', b'l'):
            dictionary = data[i:i+1] == b'd'
            values, i = [], i+1
            while data[i:i+1] != b'e':
                value, i = item(i)
                values.append(value)
            return (dict(zip(values[::2], values[1::2])) if dictionary else values), i+1
        end = data.index(b':', i)
        size = int(data[i:end])
        return data[end+1:end+1+size], end+1+size
    result, end = item(0)
    assert end == len(data)
    return result


class TorrentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='release tests ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.release = self.root / 'release'
        self.release.mkdir()
        self.log = self.root / 'log'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', TEST_LOG=str(self.log))
        for name in ('omarchy-iso-release', 'omarchy-iso-torrent'):
            shutil.copy2(ROOT / 'bin' / name, self.bin)
        # Isolate credentials without changing HOME or contacting R2.
        upload = (ROOT / 'bin/omarchy-iso-upload').read_text().replace(
            '~/.config/rclone/rclone.conf', '"' + str(self.root / 'rclone.conf') + '"')
        self.script('omarchy-iso-upload', upload, shebang=False)
        (self.root / 'rclone.conf').touch()
        self.script('rclone', 'echo "$2" >> "$TEST_LOG"\n[[ -z ${FAIL_COPY:-} || $2 != *"$FAIL_COPY" ]]')
        self.script('omarchy-iso-sign', 'printf signature > "$1.sig"')
        self.script('omarchy-iso-make', 'echo make >> "$TEST_LOG"')

    def script(self, name, body, shebang=True):
        path = self.bin / name
        path.write_text(('#!/bin/bash\n' if shebang else '') + body + '\n')
        path.chmod(0o755)

    def run_cmd(self, name, *args, ok=True, **env):
        result = subprocess.run([str(self.bin / name), *map(str, args)],
                                env=dict(self.env, **env), text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def iso(self, name='omarchy-9.9.9.iso'):
        path = self.release / name
        path.write_bytes(b'fixture bytes' * 200000)
        return path

    @unittest.skipUnless(shutil.which('mktorrent'), 'install mktorrent for real metadata tests')
    def test_metadata_and_regeneration(self):
        iso = self.iso()
        self.run_cmd('omarchy-iso-torrent', iso)
        torrent = Path(str(iso) + '.torrent')
        metadata = decode(torrent.read_bytes())
        info = metadata[b'info']
        self.assertEqual(info[b'name'], iso.name.encode())
        self.assertEqual(info[b'length'], iso.stat().st_size)
        self.assertEqual(info[b'piece length'], 2**21)
        self.assertNotIn(b'private', info)
        self.assertNotIn(b'announce', metadata)
        self.assertNotIn(b'announce-list', metadata)
        urls = metadata[b'url-list']
        if isinstance(urls, bytes):
            urls = [urls]
        self.assertIn(b'https://iso.omarchy.org/' + iso.name.encode(), urls)
        data = iso.read_bytes()
        pieces = b''.join(hashlib.sha1(data[i:i+2**21]).digest() for i in range(0, len(data), 2**21))
        self.assertEqual(info[b'pieces'], pieces)
        self.run_cmd('omarchy-iso-torrent', iso)
        self.assertEqual(decode(torrent.read_bytes())[b'info'], info)
        self.assertEqual(list(self.release.glob('*.torrent.*')), [])

    def test_invalid_inputs(self):
        self.run_cmd('omarchy-iso-torrent', ok=False)
        self.run_cmd('omarchy-iso-torrent', self.release / 'missing.iso', ok=False)
        empty = self.release / 'empty.iso'
        empty.touch()
        self.run_cmd('omarchy-iso-torrent', empty, ok=False)
        self.script('mktorrent', 'exit 0')
        self.run_cmd('omarchy-iso-torrent', self.iso('bad name.iso'), ok=False)

    def test_failed_generation_preserves_previous_torrent(self):
        iso = self.iso()
        torrent = Path(str(iso) + '.torrent')
        torrent.write_bytes(b'previous torrent')
        self.script('mktorrent', 'while [[ $# -gt 0 ]]; do\n if [[ $1 == -o ]]; then printf partial > "$2"; fi\n shift\ndone\nexit 1')
        self.run_cmd('omarchy-iso-torrent', iso, ok=False)
        self.assertEqual(torrent.read_bytes(), b'previous torrent')
        self.assertEqual(list(self.release.glob('*.torrent.*')), [])

    def test_release_failure_does_not_upload(self):
        self.iso('omarchy-date-x86_64-quattro.iso')
        self.script('mktorrent', 'exit 1')
        self.run_cmd('omarchy-iso-release', '--no-make', '9.9.9', ok=False)
        self.assertFalse(self.log.exists())

    def test_missing_generator_is_installed_before_build(self):
        (self.bin / 'realpath').symlink_to(shutil.which('realpath'))
        self.script('sudo', 'echo "sudo $*" >> "$TEST_LOG"\nexit 0')
        # Stop at make: this case tests dependency setup and its ordering.
        self.script('omarchy-iso-make', 'echo make >> "$TEST_LOG"\nexit 19')
        result = self.run_cmd('omarchy-iso-release', '9.9.9',
                              ok=False, PATH=str(self.bin))
        self.assertEqual(result.returncode, 19)
        self.assertEqual(self.log.read_text().splitlines(), [
            'sudo pacman -S --noconfirm --needed --quiet mktorrent', 'make'])

    def test_failed_dependency_install_stops_before_build(self):
        (self.bin / 'realpath').symlink_to(shutil.which('realpath'))
        self.script('sudo', 'echo "sudo $*" >> "$TEST_LOG"\nexit 23')
        result = self.run_cmd('omarchy-iso-release', '9.9.9',
                              ok=False, PATH=str(self.bin))
        self.assertEqual(result.returncode, 23)
        self.assertEqual(self.log.read_text().splitlines(), [
            'sudo pacman -S --noconfirm --needed --quiet mktorrent'])

    @unittest.skipUnless(shutil.which('mktorrent'), 'install mktorrent for release tests')
    def test_stable_and_rc_release(self):
        self.script('sudo', 'echo unexpected-sudo >> "$TEST_LOG"\nexit 1')
        for args, ref, name in [
            (['9.9.9'], 'quattro', 'omarchy-9.9.9.iso'),
            (['--rc', '9.9.9'], 'rc', 'omarchy-9.9.9-rc.iso'),
            (['--rc', '9.9.9rc2'], 'rc', 'omarchy-9.9.9rc2.iso'),
        ]:
            with self.subTest(name=name):
                self.iso(f'omarchy-date-x86_64-{ref}.iso')
                self.log.write_text('')
                result = self.run_cmd('omarchy-iso-release', '--no-make', *args)
                target = self.release / name
                self.assertEqual(self.log.read_text().splitlines(), [str(target) + suffix for suffix in ('', '.sig', '.sha256', '.torrent')])
                self.assertEqual(decode(Path(str(target) + '.torrent').read_bytes())[b'info'][b'name'], name.encode())
                self.assertIn(f'https://iso.omarchy.org/{name}.torrent', result.stdout)

    def test_upload_failure_and_missing_verification(self):
        iso = self.iso()
        for suffix in ('.sig', '.sha256', '.torrent'):
            Path(str(iso) + suffix).write_text('fixture')
        for suffix in ('.iso', '.sig', '.sha256', '.torrent'):
            with self.subTest(suffix=suffix):
                self.log.write_text('')
                self.run_cmd('omarchy-iso-upload', iso, ok=False, FAIL_COPY=suffix)
                calls = self.log.read_text().splitlines()
                if suffix != '.torrent':
                    self.assertNotIn(str(iso) + '.torrent', calls)
                else:
                    self.assertEqual(calls[-1], str(iso) + '.torrent')
        Path(str(iso) + '.sig').unlink()
        self.log.write_text('')
        self.run_cmd('omarchy-iso-upload', iso, ok=False)
        self.assertNotIn(str(iso) + '.torrent', self.log.read_text().splitlines())
