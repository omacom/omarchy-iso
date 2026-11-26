"""Boot calibration is optional; invalid data must never force a weaker cost."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('luks_calibration', ROOT / 'configs/airootfs/usr/share/omarchy-iso/orchestrator/luks_calibration.py')
luks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(luks)
LINE = 'argon2id     13 iterations, 1048576 memory, 4 parallel threads (CPUs) for 512-bit key (requested 2000 ms time)'
COMMAND = ['cryptsetup', '--batch-mode', '--verbose', '--type', 'luks2', '--pbkdf', 'argon2id', '--hash', 'sha512', '--key-size', '512', '--iter-time', '2000', '--use-urandom', 'luksFormat', '/dev/vda2']


class Calibration(unittest.TestCase):
    def setUp(self):
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.path = self.directory / 'result.json'
        self.enterContext(mock.patch.object(luks, 'STATE', self.path))
        self.enterContext(mock.patch.object(luks, 'memory_total', return_value=8*1024*1024))
        self.enterContext(mock.patch.object(luks, 'memory_available', return_value=4*1024*1024))
        self.enterContext(mock.patch.object(luks.os, 'cpu_count', return_value=4))
        self.data = dict(schema=1, iter_time=2000, key_size=512, cpus=4,
                         iterations=13, memory=1048576, parallel=4)
        # The production reader requires root ownership; unit tests run as an
        # ordinary user. Preserve the actual mode/size/type checks.
        fstat = os.fstat
        def root_stat(fd):
            st = fstat(fd)
            return types.SimpleNamespace(st_uid=0, st_mode=st.st_mode, st_size=st.st_size)
        self.enterContext(mock.patch.object(luks.os, 'fstat', side_effect=root_stat))

    def write(self, data=None):
        self.path.write_text(json.dumps(self.data if data is None else data))
        self.path.chmod(0o600)

    def test_parser_uses_the_actual_argon2_line(self):
        self.assertEqual(luks.parse_benchmark('# informational header\n'+LINE+'\n'),
                         dict(iterations=13, memory=1048576, parallel=4))

    def test_parser_rejects_ambiguous_or_wrong_policy_output(self):
        for output in ('', LINE+'\n'+LINE, LINE.replace('argon2id','argon2i'),
                       LINE.replace('2000 ms','1000 ms'), LINE.replace('512-bit','256-bit'),
                       LINE.replace('13 iterations','3 iterations'),
                       LINE.replace('1048576 memory','0 memory'), LINE+' garbage'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                luks.parse_benchmark(output)

    def test_complete_result_replaces_time_with_costs_only(self):
        self.write()
        changed = luks.format_command(COMMAND)
        self.assertNotIn('--iter-time', changed)
        self.assertEqual(changed[11:17], ['--pbkdf-force-iterations', '13', '--pbkdf-memory', '1048576', '--pbkdf-parallel', '4'])
        self.assertEqual(changed[:11], COMMAND[:11])
        self.assertEqual(changed[17:], COMMAND[13:])
        self.assertIn('--iter-time', COMMAND)

    def test_absent_malformed_and_non_object_cache_fall_back(self):
        self.assertEqual(luks.format_command(COMMAND), COMMAND)
        for text in ('{partial', '[]', 'null', '0', 'x'*5000):
            self.path.write_text(text)
            self.path.chmod(0o600)
            self.assertEqual(luks.format_command(COMMAND), COMMAND)

    def test_invalid_results_fall_back(self):
        for key, value in [('schema', 2), ('iter_time', 1000),
                           ('key_size', 256), ('cpus', 2), ('iterations', 3),
                           ('iterations', 2**32), ('iterations', True), ('iterations', '13'),
                           ('memory', 65535), ('memory', 1048577), ('parallel', 0), ('parallel', 5)]:
            with self.subTest(key=key, value=value):
                self.write({**self.data, key:value})
                self.assertEqual(luks.format_command(COMMAND), COMMAND)

    def test_untrusted_permissions_symlink_fifo_and_owner_are_rejected(self):
        self.write()
        self.path.chmod(0o666)
        self.assertEqual(luks.cached_options(2000,512), [])
        self.path.rename(self.directory/'other')
        self.path.symlink_to(self.directory/'other')
        self.assertEqual(luks.cached_options(2000,512), [])
        self.path.unlink()
        os.mkfifo(self.path)
        self.assertEqual(luks.cached_options(2000,512), [])
        self.path.unlink()
        self.write()
        with mock.patch.object(luks.os, 'fstat', return_value=types.SimpleNamespace(st_uid=1000, st_mode=0o100600, st_size=200)):
            self.assertEqual(luks.cached_options(2000,512), [])

    def test_memory_pressure_falls_back(self):
        self.write()
        with mock.patch.object(luks, 'memory_available', return_value=1024*1024):
            self.assertEqual(luks.format_command(COMMAND), COMMAND)

    def test_custom_policy_and_non_format_commands_are_unchanged(self):
        self.write()
        for old,new in [('2000','10000'), ('512','256'), ('luks2','luks1'),
                        ('argon2id','pbkdf2'), ('luksFormat','open')]:
            command = [new if x == old else x for x in COMMAND]
            self.assertEqual(luks.format_command(command), command)
        for extra in (['--pbkdf-memory','524288'], ['--pbkdf-force-iterations','9'],
                      ['--pbkdf-parallel','2'], ['--iter-time','2000']):
            command = COMMAND+extra
            self.assertEqual(luks.format_command(command), command)

    def test_producer_publishes_complete_root_only_result(self):
        with mock.patch.object(luks.subprocess, 'run', return_value=types.SimpleNamespace(stdout=LINE)) as run:
            luks.calibrate()
        self.assertEqual(json.loads(self.path.read_text()), self.data)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.directory.glob('.result-*')), [])
        self.assertEqual(run.call_args.kwargs['env']['LC_ALL'], 'C')
        self.assertNotIn('luksFormat', run.call_args.args[0])

    def test_failed_or_skipped_benchmark_removes_stale_result(self):
        self.write()
        with mock.patch.object(luks.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'cryptsetup')):
            with self.assertRaises(subprocess.CalledProcessError): luks.calibrate()
        self.assertFalse(self.path.exists())
        self.write()
        with mock.patch.object(luks, 'memory_available', return_value=512*1024), mock.patch.object(luks.subprocess, 'run') as run:
            luks.calibrate()
            run.assert_not_called()
        self.assertFalse(self.path.exists())

    def test_small_machine_and_reduced_cost_do_not_reuse_calibration(self):
        self.write()
        with mock.patch.object(luks, 'memory_total', return_value=4*1024*1024-65536), mock.patch.object(luks.subprocess, 'run') as run:
            self.assertEqual(luks.cached_options(2000,512), [])
            luks.calibrate()
            run.assert_not_called()
        self.assertFalse(self.path.exists())
        self.write({**self.data, 'memory': 96082})
        self.assertEqual(luks.cached_options(2000,512), [])
        with mock.patch.object(luks.subprocess, 'run', return_value=types.SimpleNamespace(stdout=LINE.replace('1048576 memory','96082 memory'))):
            luks.calibrate()
        self.assertFalse(self.path.exists())

    def test_stop_failure_does_not_block_normal_format(self):
        for failure in (OSError(), subprocess.TimeoutExpired('systemctl',10)):
            with mock.patch.object(luks.subprocess, 'run', side_effect=failure):
                luks.stop_calibration()

    def test_a_poll_that_fails_still_stops_the_unit(self):
        for failure in (OSError(), subprocess.TimeoutExpired('systemctl', 5)):
            calls = []
            def run(command, **_kwargs):
                if command[-1] == luks.EARLY_KEYRING_UNIT:
                    return types.SimpleNamespace(stdout='')
                calls.append(command[1])
                if command[1] == 'show':
                    raise failure
                return types.SimpleNamespace(stdout='')
            with mock.patch.object(luks.subprocess, 'run', side_effect=run):
                luks.stop_calibration()
            self.assertEqual(calls, ['show', 'stop'])

    def stop(self, states, wait=20):
        """stop_calibration against a unit that reports each of states in
        turn (the last one from then on), on a clock that only sleep moves."""
        calls, clock = [], [0.0]
        def run(command, **_kwargs):
            if command[-1] == luks.EARLY_KEYRING_UNIT:
                return types.SimpleNamespace(stdout='')
            calls.append(command[1])
            state = states[min(calls.count('show') - 1, len(states) - 1)] if command[1] == 'show' else ''
            return types.SimpleNamespace(stdout=state)
        with mock.patch.object(luks.subprocess, 'run', side_effect=run), \
                mock.patch.object(luks.time, 'monotonic', side_effect=lambda: clock[0]), \
                mock.patch.object(luks.time, 'sleep', side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)):
            luks.stop_calibration(wait)
        return calls, clock[0]

    def test_a_benchmark_under_way_is_waited_for_then_the_unit_is_stopped(self):
        running, done = 'ActiveState=active\nJob=\n', 'ActiveState=inactive\nJob=\n'
        calls, waited = self.stop([running, running, running, done])
        self.assertEqual(calls, ['show', 'show', 'show', 'show', 'stop'])
        self.assertAlmostEqual(waited, 0.6)

    def test_a_queued_benchmark_counts_as_under_way(self):
        calls, _ = self.stop(['ActiveState=inactive\nJob=42\n', 'ActiveState=activating\nJob=42\n', 'ActiveState=inactive\nJob=\n'])
        self.assertEqual(calls, ['show', 'show', 'show', 'stop'])

    def test_a_finished_or_absent_benchmark_costs_no_wait(self):
        for state in ('ActiveState=inactive\nJob=\n', 'ActiveState=failed\nJob=\n', ''):
            calls, waited = self.stop([state])
            self.assertEqual((calls, waited), (['show', 'stop'], 0.0))

    def test_a_benchmark_that_outlasts_the_wait_is_stopped(self):
        calls, waited = self.stop(['ActiveState=active\nJob=\n'], wait=2)
        self.assertEqual(calls[-1], 'stop')
        self.assertTrue(2.0 <= waited < 2.5, waited)


class ArchinstallBoundary(unittest.TestCase):
    def test_original_encrypt_keeps_input_return_and_restores_runner_on_error(self):
        sys.path.insert(0, str(Path(__file__).parent))
        from archinstall_fakes import orchestrator_module
        calls=[]
        runner=mock.Mock(return_value='result')
        class Luks2:
            def lock(self): pass
            def encrypt(self, key_file=None):
                from archinstall.lib.disk import luks as real
                calls.append(real.run(COMMAND, input_data=b'not-logged'))
                return key_file
        names={'archinstall.lib.disk.luks': {'Luks2':Luks2, 'run':runner}}
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        with orchestrator_module('luks_tuning', names) as tuning:
            import importlib
            shared=importlib.import_module('orchestrator.luks_calibration')
            real=importlib.import_module('archinstall.lib.disk.luks')
            with mock.patch.object(shared,'stop_calibration') as stop, mock.patch.object(shared,'format_command', return_value=['changed']) as format_command, \
                    mock.patch.object(shared,'VOLUME_KEY_DIR', directory):
                wrapped=tuning._with_calibration(Luks2.encrypt)
                handler=Luks2()
                self.assertEqual(wrapped(handler, key_file='key-file'), 'key-file')
                runner.assert_called_once_with(['changed'], input_data=b'not-logged')
                stop.assert_called_once()
                self.assertIs(real.run, runner)
                # The format is given a volume key, which the handler keeps for its open.
                self.assertEqual(format_command.call_args.args, (COMMAND, handler.omarchy_volume_key))
                self.assertEqual(list(directory.iterdir()), [handler.omarchy_volume_key])
                handler.omarchy_volume_key.unlink()
                runner.side_effect=RuntimeError('format failed')
                failed=Luks2()
                with self.assertRaises(RuntimeError): wrapped(failed)
                self.assertIs(real.run, runner)
                self.assertFalse(hasattr(failed, 'omarchy_volume_key'))
                self.assertEqual(list(directory.iterdir()), [], 'a failed format leaves its volume key behind')

    def unlock(self, handler, runner):
        sys.path.insert(0, str(Path(__file__).parent))
        from archinstall_fakes import orchestrator_module
        class Luks2:
            def lock(self): pass
        names={'archinstall.lib.disk.luks': {'Luks2':Luks2}, 'archinstall.lib.command': {'run':runner},
               'archinstall.lib.exceptions': {'DiskError':RuntimeError}, 'archinstall.lib.log': {'debug':lambda *_: None}}
        with orchestrator_module('luks_tuning', names) as tuning:
            tuning._unlock(handler)

    def handler(self, **attributes):
        opened=[]
        return types.SimpleNamespace(
            luks_dev_path=Path('/dev/vda2'), mapper_name='root', is_unlocked=lambda: bool(opened),
            _get_passphrase_args=lambda key_file: ([], b'passphrase'), opened=opened, **attributes)

    def test_the_open_after_a_format_uses_its_volume_key_and_removes_it(self):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        key = directory / 'omarchy-volume-key-x'
        key.write_bytes(bytes(64))
        handler = self.handler(omarchy_volume_key=key)
        seen = {}
        def runner(command, input_data=None):
            seen.update(command=command, input_data=input_data, key_there=key.exists())
            handler.opened.append(True)
            return types.SimpleNamespace(stdout=b'')
        self.unlock(handler, runner)
        self.assertEqual(seen['command'], ['cryptsetup', 'open', '/dev/vda2', 'root', '--volume-key-file', str(key),
                                           '--type', 'luks2', '--persistent', '--allow-discards', '--perf-no_read_workqueue'])
        self.assertIsNone(seen['input_data'], 'no passphrase, so no key derivation')
        self.assertTrue(seen['key_there'])
        self.assertFalse(key.exists())
        self.assertIsNone(handler.omarchy_volume_key)

    def test_an_open_with_no_format_before_it_uses_the_passphrase(self):
        handler = self.handler()
        seen = {}
        def runner(command, input_data=None):
            seen.update(command=command, input_data=input_data)
            handler.opened.append(True)
            return types.SimpleNamespace(stdout=b'')
        self.unlock(handler, runner)
        self.assertNotIn('--volume-key-file', seen['command'])
        self.assertEqual(seen['input_data'], b'passphrase')

    def test_a_failed_open_still_removes_the_volume_key(self):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        key = directory / 'omarchy-volume-key-x'
        key.write_bytes(bytes(64))
        def runner(command, input_data=None):
            raise subprocess.CalledProcessError(1, command, output=b'no')
        with self.assertRaises(RuntimeError):
            self.unlock(self.handler(omarchy_volume_key=key), runner)
        self.assertFalse(key.exists())


class VolumeKey(unittest.TestCase):
    def test_the_key_is_random_root_only_and_the_cipher_keys_size(self):
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        with mock.patch.object(luks, 'VOLUME_KEY_DIR', directory):
            first, second = luks.new_volume_key(), luks.new_volume_key()
        for key in (first, second):
            self.assertEqual(key.parent, directory)
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(key.read_bytes()), 64)
        self.assertNotEqual(first.read_bytes(), second.read_bytes())

    def test_the_format_takes_the_key_and_keeps_its_other_arguments(self):
        with mock.patch.object(luks, 'STATE', Path('/nonexistent/result.json')):
            self.assertEqual(luks.format_command(COMMAND, Path('/run/key')),
                             COMMAND[:1] + ['--volume-key-file', '/run/key'] + COMMAND[1:])
            self.assertEqual(luks.format_command(COMMAND), COMMAND)

    def test_the_free_space_format_passes_its_key_file_on(self):
        with mock.patch.object(luks.sys, 'argv', ['omarchy-luks-calibrate', 'format', '/dev/vda3', '/run/key']), \
                mock.patch.object(luks, 'stop_calibration'), \
                mock.patch.object(luks, 'STATE', Path('/nonexistent/result.json')), \
                mock.patch.object(luks.os, 'execvp') as execvp:
            luks.main()
        argv = execvp.call_args.args[1]
        self.assertEqual(argv[:3], ['cryptsetup', '--volume-key-file', '/run/key'])
        self.assertEqual(argv[-1], '-')


class SectorSize(unittest.TestCase):
    """4096-byte encryption sectors where the device's size allows them."""
    def setUp(self):
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.enterContext(mock.patch.object(luks, 'STATE', self.directory / 'none.json'))

    def device(self, size):
        path = self.directory / f'disk-{size}'
        with open(path, 'wb') as stream:
            stream.truncate(size)
        return str(path)

    def test_archinstall_format_gets_4096_after_the_device(self):
        device = self.device(64 * 1024 * 1024)
        command = COMMAND[:-1] + [device]
        self.assertEqual(luks.format_command(command), command + ['--sector-size', '4096'])

    def test_a_size_4096_does_not_divide_keeps_the_default(self):
        # parted's inclusive end used to leave free-space partitions one
        # 512-byte sector over a MiB multiple; cryptsetup refuses 4096 there.
        device = self.device(64 * 1024 * 1024 + 512)
        command = COMMAND[:-1] + [device]
        self.assertEqual(luks.format_command(command), command)

    def test_missing_device_and_explicit_sector_size_are_left_alone(self):
        self.assertEqual(luks.format_command(COMMAND), COMMAND)
        command = COMMAND[:-1] + [self.device(64 * 1024 * 1024), '--sector-size', '512']
        self.assertEqual(luks.format_command(command), command)

    def test_calibration_still_applies(self):
        device = self.device(64 * 1024 * 1024)
        state = self.directory / 'result.json'
        state.write_text(json.dumps(dict(schema=1, iter_time=2000, key_size=512, cpus=4,
                                         iterations=13, memory=1048576, parallel=4)))
        state.chmod(0o600)
        fstat = os.fstat
        def root_stat(fd):
            st = fstat(fd)
            return types.SimpleNamespace(st_uid=0, st_mode=st.st_mode, st_size=st.st_size)
        with mock.patch.object(luks, 'STATE', state), \
                mock.patch.object(luks, 'memory_total', return_value=8*1024*1024), \
                mock.patch.object(luks, 'memory_available', return_value=4*1024*1024), \
                mock.patch.object(luks.os, 'cpu_count', return_value=4), \
                mock.patch.object(luks.os, 'fstat', side_effect=root_stat):
            changed = luks.format_command(COMMAND[:-1] + [device])
        self.assertEqual(changed[-2:], ['--sector-size', '4096'])
        self.assertIn('--pbkdf-force-iterations', changed)
        self.assertNotIn('--iter-time', changed)

    def test_free_space_format_names_the_device_after_luksformat(self):
        device = self.device(64 * 1024 * 1024)
        with mock.patch.object(luks.sys, 'argv', ['omarchy-luks-calibrate', 'format', device]), \
                mock.patch.object(luks, 'stop_calibration'), \
                mock.patch.object(luks.os, 'execvp') as execvp:
            luks.main()
        argv = execvp.call_args.args[1]
        self.assertEqual(argv[:5], ['cryptsetup', 'luksFormat', device, '--sector-size', '4096'])
        self.assertEqual(argv[-1], '-')


