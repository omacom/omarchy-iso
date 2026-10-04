#!/usr/bin/env python3
"""Acquire pinned vendor inputs and verify the selected firmware byte-for-byte."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
PREFIX = '/usr/lib/firmware/updates/'


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def verify_payload(root):
    for board in ('hp', 't14s'):
        expected = set()
        for line in (HERE / 'inputs' / f'{board}-files.sha256').read_text().splitlines():
            checksum, name = line.split(maxsplit=1)
            relative = name.removeprefix(PREFIX)
            path = root / board / relative
            if not path.is_file() or digest(path) != checksum:
                raise ValueError(f'Firmware mismatch: {path}')
            expected.add(relative)
        actual = {str(p.relative_to(root / board)) for p in (root / board).rglob('*') if p.is_file()}
        if actual != expected:
            raise ValueError(f'Unexpected firmware inventory for {board}: {actual ^ expected}')


def fetch(source, cache):
    target = cache / source['filename']
    if target.exists():
        if digest(target) != source['sha256']:
            raise ValueError(f'Cached input hash mismatch: {target}; remove it to retry')
        return target
    partial = target.with_suffix(target.suffix + '.part')
    run('curl', '--fail', '--location', '--retry', '3', '--connect-timeout', '30',
        '--max-time', '1800', '--output', partial, source['url'])
    if digest(partial) != source['sha256']:
        raise ValueError(f'Download hash mismatch: {partial}')
    partial.replace(target)
    return target


def copy(source, dest):
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, dest)


def extract(inputs, work, payload):
    hp = work / 'hp'
    names = {
        'qcdxkmsuc8380.mbn': 'qcdx8380',
        'qcadsp8380.mbn': '1ADSP_7700_0711_hamoa',
        'adsp_dtbs.elf': '1ADSP_7700_0711_hamoa',
        'qccdsp8380.mbn': '1qcnspmcdm_ext_cdsp8380_7800',
        'cdsp_dtbs.elf': '1qcnspmcdm_ext_cdsp8380_7800',
    }
    run('7z', 'x', '-y', f'-o{hp}', inputs['hp'],
        *[f'src/Driver/{directory}/{name}' for name, directory in names.items()])
    for name, directory in names.items():
        copy(hp / 'src/Driver' / directory / name,
             payload / 'hp/qcom/x1e80100/hp/elitebook-ultra-g1q' / name)
    ubuntu = work / 'ubuntu'
    squash = work / 'minimal.squashfs'
    run('xorriso', '-osirrox', 'on', '-indev', inputs['ubuntu'],
        '-extract', '/casper/minimal.squashfs', squash)
    run('unsquashfs', '-no-progress', '-d', ubuntu, squash,
        'usr/lib/firmware/qcom/x1e80100', 'usr/share/doc/linux-firmware*')
    firmware = ubuntu / 'usr/lib/firmware'
    for line in (HERE / 'inputs/t14s-files.sha256').read_text().splitlines():
        _, name = line.split(maxsplit=1)
        relative = name.removeprefix(PREFIX)
        if Path(relative).name in ('qccdsp8380.mbn', 'cdsp_dtbs.elf') or relative.endswith('-tplg.bin'):
            continue
        source = firmware / relative
        dest = payload / 't14s' / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        if source.is_file():
            copy(source, dest)
        else:
            with dest.open('wb') as stream:
                run('zstd', '-dc', str(source) + '.zst', stdout=stream)
    for group in ('graphics', 'misc', 'wireless'):
        copy(ubuntu / f'usr/share/doc/linux-firmware-qualcomm-{group}/copyright',
             payload / 'licenses' / f'qualcomm-{group}.copyright')
    lenovo = work / 'lenovo'
    run('innoextract', '-d', lenovo, inputs['lenovo'])
    source = lenovo / 'code$GetExtractPath$/N42QQ23W/N42QG16W/Core_drivers/qcnspmcdm_ext_cdsp8380'
    for name in ('qccdsp8380.mbn', 'cdsp_dtbs.elf'):
        copy(source / name, payload / 't14s/qcom/x1e80100/LENOVO/21N1' / name)
    audio = work / 'audio'
    audio.mkdir()
    run('tar', '-xf', inputs['audio'], '--strip-components=1', '-C', audio)
    config = work / 'topology.conf'
    topology = work / 'topology.bin'
    with config.open('wb') as stream:
        run('m4', '-I', audio, audio / 'X1E80100-LENOVO-Thinkpad-T14s.m4', stdout=stream)
    run('alsatplg', '-c', config, '-o', topology)
    for dest in ('hp/qcom/x1e80100/X1E80100-HP-ELITEBOOK-ULTRA-G1Q-tplg.bin',
                 't14s/qcom/x1e80100/X1E80100-LENOVO-Thinkpad-T14s-tplg.bin',
                 't14s/qcom/x1e80100/LENOVO/21N1/X1E80100-LENOVO-Thinkpad-T14s-tplg.bin'):
        copy(topology, payload / dest)
    copy(audio / 'LICENSE.BSD-3-Clause', payload / 'licenses/AudioReach.BSD-3-Clause')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-dir', type=Path, required=True)
    args = parser.parse_args()
    work = args.work_dir.resolve()
    cache = work / 'downloads'
    cache.mkdir(parents=True, exist_ok=True)
    sources = json.loads((HERE / 'inputs/sources.json').read_text())
    inputs = {name: fetch(source, cache) for name, source in sources.items()}
    output = work / 'firmware'
    if output.exists():
        verify_payload(output)
        print(output)
        return
    with tempfile.TemporaryDirectory(prefix='extract-', dir=work) as temporary:
        stage = Path(temporary)
        payload = stage / 'payload'
        extract(inputs, stage, payload)
        verify_payload(payload)
        copy(HERE / 'inputs/sources.json', payload / 'sources.json')
        payload.rename(output)
    print(output)


if __name__ == '__main__':
    main()
