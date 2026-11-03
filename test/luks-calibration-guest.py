#!/usr/bin/env python3
"""Run inside the live QEMU guest; formats only newly-created scratch files."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time


def command(argv, **kwargs):
    start = time.monotonic()
    result = subprocess.run(argv, check=True, capture_output=True, **kwargs)
    return result, time.monotonic() - start


def wait_for_calibration(unit, timeout=120):
    """Wait for an actual successful execution, with or without a cache.

    Before a queued Type=exec service starts, it can also be inactive with
    Result=success. ExecMainCode=1 means its process exited normally; zero
    means it has not run. A failed, killed or missing service is not a skip.
    """
    deadline = time.monotonic() + timeout
    while True:
        result, _ = command([
            'systemctl', 'show', unit,
            '--property=LoadState,ActiveState,Result,ExecMainCode,ExecMainStatus',
        ], text=True)
        status = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        if status.get('LoadState') != 'loaded' or status.get('ActiveState') == 'failed':
            raise AssertionError(f'Calibration service failed: {status}')
        if status.get('ActiveState') == 'inactive' and status.get('ExecMainCode') != '0':
            assert (status.get('Result'), status.get('ExecMainCode'), status.get('ExecMainStatus')) == (
                'success', '1', '0'), f'Calibration service did not exit successfully: {status}'
            return status
        if time.monotonic() >= deadline:
            raise TimeoutError(f'Calibration service did not finish: {status}')
        time.sleep(1)


def exercise_formats(calibration, Luks2, report, expect_no_cache=False):
    state = calibration.STATE
    saved = state.read_bytes() if state.exists() else None
    cache = json.loads(saved) if saved is not None else None
    report['calibration'] = cache
    report['cache_status'] = 'ready' if cache is not None else 'skipped'
    if expect_no_cache:
        assert saved is None, 'small-memory guest unexpectedly cached calibration'
    if saved is not None:
        assert calibration.cached_options(2000, 512), 'boot service produced unusable calibration'
    else:
        assert not calibration.cached_options(2000, 512)
    modes = (('cached',) if cache is not None else ()) + ('absent', 'malformed', 'archinstall')
    try:
        with tempfile.TemporaryDirectory(prefix='luks-calibration-', dir='/var/tmp') as tmp:
            tmp = Path(tmp)
            key = tmp / 'test-key'
            password = b'only-a-disposable-vm-test'
            key.write_bytes(password)
            key.chmod(0o600)
            for mode in modes:
                if mode == 'malformed':
                    state.write_text('{partial')
                elif mode == 'absent' or saved is None:
                    state.unlink(missing_ok=True)
                else:
                    state.write_bytes(saved)
                image = tmp / f'{mode}.img'
                with image.open('xb') as stream:
                    stream.truncate(64 * 1024 * 1024)
                if mode == 'archinstall':
                    start = time.monotonic()
                    returned = Luks2(image).encrypt(iter_time=2000, key_file=key)
                    assert returned == key
                    elapsed = time.monotonic() - start
                    output = ''
                else:
                    result, elapsed = command(['omarchy-luks-calibrate', 'format', str(image)], input=password)
                    output = result.stderr.decode()
                    assert ('Using this boot' in output) == (mode == 'cached'), output
                result, _ = command(['cryptsetup', 'luksDump', '--dump-json-metadata', str(image)])
                metadata = json.loads(result.stdout)
                slot = metadata['keyslots']['0']
                kdf = slot['kdf']
                assert kdf['type'] == 'argon2id'
                assert slot['key_size'] == 64
                assert kdf['time'] >= 4 and 1 <= kdf['cpus'] <= 4
                assert calibration.MIN_MEMORY <= kdf['memory'] <= calibration.MAX_MEMORY
                if cache is not None:
                    if mode in ('cached', 'archinstall'):
                        assert (kdf['time'], kdf['memory'], kdf['cpus']) == (
                            cache['iterations'], cache['memory'], cache['parallel'])
                    else:
                        assert kdf['memory'] == cache['memory'] and kdf['cpus'] == cache['parallel']
                unlock = []
                for _ in range(3):
                    _, duration = command(['cryptsetup', 'open', '--test-passphrase', '--key-file', str(key), str(image)])
                    unlock.append(duration)
                report['runs'].append(dict(mode=mode, format_seconds=elapsed, unlock_seconds=unlock,
                                           kdf=kdf, metadata=metadata, stderr=output))
                image.unlink()
            if cache is not None:
                runs = {row['mode']: row for row in report['runs']}
                report['cached_to_ordinary_unlock_ratio'] = (statistics.median(runs['cached']['unlock_seconds'])
                                                             / statistics.median(runs['absent']['unlock_seconds']))
                report['format_saved_seconds'] = runs['absent']['format_seconds'] - runs['cached']['format_seconds']
                # The cost of a guess is the KDF's: memory and parallelism are
                # the cache's in every mode (above), so compare iterations, not
                # unlock seconds, which move with the CI host's speed between
                # two unlocks. Against both ordinary calibrations, because one
                # benchmark alone varies too: absent 13 and malformed 10 within
                # a minute on one runner, where unlock seconds put the cache at
                # 0.59 of ordinary. Keep raw timings; fail a material weakening.
                ordinary = statistics.median([runs['absent']['kdf']['time'], runs['malformed']['kdf']['time']])
                report['cached_to_ordinary_iterations_ratio'] = runs['cached']['kdf']['time'] / ordinary
                assert 0.70 <= report['cached_to_ordinary_iterations_ratio'] <= 1.40, report
                assert report['format_saved_seconds'] > 1, report
            assert len({row['kdf']['salt'] for row in report['runs']}) == len(modes)
    finally:
        if saved is None:
            state.unlink(missing_ok=True)
        else:
            state.write_bytes(saved)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--expect-no-cache', action='store_true')
    args = parser.parse_args()
    sys.path.insert(0, '/usr/share/omarchy-iso')
    from orchestrator import luks_calibration as calibration
    report = {'memory_kib': calibration.memory_available(), 'runs': []}
    try:
        report['service'] = wait_for_calibration(calibration.UNIT)
        # archinstall parses argv on import; use the real dependency on the ISO.
        sys.argv = sys.argv[:1]
        from archinstall.lib.disk.luks import Luks2
        from orchestrator import luks_tuning
        luks_tuning.apply()
        exercise_formats(calibration, Luks2, report, args.expect_no_cache)
    finally:
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
