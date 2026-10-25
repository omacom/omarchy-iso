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
        with orchestrator_module('luks_tuning', names) as tuning:
            import importlib
            shared=importlib.import_module('orchestrator.luks_calibration')
            real=importlib.import_module('archinstall.lib.disk.luks')
            with mock.patch.object(shared,'stop_calibration') as stop, mock.patch.object(shared,'format_command', return_value=['changed']):
                wrapped=tuning._with_calibration(Luks2.encrypt)
                self.assertEqual(wrapped(Luks2(), key_file='key-file'), 'key-file')
                runner.assert_called_once_with(['changed'], input_data=b'not-logged')
                stop.assert_called_once()
                self.assertIs(real.run, runner)
                runner.side_effect=RuntimeError('format failed')
                with self.assertRaises(RuntimeError): wrapped(Luks2())
                self.assertIs(real.run, runner)


if __name__ == '__main__': unittest.main()
