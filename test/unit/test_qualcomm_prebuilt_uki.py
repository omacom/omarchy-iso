"""Unit tests for the Snapdragon pre-built UKI build and matching logic."""

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class QualcommPrebuiltUkiTests(unittest.TestCase):
    """Snapdragon pre-built UKI matching: standard laptops take it; boards with
    extra hooks, early DSP loading, extra firmware files or no HWID build their own."""

    def setUp(self):
        import json, sys, types
        sys.path.insert(0, str(ROOT/'configs/airootfs/usr/share/omarchy-iso'))
        sys.modules.setdefault('orchestrator.archinstall_adapter', types.ModuleType('orchestrator.archinstall_adapter'))
        from orchestrator import phases_impl
        self.phases_impl=phases_impl
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.target=Path(self.tmp.name)/'target'
        self.state=self.target/'var/lib/omarchy-iso'; self.state.mkdir(parents=True)
        self.conf=self.target/'etc/mkinitcpio.conf.d'; self.conf.mkdir(parents=True)
        self.hwids=self.target/'usr/lib/systemd/boot/hwids/aa64'; self.hwids.mkdir(parents=True)
        (self.state/'prebuilt-uki-qualcomm.efi').write_bytes(b'MZ')
        (self.state/'prebuilt-uki-qualcomm.modules').write_text(
            'hid_asus\ni2c_hid_of\nasus_glymur_ec\nqrtr\nqcom_pd_mapper\npmic_glink\npmic_glink_altmode\nps883x\nphy_nxp_ptn3222\npinctrl_glymur\n'
        )
        (self.state/'prebuilt-uki-qualcomm.files').write_text('qcom/gen80100_sqe.fw\nqcom/gen80100_gmu.bin\n')
        (self.hwids/'glymur-asus-zenbook-a16-ux3607oa.json').write_text(
            json.dumps({'compatible':'asus,zenbook-a16-ux3607oa'})
        )
        self.compat=Path(self.tmp.name)/'compatible'
        self.compat.write_bytes(b'asus,zenbook-a16-ux3607oa\x00qcom,glymur\x00')
        (self.conf/'qualcomm-platform.conf').write_text('MODULES+=(pinctrl-glymur?)\nHOOKS+=(omarchy-quiet-efivars)\n')
        (self.conf/'zenbook-a16-initramfs.conf').write_text(
            'MODULES+=(hid-asus? i2c-hid-of? asus_glymur_ec? qrtr? qcom_pd_mapper? pmic_glink?\n'
            '  ps883x? pmic_glink_altmode? phy-nxp-ptn3222?)\n'
            'for firmware in qcom/gen80100_sqe.fw qcom/gen80100_gmu.bin; do\n'
            '  FILES+=("$directory/$firmware$suffix")\n'
            'done\n'
        )

    def check(self, platform_name='aarch64-qualcomm'):
        return self.phases_impl._qualcomm_prebuilt_uki(self.target, platform_name, dt_compatible_path=self.compat)

    def test_matching_snapdragon_laptop_takes_prebuilt_uki(self):
        self.assertEqual(self.check(), self.state/'prebuilt-uki-qualcomm.efi')

    def test_other_platforms_never_take_it(self):
        self.assertIsNone(self.check('aarch64-n1x'))
        self.assertIsNone(self.check(''))

    def test_custom_hook_like_galaxy_book4_edge_builds_its_own(self):
        (self.conf/'samsung-galaxy-book4-edge-14.conf').write_text('HOOKS+=(samsung-galaxy-book4-edge-14)\n')
        self.assertIsNone(self.check())

    def test_early_dsp_module_like_surface_laptop8_builds_its_own(self):
        (self.conf/'surface-laptop8-initramfs.conf').write_text('MODULES+=(qcom_q6v5_pas?)\n')
        self.assertIsNone(self.check())

    def test_extra_board_firmware_files_build_their_own(self):
        (self.conf/'surface-pro-11-initramfs.conf').write_text(
            'for firmware in \\\n  qcom/gen80100_sqe.fw \\\n  ath12k/WCN7850/hw2.0/board.bin; do\n'
            '  FILES+=("$directory/$firmware$suffix")\n'
            'done\n'
        )
        self.assertIsNone(self.check())

    def test_windows_extracted_qcom_firmware_conf_builds_its_own(self):
        (self.conf/'qcom-firmware.conf').write_text('FILES+=(/usr/lib/firmware/updates/qcom/zap.mbn)\n')
        self.assertIsNone(self.check())

    def test_adsp_blacklist_modprobe_builds_its_own(self):
        modprobe=self.target/'etc/modprobe.d'; modprobe.mkdir(parents=True)
        (modprobe/'qualcomm-adsp-nofw.conf').write_text('blacklist qcom_q6v5_pas\n')
        self.assertIsNone(self.check())

    def test_missing_hwid_entry_builds_its_own(self):
        self.compat.write_bytes(b'vendor,unknown-board\x00qcom,glymur\x00')
        self.assertIsNone(self.check())

    def test_build_root_image_qualcomm_module_names_excludes_qcom_q6v5_pas(self):
        code=(ROOT/'builder/build-root-image.sh').read_text()
        fn=re.search(r'^qualcomm_module_names\(\) \{\n.*?^\}\n', code, re.S|re.M).group(0)
        root=Path(self.tmp.name)/'imgroot'
        hw=root/'usr/share/omarchy/install/hardware/microsoft'; hw.mkdir(parents=True)
        (hw/'surface-laptop8.sh').write_text(
            'if omarchy-hw-aarch64-qualcomm; then\n'
            '  cat >"$mkinitcpio_dir/surface-laptop8-initramfs.conf" <<\'CONF\'\n'
            'MODULES+=(hid-asus? qcom_q6v5_pas? pmic_glink?)\n'
            'CONF\nfi\n'
        )
        result=subprocess.run(['bash','-c',f'{fn}\nqualcomm_module_names "{root}"'],capture_output=True,text=True,check=True)
        mods=result.stdout.splitlines()
        self.assertIn('hid_asus', mods)
        self.assertIn('pmic_glink', mods)
        self.assertNotIn('qcom_q6v5_pas', mods)


if __name__=='__main__': unittest.main()
