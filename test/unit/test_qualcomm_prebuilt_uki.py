"""Unit tests for the Snapdragon pre-built UKI build and matching logic."""

import json
import re
import struct
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UNIT_DIR = Path(__file__).resolve().parent
if str(UNIT_DIR) not in sys.path:
    sys.path.insert(0, str(UNIT_DIR))
ZENBOOK_CHID = "5b6d366d-9a43-536d-9637-8e47abfb8e63"


def _minimal_dtb(compatibles: list[str]) -> bytes:
    """Build a minimal valid Flattened Device Tree with root `compatible`."""
    prop_name = b"compatible\x00"
    val = b"".join(c.encode("utf-8") + b"\x00" for c in compatibles)
    val_padded = val + b"\x00" * ((4 - len(val) % 4) % 4)
    struct_blk = (
        struct.pack(">I", 1) + b"\x00\x00\x00\x00"  # FDT_BEGIN_NODE ""
        + struct.pack(">III", 3, len(val), 0) + val_padded  # FDT_PROP compatible
        + struct.pack(">II", 2, 9)  # FDT_END_NODE, FDT_END
    )
    rsvmap = struct.pack(">QQ", 0, 0)
    off_rsv = 40
    off_struct = off_rsv + len(rsvmap)
    off_strings = off_struct + len(struct_blk)
    totalsize = off_strings + len(prop_name)
    header = struct.pack(
        ">10I",
        0xD00DFEED, totalsize, off_struct, off_strings, off_rsv,
        17, 16, 0, len(prop_name), len(struct_blk),
    )
    return header + rsvmap + struct_blk + prop_name