class DeferredArgon2Keyslot(unittest.TestCase):
    def setUp(self):
        self.directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.state = self.directory / 'result.json'
        self.data = dict(schema=1, iter_time=2000, key_size=512, cpus=4,
                         iterations=13, memory=1048576, parallel=4)
        self.state.write_text(json.dumps(self.data))
        self.state.chmod(0o600)
        fstat = os.fstat
        def root_stat(fd):
            st = fstat(fd)
            return types.SimpleNamespace(st_uid=0, st_mode=st.st_mode, st_size=st.st_size)
        self.enterContext(mock.patch.object(luks, 'STATE', self.state))
        self.enterContext(mock.patch.object(luks, 'memory_total', return_value=8*1024*1024))
        self.enterContext(mock.patch.object(luks, 'memory_available', return_value=4*1024*1024))
        self.enterContext(mock.patch.object(luks.os, 'cpu_count', return_value=4))
        self.enterContext(mock.patch.object(luks.os, 'fstat', side_effect=root_stat))

    def test_splits_calibrated_format_into_fast_slot1_and_argon2_slot0(self):
        vk = self.directory / 'vk'
        tk = self.directory / 'tk'
        split = luks.deferred_format_command(COMMAND, vk, tk)
        self.assertIsNotNone(split)
        fast_cmd, enroll_cmd, kill_cmd = split
        self.assertIn('--key-slot', fast_cmd)
        self.assertEqual(fast_cmd[fast_cmd.index('--key-slot') + 1], '1')
        self.assertEqual(fast_cmd[fast_cmd.index('--pbkdf') + 1], 'pbkdf2')
        self.assertEqual(fast_cmd[fast_cmd.index('--pbkdf-force-iterations') + 1], '1000')
        self.assertEqual(fast_cmd[-1], str(tk))
        self.assertNotIn('--iter-time', fast_cmd)
        self.assertEqual(enroll_cmd[:6], ['cryptsetup', '--batch-mode', 'luksAddKey', '--key-slot', '0', '--volume-key-file'])
        self.assertIn('--pbkdf-force-iterations', enroll_cmd)
        self.assertEqual(enroll_cmd[-2:], ['/dev/vda2', '-'])
        self.assertEqual(kill_cmd, ['cryptsetup', '--batch-mode', 'luksKillSlot', '/dev/vda2', '1'])

    def test_splits_uncalibrated_format_using_iter_time_in_background(self):
        self.state.unlink()
        vk = self.directory / 'vk'
        tk = self.directory / 'tk'
        split = luks.deferred_format_command(COMMAND, vk, tk)
        self.assertIsNotNone(split)
        fast_cmd, enroll_cmd, kill_cmd = split
        self.assertEqual(fast_cmd[fast_cmd.index('--pbkdf') + 1], 'pbkdf2')
        self.assertNotIn('--pbkdf-force-iterations', enroll_cmd)
        self.assertEqual(enroll_cmd[enroll_cmd.index('--iter-time') + 1], '2000')
        self.assertEqual(kill_cmd, ['cryptsetup', '--batch-mode', 'luksKillSlot', '/dev/vda2', '1'])

    def test_falls_back_on_low_cpus_low_memory_or_opt_out(self):
        vk, tk = self.directory / 'vk', self.directory / 'tk'
        with mock.patch.object(luks.os, 'cpu_count', return_value=2):
            self.assertIsNone(luks.deferred_format_command(COMMAND, vk, tk))
        with mock.patch.object(luks, 'memory_available', return_value=2*1024*1024):
            self.assertIsNone(luks.deferred_format_command(COMMAND, vk, tk))
        with mock.patch.dict(os.environ, {'OMARCHY_LUKS_ASYNC_KEYSLOT': '0'}):
            self.assertIsNone(luks.deferred_format_command(COMMAND, vk, tk))
        self.assertIsNone(luks.deferred_format_command(COMMAND + ['/tmp/keyfile'], vk, tk))

    def test_deferred_keyslot_enrolls_kills_slot1_and_cleans_up_files(self):
        vk = self.directory / 'vk'
        tk = self.directory / 'tk'
        vk.write_bytes(b'v' * 64)
        tk.write_bytes(b't' * 32)
        seen = []
        class FakePopen:
            def __init__(self, cmd, **_kwargs):
                self.cmd = cmd
                self.returncode = 0
            def communicate(self, input=None):
                seen.append((self.cmd, input, vk.exists(), tk.exists()))
                return b'', None
        entry = luks.DeferredKeyslot('/dev/vda2', vk, tk, ['enroll'], ['kill'], b'secret')
        with mock.patch.object(luks.subprocess, 'Popen', FakePopen):
            entry.start()
            entry.join()
        self.assertEqual([s[0] for s in seen], [['enroll'], ['kill']])
        self.assertEqual(seen[0][1], b'secret')
        self.assertTrue(seen[0][2] and seen[0][3])
        self.assertFalse(vk.exists() or tk.exists())

    def test_deferred_keyslot_failure_raises_and_cleans_up(self):
        vk = self.directory / 'vk'
        tk = self.directory / 'tk'
        vk.write_bytes(b'v' * 64)
        tk.write_bytes(b't' * 32)
        class FailPopen:
            def __init__(self, cmd, **_kwargs):
                self.returncode = 2
            def communicate(self, input=None):
                return b'bad header', None
        entry = luks.DeferredKeyslot('/dev/vda2', vk, tk, ['enroll'], ['kill'], b'secret')
        with mock.patch.object(luks.subprocess, 'Popen', FailPopen):
            entry.start()
            with self.assertRaisesRegex(RuntimeError, 'luksAddKey failed.*bad header'):
                entry.join()
        self.assertFalse(vk.exists() or tk.exists())

    def test_encrypt_inside_defer_context_keeps_volume_key_across_unlock(self):
        sys.path.insert(0, str(Path(__file__).parent))
        from archinstall_fakes import orchestrator_module
        calls = []
        def runner(cmd, input_data=None):
            calls.append((cmd, input_data))
            return types.SimpleNamespace(stdout=b'')
        class Luks2:
            def lock(self): pass
            def encrypt(self, key_file=None):
                from archinstall.lib.disk import luks as real
                real.run(COMMAND, input_data=b'passphrase')
                return key_file
        names = {
            'archinstall.lib.disk.luks': {'Luks2': Luks2, 'run': runner},
            'archinstall.lib.command': {'run': runner},
            'archinstall.lib.exceptions': {'DiskError': RuntimeError},
            'archinstall.lib.log': {'debug': lambda *_: None},
        }
        with orchestrator_module('luks_tuning', names) as tuning:
            import importlib
            shared = importlib.import_module('orchestrator.luks_calibration')
            real_fstat = os.fstat
            with mock.patch.object(shared, 'stop_calibration') as stop, \
                    mock.patch.object(shared, 'VOLUME_KEY_DIR', self.directory), \
                    mock.patch.object(shared, 'STATE', self.state), \
                    mock.patch.object(shared, 'memory_total', return_value=8*1024*1024), \
                    mock.patch.object(shared, 'memory_available', return_value=4*1024*1024), \
                    mock.patch.object(shared.os, 'cpu_count', return_value=4), \
                    mock.patch.object(shared.os, 'fstat', side_effect=lambda fd: types.SimpleNamespace(
                        st_uid=0, st_mode=real_fstat(fd).st_mode, st_size=real_fstat(fd).st_size)):
                wrapped = tuning._with_calibration(Luks2.encrypt)
                handler = Luks2()
                handler.luks_dev_path = Path('/dev/vda2')
                handler.mapper_name = 'root'
                handler.is_unlocked = lambda: len(calls) >= 2
                with tuning.defer_argon2_keyslot() as deferred:
                    wrapped(handler)
                    stop.assert_called_once_with(wait=0)
                    self.assertEqual(len(deferred), 1)
                    vk = handler.omarchy_volume_key
                    self.assertTrue(handler.omarchy_keep_volume_key)
                    tuning._unlock(handler)
                    # Volume key remains alive for the background luksAddKey.
                    self.assertTrue(vk.exists())
                # Abort cleans up both temporary keys.
                deferred[0].abort()
                self.assertFalse(vk.exists())
                self.assertFalse(deferred[0].temp_keyfile.exists())

    def test_real_cryptsetup_deferred_format_enroll_and_unlock(self):
        import shutil
        if not shutil.which('cryptsetup'):
            self.skipTest('cryptsetup not installed')
        image = self.directory / 'deferred.img'
        with image.open('wb') as stream:
            stream.truncate(32 * 1024 * 1024)
        vk = self.directory / 'vk'
        tk = self.directory / 'tk'
        vk.write_bytes(os.urandom(64))
        tk.write_bytes(os.urandom(32))
        vk.chmod(0o600)
        tk.chmod(0o600)
        command = COMMAND[:-1] + [str(image)]
        with mock.patch.object(luks, 'cached_options', return_value=[
            '--pbkdf-force-iterations', '4', '--pbkdf-memory', '65536', '--pbkdf-parallel', '2',
        ]):
            split = luks.deferred_format_command(command, vk, tk)
        self.assertIsNotNone(split)
        fast_cmd, enroll_cmd, kill_cmd = split
        subprocess.run(fast_cmd, check=True, capture_output=True)
        entry = luks.DeferredKeyslot(str(image), vk, tk, enroll_cmd, kill_cmd, b'test-passphrase')
        entry.start()
        entry.join()
        self.assertFalse(vk.exists() or tk.exists())
        dump = json.loads(subprocess.check_output(
            ['cryptsetup', 'luksDump', '--dump-json-metadata', str(image)]))
        self.assertEqual(list(dump['keyslots'].keys()), ['0'])
        kdf = dump['keyslots']['0']['kdf']
        self.assertEqual((kdf['type'], kdf['time'], kdf['memory'], kdf['cpus']), ('argon2id', 4, 65536, 2))
        subprocess.run(
            ['cryptsetup', 'open', '--test-passphrase', str(image)],
            input=b'test-passphrase', check=True, capture_output=True)



