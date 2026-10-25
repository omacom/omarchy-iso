"""The VM scenario must accept deliberate skips without hiding failed jobs."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('calibration_guest', ROOT / 'test/luks-calibration-guest.py')
guest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guest)
DONE = dict(LoadState='loaded', ActiveState='inactive', Result='success', ExecMainCode='1', ExecMainStatus='0')
PENDING = {**DONE, 'ExecMainCode': '0'}
RUNNING = {**PENDING, 'ActiveState': 'active'}


def shown(status):
    return types.SimpleNamespace(stdout='\n'.join(f'{key}={value}' for key, value in status.items())), 0


class ServiceCompletion(unittest.TestCase):
    def test_waits_through_queued_and_running_states(self):
        with mock.patch.object(guest, 'command', side_effect=[shown(PENDING), shown(RUNNING), shown(DONE)]), mock.patch.object(guest.time, 'sleep') as sleep:
            self.assertEqual(guest.wait_for_calibration('calibration.service'), DONE)
            self.assertEqual(sleep.call_count, 2)

    def test_success_does_not_require_a_cache_file(self):
        with mock.patch.object(guest, 'command', return_value=shown(DONE)):
            self.assertEqual(guest.wait_for_calibration('calibration.service'), DONE)

    def test_failed_killed_missing_and_invalid_service_results_fail(self):
        for status in (
            {**DONE, 'ActiveState': 'failed', 'Result': 'exit-code', 'ExecMainStatus': '1'},
            {**DONE, 'Result': 'signal', 'ExecMainCode': '2', 'ExecMainStatus': '15'},
            {**DONE, 'ExecMainStatus': '1'},
            {**DONE, 'LoadState': 'not-found'},
            {},
        ):
            with self.subTest(status=status), mock.patch.object(guest, 'command', return_value=shown(status)):
                with self.assertRaises(AssertionError):
                    guest.wait_for_calibration('calibration.service')

    def test_unstarted_or_hung_service_times_out(self):
        for status in (PENDING, RUNNING):
            with self.subTest(status=status), mock.patch.object(guest, 'command', return_value=shown(status)):
                with self.assertRaises(TimeoutError):
                    guest.wait_for_calibration('calibration.service', timeout=0)

    def test_systemctl_error_is_not_a_skip(self):
        with mock.patch.object(guest, 'command', side_effect=subprocess.CalledProcessError(1, 'systemctl')):
            with self.assertRaises(subprocess.CalledProcessError):
                guest.wait_for_calibration('calibration.service')


class FormatCoverage(unittest.TestCase):
    def setUp(self):
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.state = self.directory / 'result.json'
        self.cost = dict(iterations=13, memory=1048576, parallel=4)
        self.calibration = types.SimpleNamespace(STATE=self.state, MIN_MEMORY=65536, MAX_MEMORY=1048576,
                                                cached_options=lambda *_: ['costs'] if self.state.exists() else [])
        self.report = {'runs': []}
        self.calls = []
        calls, state = self.calls, self.state
        class Luks2:
            def __init__(self, image): self.image = image
            def encrypt(self, *, iter_time, key_file):
                calls.append(('archinstall', state.read_bytes() if state.exists() else None))
                return key_file
        self.Luks2 = Luks2
        self.enterContext(mock.patch.object(guest, 'command', side_effect=self.command))

    def command(self, argv, **kwargs):
        mode = Path(argv[-1]).stem
        self.calls.append((argv[1], mode))
        if argv[1] == 'format':
            forced = mode == 'cached'
            return types.SimpleNamespace(stderr=b'Using this boot' if forced else b''), 2 if forced else 8
        if argv[1] == 'luksDump':
            # In the skipped case each normal format may choose a different
            # memory cap. There is no cached policy to compare it against.
            memory = 1048576 if self.has_cache else {'absent': 96082, 'malformed': 131072, 'archinstall': 262144}[mode]
            kdf = dict(type='argon2id', time=13, memory=memory, cpus=4, salt=mode)
            return types.SimpleNamespace(stdout=json.dumps({'keyslots': {'0': {'key_size': 64, 'kdf': kdf}}})), 0
        self.assertEqual(argv[1], 'open')
        return types.SimpleNamespace(), 2

    def test_deliberate_skip_formats_and_unlocks_with_both_callers(self):
        self.has_cache = False
        guest.exercise_formats(self.calibration, self.Luks2, self.report)
        self.assertEqual(self.report['cache_status'], 'skipped')
        self.assertIsNone(self.report['calibration'])
        self.assertEqual([r['mode'] for r in self.report['runs']], ['absent', 'malformed', 'archinstall'])
        self.assertEqual(sum(call[0] == 'open' for call in self.calls), 9)
        self.assertIn(('archinstall', None), self.calls)
        self.assertNotIn('format_saved_seconds', self.report)
        self.assertFalse(self.state.exists())

    def test_cached_path_keeps_the_comparison_and_restores_original_state(self):
        self.has_cache = True
        saved = json.dumps(self.cost).encode()
        self.state.write_bytes(saved)
        guest.exercise_formats(self.calibration, self.Luks2, self.report)
        self.assertEqual(self.report['cache_status'], 'ready')
        self.assertEqual([r['mode'] for r in self.report['runs']], ['cached', 'absent', 'malformed', 'archinstall'])
        self.assertEqual(sum(call[0] == 'open' for call in self.calls), 12)
        self.assertEqual(self.report['format_saved_seconds'], 6)
        self.assertIn(('archinstall', saved), self.calls)
        self.assertEqual(self.state.read_bytes(), saved)

    def test_small_memory_expectation_still_rejects_an_unexpected_cache(self):
        self.has_cache = True
        self.state.write_text(json.dumps(self.cost))
        with self.assertRaisesRegex(AssertionError, 'unexpectedly cached'):
            guest.exercise_formats(self.calibration, self.Luks2, self.report, expect_no_cache=True)
        self.assertEqual(self.calls, [])

    def test_a_failed_fallback_unlock_fails_the_scenario(self):
        self.has_cache = False
        def failing(argv, **kwargs):
            if argv[1] == 'open':
                raise subprocess.CalledProcessError(2, argv)
            return self.command(argv, **kwargs)
        with mock.patch.object(guest, 'command', side_effect=failing):
            with self.assertRaises(subprocess.CalledProcessError):
                guest.exercise_formats(self.calibration, self.Luks2, self.report)
        self.assertFalse(self.state.exists())


if __name__ == '__main__':
    unittest.main()