class QualcommPrebuiltUkiTests(unittest.TestCase):
    """Snapdragon pre-built UKI matching: standard laptops take it; boards with
    extra hooks, early DSP loading, extra firmware files, BINARIES, pinned
    DeviceTree=, unexpected modprobe/initcpio changes, or missing HWID/CHID
    matches build their own."""

    @classmethod
    def setUpClass(cls):
        orchestrator_root = str(ROOT / "configs/airootfs/usr/share/omarchy-iso")
        cls._added_path = orchestrator_root not in sys.path
        if cls._added_path:
            sys.path.insert(0, orchestrator_root)
            cls.addClassCleanup(lambda: sys.path.remove(orchestrator_root) if orchestrator_root in sys.path else None)
        adapter_name = "orchestrator.archinstall_adapter"
        if adapter_name not in sys.modules:
            sys.modules[adapter_name] = types.ModuleType(adapter_name)
            cls.addClassCleanup(lambda: sys.modules.pop(adapter_name, None))
        from orchestrator import phases_impl
        cls.phases_impl = phases_impl

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "target"
        self.state = self.target / "var/lib/omarchy-iso"
        self.state.mkdir(parents=True)
        self.conf = self.target / "etc/mkinitcpio.conf.d"
        self.conf.mkdir(parents=True)
        self.hwids = self.target / "usr/lib/systemd/boot/hwids/aa64"
        self.hwids.mkdir(parents=True)
        self.modprobe = self.target / "etc/modprobe.d"
        self.modprobe.mkdir(parents=True)
        (self.target / "etc/mkinitcpio.conf").write_text("MODULES=()\n")
        (self.modprobe / "omarchy-usb-autosuspend.conf").write_text("options usbcore autosuspend=-1\n")

        (self.state / "prebuilt-uki-qualcomm.efi").write_bytes(b"MZ")
        (self.state / "prebuilt-uki-qualcomm.modules").write_text(
            "hid_asus\ni2c_hid_of\nasus_glymur_ec\nqrtr\nqcom_pd_mapper\npmic_glink\n"
            "pmic_glink_altmode\nps883x\nphy_nxp_ptn3222\npinctrl_glymur\n"
        )
        (self.state / "prebuilt-uki-qualcomm.files").write_text("qcom/gen80100_sqe.fw\nqcom/gen80100_gmu.bin\n")
        (self.state / "prebuilt-uki-qualcomm.dropins").write_text("00-omarchy-hooks.conf\nomarchy_hooks.conf\n")
        (self.state / "prebuilt-uki-qualcomm.compatibles").write_text("asus,zenbook-a16-ux3607oa\n")
        inputs = self.phases_impl._qualcomm_initramfs_inputs(self.target)
        (self.state / "prebuilt-uki-qualcomm.inputs").write_text(
            "".join(f"{digest}  {rel}\n" for rel, digest in sorted(inputs.items()))
        )

        (self.hwids / "glymur-asus-zenbook-a16-ux3607oa.json").write_text(
            json.dumps({
                "type": "devicetree",
                "name": "ASUS Zenbook A16 UX3607OA",
                "compatible": "asus,zenbook-a16-ux3607oa",
                "hwids": [ZENBOOK_CHID],
            })
        )
        self.compat = Path(self.tmp.name) / "compatible"
        self.compat.write_bytes(b"asus,zenbook-a16-ux3607oa\x00qcom,glymur\x00")
        (self.conf / "qualcomm-platform.conf").write_text("MODULES+=(pinctrl-glymur?)\nHOOKS+=(omarchy-quiet-efivars)\n")
        (self.conf / "zenbook-a16-initramfs.conf").write_text(
            "MODULES+=(hid-asus? i2c-hid-of? asus_glymur_ec? qrtr? qcom_pd_mapper? pmic_glink?\n"
            "  ps883x? pmic_glink_altmode? phy-nxp-ptn3222?)\n"
            "for firmware in qcom/gen80100_sqe.fw qcom/gen80100_gmu.bin; do\n"
            '  FILES+=("$directory/$firmware$suffix")\n'
            "done\n"
        )
        # Standard omarchy-update-qualcomm-device-trees managed uki.conf block.
        uki_conf = self.target / "etc/kernel/uki.conf"
        uki_conf.parent.mkdir(parents=True)
        uki_conf.write_text(
            "# BEGIN OMARCHY QUALCOMM DEVICE TREES\n"
            "[UKI]\n"
            "Stub=/usr/lib/systemd-stub-omarchy/linuxaa64.efi.stub\n"
            "DeviceTree=/boot/dtbs/linux-omarchy/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb\n"
            "DeviceTreeAuto=/boot/dtbs/linux-omarchy/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb\n"
            "# END OMARCHY QUALCOMM DEVICE TREES\n"
        )

    def check(self, platform_name="aarch64-qualcomm", live_chids=None):
        return self.phases_impl._qualcomm_prebuilt_uki(
            self.target,
            platform_name,
            dt_compatible_path=self.compat,
            live_chids={ZENBOOK_CHID} if live_chids is None else live_chids,
        )

    def test_matching_snapdragon_laptop_takes_prebuilt_uki(self):
        self.assertEqual(self.check(), self.state / "prebuilt-uki-qualcomm.efi")

    def test_toprow_modprobe_dropin_is_allowed(self):
        (self.modprobe / "omarchy-toprow.conf").write_text("options hid_asus fnlock_default=0\n")
        self.assertEqual(self.check(), self.state / "prebuilt-uki-qualcomm.efi")

    def test_literal_firmware_path_is_normalized_against_covered_files(self):
        (self.conf / "literal-fw.conf").write_text("FILES+=(/usr/lib/firmware/qcom/gen80100_sqe.fw.zst)\n")
        self.assertEqual(self.check(), self.state / "prebuilt-uki-qualcomm.efi")

    def test_other_platforms_never_take_it(self):
        self.assertIsNone(self.check("aarch64-n1x"))
        self.assertIsNone(self.check(""))

    def test_custom_hook_like_galaxy_book4_edge_builds_its_own(self):
        (self.conf / "samsung-galaxy-book4-edge-14.conf").write_text("HOOKS+=(samsung-galaxy-book4-edge-14)\n")
        self.assertIsNone(self.check())

    def test_early_dsp_module_like_surface_laptop8_builds_its_own(self):
        (self.conf / "surface-laptop8-initramfs.conf").write_text("MODULES+=(qcom_q6v5_pas?)\n")
        self.assertIsNone(self.check())

    def test_binaries_in_board_dropin_builds_its_own(self):
        (self.conf / "board-bin.conf").write_text("BINARIES+=(/usr/bin/custom-tool)\n")
        self.assertIsNone(self.check())

    def test_extra_board_firmware_files_build_their_own(self):
        (self.conf / "surface-pro-11-initramfs.conf").write_text(
            "for firmware in \\\n  qcom/gen80100_sqe.fw \\\n  ath12k/WCN7850/hw2.0/board.bin; do\n"
            '  FILES+=("$directory/$firmware$suffix")\n'
            "done\n"
        )
        self.assertIsNone(self.check())

    def test_unrelated_dollar_var_next_to_covered_loop_builds_its_own(self):
        (self.conf / "mixed-files.conf").write_text(
            "for firmware in qcom/gen80100_sqe.fw; do\n"
            '  FILES+=("$directory/$firmware$suffix")\n'
            "done\n"
            'FILES+=("$zap_path")\n'
        )
        self.assertIsNone(self.check())

    def test_windows_extracted_qcom_firmware_conf_uses_initrd_append_when_valid(self):
        from test_uki_initrd_append import _make_fake_uki

        # Real unsigned PE32+ UKI with trailing .initrd + tiny board zap shader
        (self.state / "prebuilt-uki-qualcomm.efi").write_bytes(_make_fake_uki())
        fw_path = self.target / "usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-14-ux3480qa/qcdxkmsucpurwa.mbn.xz"
        fw_path.parent.mkdir(parents=True, exist_ok=True)
        fw_path.write_bytes(b"ZAP" * 64)
        (self.conf / "qcom-firmware.conf").write_text(
            "_qcom_fw_files=(/usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-14-ux3480qa/qcdxkmsucpurwa.mbn.xz)\n"
            "_qcom_fw_names=(qcom/x1p42100/ASUSTeK/zenbook-14-ux3480qa/qcdxkmsucpurwa.mbn)\n"
        )
        self.assertEqual(self.check(), self.state / "prebuilt-uki-qualcomm.efi")
        resolved = self.phases_impl._qualcomm_qcom_firmware_files(self.target)
        self.assertEqual(
            resolved,
            [("usr/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-14-ux3480qa/qcdxkmsucpurwa.mbn.xz", fw_path)],
        )

        # Signed UKI (cannot append) falls back cleanly to rebuilding
        (self.state / "prebuilt-uki-qualcomm.efi").write_bytes(_make_fake_uki(signed=True))
        self.assertIsNone(self.check())

        # Unrecognized qcom-firmware.conf syntax falls back cleanly to rebuilding
        (self.state / "prebuilt-uki-qualcomm.efi").write_bytes(_make_fake_uki())
        (self.conf / "qcom-firmware.conf").write_text("FILES+=(/usr/lib/firmware/updates/qcom/zap.mbn)\n")
        self.assertIsNone(self.check())

    def test_nested_hwid_subdir_and_quiet_efivars_hook_are_accepted(self):
        # Move HWID JSON into a linux-omarchy/ subdirectory (matching linux-omarchy-dtbs)
        src = self.hwids / "glymur-asus-zenbook-a16-ux3607oa.json"
        nested = self.hwids / "linux-omarchy" / src.name
        nested.parent.mkdir(parents=True, exist_ok=True)
        src.rename(nested)
        # Add the busybox-only omarchy-quiet-efivars install hook written by qualcomm/initramfs.sh
        hook = self.target / "etc/initcpio/install/omarchy-quiet-efivars"
        hook.parent.mkdir(parents=True, exist_ok=True)
        hook.write_text("#!/bin/bash\nbuild() { :; }\n")
        self.assertEqual(self.check(), self.state / "prebuilt-uki-qualcomm.efi")

    def test_adsp_blacklist_and_unexpected_modprobe_build_their_own(self):
        (self.modprobe / "qualcomm-adsp-nofw.conf").write_text("blacklist qcom_q6v5_pas\n")
        self.assertIsNone(self.check())
        (self.modprobe / "qualcomm-adsp-nofw.conf").unlink()
        (self.modprobe / "board-blacklist.conf").write_text("blacklist msm\n")
        self.assertIsNone(self.check())

    def test_modified_mkinitcpio_conf_or_custom_initcpio_hook_builds_its_own(self):
        (self.target / "etc/mkinitcpio.conf").write_text("MODULES=(extra_mod)\n")
        self.assertIsNone(self.check())

    def test_pinned_devicetree_override_builds_its_own(self):
        # DeviceTree= outside the managed block (e.g. Surface Pro 11 / IdeaPad Slim 5x).
        (self.target / "etc/kernel/uki.conf").write_text(
            "[UKI]\nDeviceTree=/boot/dtbs/linux-omarchy/qcom/x1p64100-microsoft-denali.dtb\n"
        )
        self.assertIsNone(self.check())
        # Managed block restored, but uki.conf.d drop-in adds DeviceTree=.
        (self.target / "etc/kernel/uki.conf").write_text(
            "# BEGIN OMARCHY QUALCOMM DEVICE TREES\n[UKI]\n"
            "DeviceTree=/boot/dtbs/linux-omarchy/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb\n"
            "DeviceTreeAuto=/boot/dtbs/linux-omarchy/qcom/glymur-asus-zenbook-a16-ux3607oa.dtb\n"
            "# END OMARCHY QUALCOMM DEVICE TREES\n"
        )
        dropin_dir = self.target / "etc/kernel/uki.conf.d"
        dropin_dir.mkdir(parents=True)
        (dropin_dir / "50-panel.conf").write_text("[UKI]\nDeviceTree=/boot/dtbs/qcom/custom.dtb\n")
        self.assertIsNone(self.check())

    def test_hwid_gate_requires_board_compatible_devicetree_type_baked_dtb_and_chid(self):
        # Missing compatible file.
        self.assertIsNone(
            self.phases_impl._qualcomm_prebuilt_uki(
                self.target, "aarch64-qualcomm",
                dt_compatible_path=Path(self.tmp.name) / "missing",
                live_chids={ZENBOOK_CHID},
            )
        )
        # CHID mismatch.
        self.assertIsNone(self.check(live_chids={"00000000-0000-0000-0000-000000000000"}))
        # Empty CHIDs.
        self.assertIsNone(self.check(live_chids=set()))
        # Board compatible not in baked compatibles list.
        (self.state / "prebuilt-uki-qualcomm.compatibles").write_text("lenovo,yoga-slim7x\n")
        self.assertIsNone(self.check())
        (self.state / "prebuilt-uki-qualcomm.compatibles").write_text("asus,zenbook-a16-ux3607oa\n")
        # SoC-only match must not pass when board-level compatible differs.
        (self.hwids / "soc.json").write_text(json.dumps({
            "type": "devicetree", "compatible": "qcom,glymur", "hwids": [ZENBOOK_CHID],
        }))
        self.compat.write_bytes(b"vendor,unknown-board\x00qcom,glymur\x00")
        self.assertIsNone(self.check())
        self.compat.write_bytes(b"asus,zenbook-a16-ux3607oa\x00qcom,glymur\x00")
        # Malformed JSON is skipped safely; wrong type ("acpi") is rejected.
        (self.hwids / "broken.json").write_text("{not valid json")
        (self.hwids / "glymur-asus-zenbook-a16-ux3607oa.json").write_text(json.dumps({
            "type": "acpi", "compatible": "asus,zenbook-a16-ux3607oa", "hwids": [ZENBOOK_CHID],
        }))
        self.assertIsNone(self.check())

    def test_build_root_image_helpers_and_guards(self):
        code = (ROOT / "builder/build-root-image.sh").read_text()
        mod_fn = re.search(r"^qualcomm_module_names\(\) \{\n.*?^\}\n", code, re.S | re.M).group(0)
        dtb_fn = re.search(r"^qualcomm_dtb_compatibles\(\) \{\n.*?^\}\n", code, re.S | re.M).group(0)
        build_fn = re.search(r"^build_qualcomm_uki_in\(\) \{\n.*?^\}\n", code, re.S | re.M).group(0)

        # qualcomm_module_names strips inline comments, excludes qcom_q6v5_pas, works under set -euo pipefail.
        root = Path(self.tmp.name) / "imgroot"
        hw = root / "usr/share/omarchy/install/hardware/microsoft"
        hw.mkdir(parents=True)
        (hw / "surface-laptop8.sh").write_text(
            "if omarchy-hw-aarch64-qualcomm; then\n"
            '  cat >"$mkinitcpio_dir/surface-laptop8-initramfs.conf" <<\'CONF\'\n'
            "MODULES+=(hid-asus? qcom_q6v5_pas? pmic_glink? # trailing comment word\n)\n"
            "CONF\nfi\n"
        )
        result = subprocess.run(
            ["bash", "-c", f'set -euo pipefail\n{mod_fn}\nqualcomm_module_names "{root}"'],
            capture_output=True, text=True, check=True,
        )
        mods = result.stdout.splitlines()
        self.assertEqual(mods, ["hid_asus", "pmic_glink"])

        # qualcomm_dtb_compatibles extracts root board-level compatible from real FDT binaries.
        dtb_file = Path(self.tmp.name) / "zenbook.dtb"
        dtb_file.write_bytes(_minimal_dtb(["asus,zenbook-a16-ux3607oa", "qcom,glymur"]))
        dtb_res = subprocess.run(
            ["bash", "-c", f'set -euo pipefail\n{dtb_fn}\nqualcomm_dtb_compatibles "{dtb_file}"'],
            capture_output=True, text=True, check=True,
        )
        self.assertEqual(dtb_res.stdout.splitlines(), ["asus,zenbook-a16-ux3607oa"])

        # qualcomm_initramfs_inputs (bash) and _qualcomm_initramfs_inputs (Python) must
        # hash both regular files and symlinks identically.
        inputs_fn = re.search(r"^qualcomm_initramfs_inputs\(\) \{\n.*?^\}\n", code, re.S | re.M).group(0)
        (self.modprobe / "masked.conf").symlink_to("/dev/null")
        sh_inputs = subprocess.run(
            ["bash", "-c", f'set -euo pipefail\n{inputs_fn}\nqualcomm_initramfs_inputs "{self.target}"'],
            capture_output=True, text=True, check=True,
        ).stdout
        py_inputs = "".join(
            f"{digest}  {rel}\n"
            for rel, digest in sorted(self.phases_impl._qualcomm_initramfs_inputs(self.target).items())
        )
        self.assertEqual(py_inputs, sh_inputs)

        # build_qualcomm_uki_in static invariants: excludes -el2 DTBs, passes HWIDs=,
        # checks mkinitcpio exit status, verifies .hwids/.dtbauto with ukify inspect,
        # resolves modinfo inside chroot, and searches updates/ before base dir.
        self.assertIn("*-el2.dtb", build_fn)
        self.assertIn("HWIDs=%s", build_fn)
        self.assertIn("-S autodetect 2>&1 | tail -25 || return 1", build_fn)
        self.assertIn("ukify inspect", build_fn)
        self.assertIn('arch-chroot "$merged" modinfo', build_fn)
        self.assertLess(build_fn.index("for dir in /usr/lib/firmware/updates"), build_fn.index("for suffix in '' .zst .xz"))


if __name__ == "__main__":
    unittest.main()
