#!/usr/bin/env python3
"""Run the real UKI builder and mkinitcpio hook with isolated file fixtures."""
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
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
 pathlib.Path(next(x.split('=',1)[1] for x in args if x.startswith('--output='))).write_bytes(b'UKI')
else:
 args=json.loads((root/'ukify-call.json').read_text()); print('.hwids:')
 for arg in args:
  if arg.startswith('--devicetree-auto='): print('.dtbauto:')
''')
        return subprocess.run([str(self.root/'bin/builder'),'test'],env=self.env,capture_output=True,text=True)

    def test_dedicated_initramfs_keeps_direct_boot_untouched(self):
        dtb_root=self.root/'boot/dtbs/test/qcom'
        for name in ('x1-test.dtb','glymur-test.dtb','x1-test-el2.dtb','sm8550-test.dtb'):
            (dtb_root/name).write_bytes(b'dtb')
        result=self.builder(); self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.initrd.read_bytes(),b'original initramfs')
        call=json.loads((self.root/'mkinitcpio-call.json').read_text())
        self.assertIn('qcom_early_startup',call['args'])
        self.assertEqual(call['args'][call['args'].index('-c')+1],str(self.config))
        self.assertIn('x1-test.dtb',call['dtbs']); self.assertIn('glymur-test.dtb',call['dtbs'])
        self.assertNotIn('el2',call['dtbs']); self.assertNotIn('sm8550',call['dtbs'])
        self.assertFalse(Path(call['args'][call['args'].index('-g')+1]).exists())

    def test_failed_initramfs_cannot_produce_uki(self):
        (self.root/'boot/dtbs/test/qcom/x1-test.dtb').touch()
        self.env['FAIL_MKINITCPIO']='1'
        result=self.builder(); self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.root/'ukify-call.json').exists())
        self.assertEqual(self.initrd.read_bytes(),b'original initramfs')

    def test_no_qualcomm_trees_does_not_rebuild_anything(self):
        result=self.builder(); self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse((self.root/'mkinitcpio-call.json').exists())
        self.assertFalse((self.root/'ukify-call.json').exists())

    def test_staging_removes_cached_late_start_service(self):
        builder=(ROOT/'builder/build-iso.sh').read_text()
        start=builder.index('  # A reused profile must not retain')
        end=builder.index('  rm -rf "$build_cache_dir/syslinux"',start)
        block=builder[start:end].replace('/builder/qualcomm/',str(ROOT/'builder/qualcomm')+'/')
        old=('usr/local/bin/omarchy-live-dsp','etc/systemd/system/omarchy-live-dsp.service','etc/systemd/system/multi-user.target.wants/omarchy-live-dsp.service')
        for name in old:
            path=self.root/'airootfs'/name; path.parent.mkdir(parents=True,exist_ok=True); path.write_text('old')
        result=subprocess.run(['bash','-c','build_cache_dir="$TEST_ROOT"\n'+block],env=self.env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        for name in old: self.assertFalse((self.root/'airootfs'/name).exists())
        for name in ('hooks/qcom_early_startup','install/qcom_early_startup','qcom-early-firmware.py'):
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
        for binary in ('cat','grep','readlink','sleep'):
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


if __name__=='__main__': unittest.main()
