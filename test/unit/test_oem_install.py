"""OEM media must choose a safe, unique target and never ask for input."""

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SELECTOR = ROOT / "configs/airootfs/usr/share/omarchy-iso/oem-disk.py"
spec = importlib.util.spec_from_file_location("oem_disk", SELECTOR)
oem = importlib.util.module_from_spec(spec)
spec.loader.exec_module(oem)


def disk(path="/dev/nvme0n1", **overrides):
    return dict(path=path, type="disk", size=128 * 1024**3,
                ro=False, rm=False, hotplug=False, tran="nvme",
                mountpoints=[None], subsystems="block:nvme:pci") | overrides


class OemDiskTest(unittest.TestCase):
    def test_one_internal_disk_alongside_usb_iso_and_other_media(self):
        usb = disk("/dev/sda") | {"tran": "usb"}
        optical = disk("/dev/sr0") | {"type": "rom"}
        loop = disk("/dev/loop0") | {"type": "loop"}
        self.assertEqual(oem.select_disk([usb, optical, loop, disk()]), "/dev/nvme0n1")

    def test_zero_or_multiple_internal_disks_halt(self):
        for devices in ([], [disk(), disk("/dev/nvme1n1")]):
            with self.subTest(devices=devices), self.assertRaises(ValueError):
                oem.select_disk(devices)

    def test_read_only_removable_hotplug_external_and_small_disks_are_refused(self):
        for override in ({"ro": True}, {"rm": True}, {"hotplug": True},
                         {"tran": "usb"}, {"tran": "ieee1394"},
                         {"size": oem.MIN_DISK_BYTES - 1}):
            with self.subTest(override=override), self.assertRaises(ValueError):
                oem.select_disk([disk() | override])

    def test_mounted_disk_boot_media_ventoy_and_swap_are_refused(self):
        for mount in ("/run/archiso/bootmnt", "/mnt", "[SWAP]"):
            device = disk() | {"children": [{"mountpoints": [None], "children": [
                {"mountpoints": [mount]}
            ]}]}
            with self.subTest(mount=mount), self.assertRaises(ValueError):
                oem.select_disk([device])

    def test_existing_unmounted_partitions_can_be_overwritten(self):
        device = disk() | {"children": [{"mountpoints": [None], "type": "part"}]}
        self.assertEqual(oem.select_disk([device]), "/dev/nvme0n1")

    def test_software_network_and_unknown_devices_cannot_be_the_install_target(self):
        for override in ({"path": "/dev/nbd0", "tran": None, "subsystems": "block"},
                         {"path": "/dev/zram0", "tran": None, "subsystems": "block"},
                         {"subsystems": None}, {"subsystems": "block:nvme"},
                         {"tran": "iscsi"}, {"tran": "fc"},
                         {"tran": None, "subsystems": "block:scsi:usb:pci"}):
            with self.subTest(override=override), self.assertRaises(ValueError):
                oem.select_disk([disk() | override])

    def test_locally_attached_storage_including_virtio_and_arm_is_supported(self):
        for transport, subsystems in ((None, "block:virtio:pci"), ("sata", "block:scsi:pci"),
                                      (None, "block:scsi:platform")):
            with self.subTest(transport=transport, subsystems=subsystems):
                self.assertEqual(oem.select_disk([disk() | {"tran": transport, "subsystems": subsystems}]),
                                 "/dev/nvme0n1")

    def test_internal_emmc_installs_alone_but_counts_against_another_internal_disk(self):
        emmc = disk("/dev/mmcblk0") | {"tran": "mmc", "subsystems": "block:mmc:mmc_host:platform"}
        with tempfile.TemporaryDirectory() as tmp:
            sysfs = Path(tmp)
            card_type = sysfs / "mmcblk0/device/type"
            card_type.parent.mkdir(parents=True)
            card_type.write_text("MMC\n")
            self.assertEqual(oem.select_disk([emmc], sysfs), "/dev/mmcblk0")
            with self.assertRaises(ValueError):
                oem.select_disk([emmc, disk()], sysfs)
            # Missing transport metadata still must not hide an internal eMMC.
            with self.assertRaises(ValueError):
                oem.select_disk([emmc | {"tran": None}, disk()], sysfs)

    def test_sd_card_in_internal_reader_is_excluded_even_when_not_removable(self):
        card = disk("/dev/mmcblk0") | {"tran": "mmc", "subsystems": "block:mmc:mmc_host:platform"}
        with tempfile.TemporaryDirectory() as tmp:
            sysfs = Path(tmp)
            card_type = sysfs / "mmcblk0/device/type"
            card_type.parent.mkdir(parents=True)
            card_type.write_text("SD\n")
            self.assertEqual(oem.select_disk([card, disk()], sysfs), "/dev/nvme0n1")
            with self.assertRaises(ValueError):
                oem.select_disk([card], sysfs)

    def test_unknown_mmc_card_type_halts_instead_of_hiding_a_possible_second_disk(self):
        card = disk("/dev/mmcblk0") | {"tran": "mmc", "subsystems": "block:mmc:mmc_host:platform"}
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                oem.select_disk([card, disk()], Path(tmp))

    def test_lsblk_preserves_mounted_descendants_without_the_name_column(self):
        internal = disk() | {"children": [{"path": "/dev/nvme0n1p1", "type": "part",
                                            "mountpoints": ["/run/archiso/bootmnt"]}]}

        def run(command, **kwargs):
            if command[0] == "udevadm":
                return subprocess.CompletedProcess(command, 0)
            # lsblk only emits children with NAME in its output or --tree.
            if "--tree" in command or "NAME" in command[-1].split(","):
                devices = [internal]
            else:
                devices = [disk(), *internal["children"]]
            return subprocess.CompletedProcess(command, 0, json.dumps({"blockdevices": devices}))

        with patch.object(oem.subprocess, "run", side_effect=run), self.assertRaises(ValueError):
            oem.main()


