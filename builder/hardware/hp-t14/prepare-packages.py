#!/usr/bin/env python3
"""Generate HP/T14 package recipes from verified upstream firmware inputs."""
import argparse
import hashlib
import importlib.util
import pathlib
import shutil

here = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('firmware', here / 'fetch-firmware.py')
firmware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(firmware)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--work-dir', type=pathlib.Path, required=True)
args = parser.parse_args()
workdir = args.work_dir.resolve()
verified = workdir / 'firmware'
firmware.verify_payload(verified)
out = workdir / 'hardware'
out.mkdir(parents=True, exist_ok=True)
for board in ('hp', 't14s'):
    work = out / f'omarchy-hw-{board}-experimental'
    payload = work / 'payload'
    if payload.exists():
        shutil.rmtree(payload)
    fw = payload / 'usr/lib/firmware/updates'
    shutil.copytree(verified / board, fw)
    if board == 'hp':
        ucm = payload / 'usr/share/alsa/ucm2/conf.d/x1e80100'
        ucm.mkdir(parents=True, exist_ok=True)
        hp_ucm = payload / 'usr/share/alsa/ucm2/Qualcomm/x1e80100'
        hp_ucm.mkdir(parents=True, exist_ok=True)
        stock_ucm = pathlib.Path('/usr/share/alsa/ucm2')
        sources = {
            'Qualcomm/x1e80100/LENOVO-T14s.conf': '93a812a711361e7212471ace6ab4c7eb575999fdf1c99ae4809da769fbde3877',
            'Qualcomm/x1e80100/T14s-HiFi.conf': '6f5956f731c02f54345016e4a2a86299e4af87ef6e0748a0d6a1caf8ecdc9f46',
            'codecs/qcom-lpass/va-macro/DMIC1EnableSeq.conf': 'ad638327f00aaff89b6f19ce4151fbf4c345c2d9394088074eda11b106e8f9eb',
        }
        contents = {}
        for name, expected in sources.items():
            data = (stock_ucm / name).read_bytes()
            if hashlib.sha256(data).hexdigest() != expected:
                raise SystemExit(f'Unexpected ALSA UCM source: {name}')
            contents[name] = data.decode()
        def replace_once(data, old, new):
            if data.count(old) != 1:
                raise SystemExit(f'Expected one UCM match: {old}')
            return data.replace(old, new)
        wrapper = replace_once(contents['Qualcomm/x1e80100/LENOVO-T14s.conf'],
                               '/Qualcomm/x1e80100/T14s-HiFi.conf',
                               '/Qualcomm/x1e80100/HP-HiFi.conf')
        hifi = contents['Qualcomm/x1e80100/T14s-HiFi.conf']
        hifi = replace_once(hifi, '/codecs/qcom-lpass/va-macro/DMIC1EnableSeq.conf',
                            '/Qualcomm/x1e80100/HP-DMIC2EnableSeq.conf')
        dmic = replace_once(contents['codecs/qcom-lpass/va-macro/DMIC1EnableSeq.conf'],
                            "name='VA DMIC MUX1' DMIC1", "name='VA DMIC MUX1' DMIC2")
        (hp_ucm / 'HP-ELITEBOOK-ULTRA-G1Q.conf').write_text(wrapper)
        (hp_ucm / 'HP-HiFi.conf').write_text(hifi)
        (hp_ucm / 'HP-DMIC2EnableSeq.conf').write_text(dmic)
        for name in ('HP-HPEliteBookUltraG1q14inchNotebookAIPC-ConfigID-8CBE.conf', 'X1E80100-HP-ELITEBOOK-ULTRA-G1Q.conf'):
            p = ucm / name
            if p.exists() or p.is_symlink(): p.unlink()
            p.symlink_to('../../Qualcomm/x1e80100/HP-ELITEBOOK-ULTRA-G1Q.conf')

    docs = payload / 'usr/share/doc' / work.name
    docs.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(here / 'inputs/sources.json', docs / 'sources.json')
    shutil.copyfile(here / 'inputs' / f'{board}-files.sha256', docs / 'FILES.sha256')
    licenses = payload / 'usr/share/licenses' / work.name
    shutil.copytree(verified / 'licenses', licenses)
    shutil.copyfile('/usr/share/licenses/alsa-ucm-conf/LICENSE', licenses / 'ALSA-UCM.LICENSE')
    (docs / 'README').write_text('Omarchy Snapdragon hardware support. Firmware acquired from hash-pinned upstream archives. No QNN SDK/runtime included.\n')
    init = payload / 'etc/mkinitcpio.conf.d'
    init.mkdir(parents=True, exist_ok=True)
    (init / f'{work.name}.conf').write_text('FILES+=(' + ' '.join('/' + str(p.relative_to(payload)) for p in sorted(fw.rglob('*')) if p.is_file()) + ')\n')
    (work / 'PKGBUILD').write_text(f'''pkgname={work.name}
pkgver={'0.3' if board == 'hp' else '0.2'}
pkgrel=2
pkgdesc='HP/ThinkPad Snapdragon firmware and audio support'
arch=('any')
license=('custom')
depends=('linux-firmware-qcom' 'alsa-ucm-conf' 'omarchy-hw-snapdragon-early-experimental')
options=('!strip' '!debug')
package() {{ cp -a "$startdir/payload/." "$pkgdir/"; }}
''')
shutil.copytree(here / 'early', out / 'omarchy-hw-snapdragon-early-experimental', dirs_exist_ok=True)
print(out)
