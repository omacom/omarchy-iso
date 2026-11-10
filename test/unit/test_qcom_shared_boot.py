#!/usr/bin/env python3
"""Run the real UKI builder and mkinitcpio hook with isolated file fixtures."""
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('firmware', ROOT/'builder/qualcomm/early-firmware.py')
firmware = importlib.util.module_from_spec(spec)
spec.loader.exec_module(firmware)


def dtb(compatible='qcom,x1e80100-adsp-pas', name='qcom/vendor/adsp.mbn'):
    strings = b'model\0compatible\0firmware-name\0'
    data = bytearray()
    def word(n): data.extend(struct.pack('>I', n))
    def text(value):
        data.extend(value); data.extend(bytes(-len(data) % 4))
    def prop(offset, value):
        word(3); word(len(value)); word(offset); text(value)
    word(1); text(b'\0'); prop(0, b'Test board\0')
    word(1); text(b'remoteproc@1000\0')
    prop(6, compatible.encode()+b'\0'); prop(17, name.encode()+b'\0')
    word(2); word(2); word(9)
    return struct.pack('>10I', 0xd00dfeed,56+len(data)+len(strings),56,56+len(data),40,17,16,0,len(strings),len(data))+bytes(16)+data+strings


class FirmwareTests(unittest.TestCase):
    def test_x1_and_x2_owners(self):
        result=firmware.firmware_inventory([dtb(),dtb('qcom,glymur-soccp-pas','qcom/soccp.mbn')])
        self.assertEqual(result[0]['required'], ['qcom/vendor/adsp.mbn'])
        self.assertEqual(result[1]['required'], [])
        self.assertEqual(result[1]['optional'], ['qcom/soccp.mbn'])

    def test_invalid_tree_stops_build(self):
        with self.assertRaises(RuntimeError): firmware.firmware_inventory([dtb()[:-5]])
        with self.assertRaises(RuntimeError): firmware.firmware_inventory([dtb('other,processor')])

    def test_cli_lists_exact_firmware_and_rejects_escape(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name); blob=root/'board.dtb'; manifest=root/'dtbs'
            manifest.write_text(str(blob)+'\n')
            blob.write_bytes(dtb())
            result=subprocess.run(['python3',str(ROOT/'builder/qualcomm/early-firmware.py'),str(manifest)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(result.stdout,'qcom/vendor/adsp.mbn\n')
            blob.write_bytes(dtb(name='../private'))
            result=subprocess.run(['python3',str(ROOT/'builder/qualcomm/early-firmware.py'),str(manifest)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('Unsafe',result.stderr)

    def test_cli_required_leaves_out_optional_firmware(self):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name); manifest=root/'dtbs'
            (root/'x1.dtb').write_bytes(dtb())
            (root/'glymur.dtb').write_bytes(dtb('qcom,glymur-soccp-pas','qcom/soccp.mbn'))
            manifest.write_text(f'{root}/x1.dtb\n{root}/glymur.dtb\n')
            script=str(ROOT/'builder/qualcomm/early-firmware.py')
            result=subprocess.run(['python3',script,str(manifest)],capture_output=True,text=True)
            self.assertEqual(result.stdout,'qcom/soccp.mbn\nqcom/vendor/adsp.mbn\n',result.stderr)
            result=subprocess.run(['python3',script,'--required',str(manifest)],capture_output=True,text=True)
            self.assertEqual(result.stdout,'qcom/vendor/adsp.mbn\n',result.stderr)


class StageMediumFirmwareTests(unittest.TestCase):
    """Run the real medium-firmware staging against synthetic packages."""

    SCRIPT=ROOT/'builder/qualcomm/stage-medium-firmware.sh'
    DTBS='boot/dtbs/linux-omarchy/qcom/'
    FW='usr/lib/firmware/qcom/'

    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name); self.out=self.root/'out'

    def package(self,name,files,links=()):
        path=self.root/name
        with tarfile.open(path,'w') as tar:
            for member,data in files.items():
                info=tarfile.TarInfo(member); info.size=len(data); tar.addfile(info,io.BytesIO(data))
            for member,target in links:
                info=tarfile.TarInfo(member); info.type=tarfile.SYMTYPE; info.linkname=target; tar.addfile(info)
        return str(path)

    def stage(self,kernel,*packages,trees=()):
        flags=[arg for package in trees for arg in ('--trees',package)]
        return subprocess.run(['bash',str(self.SCRIPT),*flags,kernel,str(self.out),*packages],capture_output=True,text=True)

    def staged(self):
        return sorted(str(p.relative_to(self.out)) for p in self.out.rglob('*') if p.is_file())

    def test_stages_what_the_device_trees_require_whatever_its_name(self):
        kernel=self.package('kernel.pkg.tar',{
            self.DTBS+'x1e80100-vendor-laptop.dtb':dtb(name='qcom/vendor/qcadsp8380.mbn'),
            # Named nothing like qcadsp*: a name pattern would miss it.
            self.DTBS+'x1p42100-other-laptop.dtb':dtb(name='qcom/other/audio-dsp.mbn'),
            self.DTBS+'x1e80100-vendor-laptop-el2.dtb':dtb(name='qcom/el2/qcadsp8380.mbn'),
            self.DTBS+'sm8550-phone.dtb':dtb(name='qcom/phone/qcadsp8550.mbn'),
        })
        vendor=self.package('vendor.pkg.tar',{self.FW+'vendor/qcadsp8380.mbn.xz':b'vendor adsp',
                                              self.FW+'vendor/qccdsp8380.mbn.xz':b'cdsp'})
        other=self.package('other.pkg.tar',{self.FW+'other/audio-dsp.mbn.zst':b'other adsp'})
        el2=self.package('el2.pkg.tar',{self.FW+'el2/qcadsp8380.mbn':b'el2'})
        phone=self.package('phone.pkg.tar',{self.FW+'phone/qcadsp8550.mbn':b'phone'})
        result=self.stage(kernel,vendor,other,el2,phone)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.staged(),['SHA256SUMS','qcom/other/audio-dsp.mbn.zst','qcom/vendor/qcadsp8380.mbn.xz'])
        self.assertIn('2 files',result.stdout)

    def test_sha256sums_is_what_the_boot_hook_reads(self):
        kernel=self.package('kernel.pkg.tar',{self.DTBS+'x1e80100-vendor-laptop.dtb':dtb(name='qcom/vendor/adsp.mbn')})
        vendor=self.package('vendor.pkg.tar',{self.FW+'vendor/adsp.mbn.xz':b'adsp'})
        result=self.stage(kernel,vendor)
        self.assertEqual(result.returncode,0,result.stderr)
        # early-startup reads "<sum> <name>" with the name relative to qcom-firmware/.
        line=(self.out/'SHA256SUMS').read_text()
        self.assertRegex(line,r'^[0-9a-f]{64}  qcom/vendor/adsp\.mbn\.xz\n$')
        check=subprocess.run(['sha256sum','-c','SHA256SUMS'],cwd=self.out,capture_output=True,text=True)
        self.assertEqual(check.returncode,0,check.stdout+check.stderr)

    def test_device_tree_selection_matches_the_live_uki(self):
        def loop(path):
            lines=[l.strip() for l in path.read_text().splitlines() if l.strip().startswith('for dtb in "$dtb_dir"/')]
            self.assertEqual(len(lines),1,path); return lines[0]
        self.assertEqual(loop(self.SCRIPT),loop(ROOT/'builder/qualcomm/live-uki.sh'))

    def test_a_symlinked_firmware_file_fails_the_build(self):
        kernel=self.package('kernel.pkg.tar',{self.DTBS+'x1e80100-vendor-laptop.dtb':dtb(name='qcom/vendor/adsp.mbn')})
        vendor=self.package('vendor.pkg.tar',{self.FW+'vendor/real.mbn.xz':b'adsp'},
                            links=((self.FW+'vendor/adsp.mbn.xz','real.mbn.xz'),))
        result=self.stage(kernel,vendor)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('symlink',result.stderr)

    def test_nothing_to_stage_fails_the_build(self):
        kernel=self.package('kernel.pkg.tar',{self.DTBS+'x1e80100-vendor-laptop.dtb':dtb(name='qcom/vendor/adsp.mbn')})
        unrelated=self.package('unrelated.pkg.tar',{self.FW+'elsewhere/adsp.mbn':b'x'})
        result=self.stage(kernel,unrelated)
        self.assertNotEqual(result.returncode,0)

    def test_a_kernel_without_snapdragon_trees_fails_the_build(self):
        kernel=self.package('kernel.pkg.tar',{self.DTBS+'sm8550-phone.dtb':dtb()})
        result=self.stage(kernel)
        self.assertNotEqual(result.returncode,0)

    def test_trees_come_from_the_package_the_kernel_depends_on_for_them(self):
        # The kernel ships no trees; linux-omarchy-dtbs has them.
        kernel=self.package('kernel.pkg.tar',{'usr/lib/modules/7.3.0/vmlinuz':b'kernel'})
        trees=self.package('trees.pkg.tar',{self.DTBS+'x1e80100-vendor-laptop.dtb':dtb(name='qcom/vendor/adsp.mbn')})
        vendor=self.package('vendor.pkg.tar',{self.FW+'vendor/adsp.mbn.xz':b'adsp'})
        result=self.stage(kernel,vendor,trees=(trees,))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.staged(),['SHA256SUMS','qcom/vendor/adsp.mbn.xz'])

    def test_no_trees_in_any_package_fails_the_build(self):
        kernel=self.package('kernel.pkg.tar',{'usr/lib/modules/7.3.0/vmlinuz':b'kernel'})
        trees=self.package('trees.pkg.tar',{'usr/share/doc/trees/README':b'none'})
        vendor=self.package('vendor.pkg.tar',{self.FW+'vendor/adsp.mbn.xz':b'adsp'})
        result=self.stage(kernel,vendor,trees=(trees,))
        self.assertNotEqual(result.returncode,0)
        self.assertIn('no Snapdragon device trees in kernel.pkg.tar trees.pkg.tar',result.stderr)


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        for directory in ('bin','boot/dtbs/test/qcom','hwids'):
            (self.root/directory).mkdir(parents=True)
        self.config=self.root/'archiso.conf'; self.config.write_text('HOOKS=(base udev archiso)\n')
        self.kernel=self.root/'boot/vmlinuz-test'; self.kernel.write_bytes(b'kernel')
        self.initrd=self.root/'boot/initramfs-test.img'; self.initrd.write_bytes(b'original initramfs')
        self.env=os.environ | {'PATH':str(self.root/'bin')+':'+os.environ['PATH'], 'TEST_ROOT':str(self.root)}

    def executable(self,name,text):
        path=self.root/'bin'/name; path.write_text(text); path.chmod(0o755)

    def builder(self):
        code=(ROOT/'builder/qualcomm/live-uki.sh').read_text()
        for old,new in (('/usr/lib/systemd/boot/hwids/aa64',str(self.root/'hwids')),('/boot/',str(self.root/'boot')+'/'),('/etc/mkinitcpio.conf.d/archiso.conf',str(self.config))):
            code=code.replace(old,new)
        self.executable('builder',code)
        self.executable('mkinitcpio','''#!/usr/bin/env python3
import json,os,pathlib,sys
root=pathlib.Path(os.environ['TEST_ROOT']); args=sys.argv[1:]
(root/'mkinitcpio-call.json').write_text(json.dumps({'args':args,'dtbs':pathlib.Path(os.environ['OMARCHY_QCOM_DTBS_FILE']).read_text()}))
if os.environ.get('FAIL_MKINITCPIO'): sys.exit(23)
pathlib.Path(args[args.index('-g')+1]).write_bytes(b'Qualcomm initramfs')
''')
        self.executable('ukify','''#!/usr/bin/env python3
import json,os,pathlib,sys
root=pathlib.Path(os.environ['TEST_ROOT']); args=sys.argv[1:]
if args[0]=='build':
 initrd=next(x.split('=',1)[1] for x in args if x.startswith('--initrd='))
 assert pathlib.Path(initrd).read_bytes()==b'Qualcomm initramfs'
 (root/'ukify-call.json').write_text(json.dumps(args))
 output=pathlib.Path(next(x.split('=',1)[1] for x in args if x.startswith('--output=')))
 output.write_bytes(b'UKI')
 if os.environ.get('UKI_BYTES'):
  with open(output,'r+b') as f: f.truncate(int(os.environ['UKI_BYTES']))
else:
 args=json.loads((root/'ukify-call.json').read_text()); print('.hwids:')
 for arg in args:
  if arg.startswith('--devicetree-auto='): print('.dtbauto:')
''')
        return subprocess.run([str(self.root/'bin/builder'),'test'],env=self.env,capture_output=True,text=True)

    def test_dedicated_initramfs_keeps_direct_boot_untouched(self):
        dtb_root=self.root/'boot/dtbs/test/qcom'
        for name in ('x1-test.dtb','glymur-test.dtb','mahua-test.dtb','x1-test-el2.dtb','sm8550-test.dtb'):
            (dtb_root/name).write_bytes(b'dtb')
        result=self.builder(); self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.initrd.read_bytes(),b'original initramfs')
        call=json.loads((self.root/'mkinitcpio-call.json').read_text())
        self.assertIn('qcom_early_startup',call['args'])
        self.assertEqual(call['args'][call['args'].index('-c')+1],str(self.config))
        self.assertIn('x1-test.dtb',call['dtbs']); self.assertIn('glymur-test.dtb',call['dtbs']); self.assertIn('mahua-test.dtb',call['dtbs'])
        self.assertNotIn('el2',call['dtbs']); self.assertNotIn('sm8550',call['dtbs'])
        self.assertFalse(Path(call['args'][call['args'].index('-g')+1]).exists())

    def test_failed_initramfs_cannot_produce_uki(self):
        (self.root/'boot/dtbs/test/qcom/x1-test.dtb').touch()
        self.env['FAIL_MKINITCPIO']='1'
        result=self.builder(); self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'ukify-call.json').exists())
        self.assertEqual(self.initrd.read_bytes(),b'original initramfs')

    def test_oversized_uki_fails_the_build(self):
        (self.root/'boot/dtbs/test/qcom/x1-test.dtb').write_bytes(b'dtb')
        self.env['UKI_BYTES']=str(256*1024*1024)
        result=self.builder(); self.assertEqual(result.returncode,0,result.stderr)
        self.env['UKI_BYTES']=str(256*1024*1024+1)
        result=self.builder(); self.assertNotEqual(result.returncode,0)
        self.assertIn('over the 268435456 limit',result.stderr)

    def test_no_qualcomm_trees_does_not_rebuild_anything(self):
        result=self.builder(); self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse((self.root/'mkinitcpio-call.json').exists())
        self.assertFalse((self.root/'ukify-call.json').exists())

    def test_staging_preserves_legacy_service_alongside_early_hook(self):
        builder=(ROOT/'builder/build-iso.sh').read_text()
        start=builder.index('  # Keep the existing late-start path')
        end=builder.index('  rm -rf "$build_cache_dir/syslinux"',start)
        block=builder[start:end].replace('/builder/qualcomm/',str(ROOT/'builder/qualcomm')+'/')
        old=('usr/local/bin/omarchy-live-dsp','etc/systemd/system/omarchy-live-dsp.service','etc/systemd/system/multi-user.target.wants/omarchy-live-dsp.service')
        for name in old:
            path=self.root/'airootfs'/name; path.parent.mkdir(parents=True,exist_ok=True); path.write_text('old')
        result=subprocess.run(['bash','-c','build_cache_dir="$TEST_ROOT"\n'+block],env=self.env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.root/'airootfs'/old[0]).read_text(),(ROOT/'builder/qualcomm/omarchy-live-dsp').read_text())
        self.assertEqual((self.root/'airootfs'/old[1]).read_text(),(ROOT/'builder/qualcomm/omarchy-live-dsp.service').read_text())
        self.assertTrue((self.root/'airootfs'/old[2]).is_symlink())
        for name in ('hooks/qcom_early_startup','install/qcom_early_startup','qcom-early-firmware.py','install/omarchy_quiet_efivars'):
            self.assertTrue((self.root/'airootfs/usr/lib/initcpio'/name).is_file())

    def test_install_hook_dependencies_and_failures(self):
        hook=(ROOT/'builder/qualcomm/early-startup-install').read_text()
        helper=self.root/'firmware.py'; helper.write_text("print('qcom/test/adsp.mbn')\n")
        hook=hook.replace('/usr/lib/initcpio/qcom-early-firmware.py',str(helper))
        script=self.root/'install'; script.write_text(hook)
        manifest=self.root/'dtbs'; manifest.write_text('test.dtb\n')
        harness='''
add_module() { echo "module $1"; [ "$1" != "$FAIL_MODULE" ]; }
add_binary() { echo "binary $1"; [ "$1" != "$FAIL_BINARY" ]; }
add_firmware() { echo "firmware $1"; }
add_runscript() { echo RUNSCRIPT; }
warning() { echo "warning $*"; }
error() { echo "error $*"; }
source "$SCRIPT"
build
'''
        env=self.env | {'SCRIPT':str(script),'OMARCHY_QCOM_DTBS_FILE':str(manifest),'FAIL_MODULE':'','FAIL_BINARY':''}
        result=subprocess.run(['bash','-c',harness],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        for module in ('qrtr','qrtr_smd','qcom_pd_mapper','qcom_q6v5_pas','pmic_glink','pmic_glink_altmode','ucsi_glink'):
            self.assertIn('module '+module+'\n',result.stdout)
        self.assertIn('firmware qcom/test/adsp.mbn',result.stdout)
        self.assertIn('RUNSCRIPT',result.stdout)
        for module in ('qrtr','qrtr_smd','qcom_pd_mapper','qcom_q6v5_pas','pmic_glink','pmic_glink_altmode','ucsi_glink'):
            env['FAIL_MODULE']=module
            failed=subprocess.run(['bash','-c',harness],env=env,capture_output=True,text=True)
            self.assertNotEqual(failed.returncode,0)
            self.assertNotIn('RUNSCRIPT',failed.stdout)
        env['FAIL_MODULE']=''
        for binary in ('cat','grep','readlink','sleep','tr'):
            env['FAIL_BINARY']='/usr/bin/'+binary
            failed=subprocess.run(['bash','-c',harness],env=env,capture_output=True,text=True)
            self.assertNotEqual(failed.returncode,0)
            self.assertNotIn('RUNSCRIPT',failed.stdout)
        env['FAIL_BINARY']=''
        helper.write_text('raise RuntimeError("invalid device tree")\n')
        failed=subprocess.run(['bash','-c',harness],env=env,capture_output=True,text=True)
        self.assertNotEqual(failed.returncode,0); self.assertNotIn('RUNSCRIPT',failed.stdout)
        del env['OMARCHY_QCOM_DTBS_FILE']
        failed=subprocess.run(['bash','-c',harness],env=env,capture_output=True,text=True)
        self.assertNotEqual(failed.returncode,0); self.assertNotIn('RUNSCRIPT',failed.stdout)


class ConfiguratorFirmwareTests(unittest.TestCase):
    """Run the configurator's real firmware functions against fixtures."""

    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        (self.root/'bin').mkdir()
        (self.root/'mirror').mkdir()
        self.env=os.environ | {'PATH':str(self.root/'bin')+':'+os.environ['PATH'], 'TEST_ROOT':str(self.root)}
        # Two missing files: one in a folder a maker's package provides, one not.
        self.executable('qcom-firmware-extract','''#!/bin/bash
if [[ $1 == --list-missing ]]; then
  printf '%s\\n' qcom/x1p42100/ASUSTeK/zenbook-14-ux3480qa/qcadsp8380.mbn qcom/x1e80100/VENDOR/laptop/qcadsp8380.mbn
elif [[ $1 == --stage ]]; then
  mkdir -p "$2"; echo staged >"$TEST_ROOT/stage-ran"; : >"$2/manifest"
  for name in ${STAGED:-}; do printf '%s windows\\n' "$name" >>"$2/manifest"; done
fi
''')
        desc=b'%NAME%\nasus-zenbook-14-ux3480qa-firmware\n\n%PROVIDES%\nqcom-firmware-x1p42100-asustek-zenbook-14-ux3480qa=20261106\n\n'
        with tarfile.open(self.root/'mirror/offline.db.tar.gz','w:gz') as tar:
            info=tarfile.TarInfo('asus-zenbook-14-ux3480qa-firmware-20261106-1/desc'); info.size=len(desc)
            tar.addfile(info,io.BytesIO(desc))
        code=(ROOT/'configs/airootfs/root/configurator').read_text()
        functions=''.join(re.search(r'^'+name+r'\(\) \{\n.*?^\}\n', code, re.S|re.M).group(0)
                          for name in ('qualcomm_firmware_uncovered','stage_qualcomm_firmware'))
        for old,new in (('/var/cache/omarchy/mirror/offline',str(self.root/'mirror')),('/run/omarchy',str(self.root/'run/omarchy')),
                        ('/sys/firmware/devicetree/base',str(self.root/'dt'))):
            functions=functions.replace(old,new)
        (self.root/'dt').mkdir()
        self.functions=functions

    def executable(self,name,text):
        path=self.root/'bin'/name; path.write_text(text); path.chmod(0o755)

    def run_bash(self,call):
        stubs='step() { echo "step $*"; }\nsay() { echo "say $*"; }\nt() { echo "$*"; }\n'
        return subprocess.run(['bash','-c',stubs+self.functions+call],env=self.env,capture_output=True,text=True)

    def test_firmware_a_package_covers_is_not_missing(self):
        result=self.run_bash('qualcomm_firmware_uncovered')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,'qcom/x1e80100/VENDOR/laptop/qcadsp8380.mbn\n')

    def test_staging_runs_before_run_omarchy_exists(self):
        self.assertFalse((self.root/'run/omarchy').exists())
        result=self.run_bash('stage_qualcomm_firmware')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('No such file',result.stderr)
        self.assertTrue((self.root/'stage-ran').exists())
        self.assertTrue((self.root/'run/omarchy/firmware-stage.log').exists())

    def test_only_uncovered_firmware_from_windows_counts_as_saved(self):
        covered='qcom/x1p42100/ASUSTeK/zenbook-14-ux3480qa/qcadsp8380.mbn'
        uncovered='qcom/x1e80100/VENDOR/laptop/qcadsp8380.mbn'
        # Windows supplied only the file a package covers: still missing.
        self.env['STAGED']=covered
        result=self.run_bash('stage_qualcomm_firmware')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('firmware.none',result.stdout)
        self.assertNotIn('firmware.saved',result.stdout)
        # Windows supplied the uncovered file: saved.
        (self.root/'run/omarchy/firmware/manifest').unlink()
        self.env['STAGED']=uncovered
        result=self.run_bash('stage_qualcomm_firmware')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('firmware.saved 1',result.stdout)
        self.assertNotIn('firmware.none',result.stdout)


if __name__=='__main__': unittest.main()