class KeyslotEnrollmentCpusTest(unittest.TestCase):
    """With the installer kept on a hybrid CPU's performance cores, the Argon2
    enrollment still gets every CPU the installer started with."""

    def entry(self, tmp):
        vk, tk = Path(tmp) / "vk", Path(tmp) / "tk"
        vk.write_text("k")
        tk.write_text("k")
        entry = luks.DeferredKeyslot("/dev/vda2", vk, tk, ["enroll"], ["kill"], b"secret")
        steps = []

        def run_step(cmd, *, input_data=None):
            steps.append(list(cmd))
            return 0, ""
        entry._run_step = run_step
        return entry, steps

    def test_the_enrollment_runs_on_the_cpus_the_installer_started_with(self):
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.dict(os.environ, {"OMARCHY_INSTALLER_ALL_CPUS": "0-15"}):
            entry, steps = self.entry(tmp)
            entry._worker()
        self.assertEqual(steps, [["taskset", "-c", "0-15", "enroll"], ["kill"]])

    def test_an_installer_that_was_not_moved_runs_it_as_before(self):
        env = {k: v for k, v in os.environ.items() if k != "OMARCHY_INSTALLER_ALL_CPUS"}
        with tempfile.TemporaryDirectory() as tmp, mock.patch.dict(os.environ, env, clear=True):
            entry, steps = self.entry(tmp)
            entry._worker()
        self.assertEqual(steps, [["enroll"], ["kill"]])


if __name__ == '__main__': unittest.main()