class OemConfiguratorTest(unittest.TestCase):
    def run_configurator(self, directory, *, marker=True, selection_status=0):
        source = (ROOT / "configs/airootfs/root/configurator").read_text()
        flow = source[source.index('defer_provisioning=false\ninstall_target="full_disk"'):]
        marker_file = directory / "oem-install"
        if marker:
            marker_file.touch()
        flow = flow.replace("/usr/share/omarchy-iso/oem-install", str(marker_file))
        # Exercise the actual OEM control flow and full-disk JSON writer. Any
        # accidental interactive call fails, with stdin closed as on the rig.
        prelude = f'''
language=en
iso_arch=x86_64
limine_efi_binary=limine_x64.efi
OMARCHY_RUNTIME_PACKAGE=omarchy
OMARCHY_SETTINGS_PACKAGE=omarchy-settings
archinstall_custom_servers='{{"url":"https://example.invalid/$repo/os/$arch"}}'
wait_for_stable_terminal() {{ :; }}
i18n_console_font() {{ :; }}
clear_logo() {{ :; }}
say() {{ :; }}
stage_qualcomm_firmware() {{ :; }}
clear() {{ :; }}
greeter() {{ exit 99; }}
language_form() {{ exit 99; }}
keyboard_form() {{ exit 99; }}
user_step() {{ exit 99; }}
disk_form() {{ exit 99; }}
confirm_disk_overwrite() {{ exit 99; }}
detect_kernel() {{ echo linux-omarchy; }}
python3() {{ echo /dev/nvme0n1; return {selection_status}; }}
lsblk() {{ echo 137438953472; }}
write_user_files() {{ echo "$encrypt_installation" >user_encrypt_installation.txt; echo '{{"users":[]}}' >user_credentials.json; }}
'''
        return subprocess.run(["bash", "-c", prelude + flow, "configurator", "--oem"],
                              cwd=directory, stdin=subprocess.DEVNULL, capture_output=True, text=True)

    def test_oem_writes_encrypted_full_disk_deferred_owner_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            result = self.run_configurator(directory)
            self.assertEqual(result.returncode, 0, result.stderr)
            config = json.loads((directory / "user_configuration.json").read_text())
            self.assertTrue(config["omarchy_install"]["defer_provisioning"])
            self.assertEqual(config["omarchy_install"]["mode"], "full_disk")
            target = config["disk_config"]["device_modifications"][0]
            self.assertEqual(target["device"], "/dev/nvme0n1")
            self.assertTrue(target["wipe"])
            self.assertEqual(config["disk_config"]["disk_encryption"]["encryption_type"], "luks")
            self.assertNotIn("encryption_password", config["disk_config"]["disk_encryption"])
            self.assertEqual(config["hostname"], "omarchy")
            self.assertEqual(config["timezone"], "UTC")

    def test_missing_oem_marker_or_failed_disk_selection_writes_no_configuration(self):
        for options in ({"marker": False}, {"selection_status": 1}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as tmp:
                directory = Path(tmp)
                self.assertNotEqual(self.run_configurator(directory, **options).returncode, 0)
                self.assertFalse((directory / "user_configuration.json").exists())


if __name__ == "__main__":
    unittest.main()
