"""EFI registration must preserve other installations with the same label."""
from pathlib import Path
import subprocess
import sys
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault("orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter"))
from orchestrator import phases_impl as phases

UUID = "75678080-f412-4035-8b3c-da1a8a2f9d2d"
OTHER = "e67c3a69-d060-48b6-992e-307a580f0257"
LOADER = r"\EFI\limine\limine_aa64.efi"

def entry(uuid=UUID, loader=LOADER, label="Limine", part=3):
    return f"{label}\tHD({part},GPT,{uuid},0x800,0x400000)/File({loader})"

class LimineEFIEntriesTest(unittest.TestCase):
    def setUp(self):
        self.before = {"entries": {
            "0001": "ubuntu", "0002": entry(),
            "0003": entry(OTHER), "0004": entry(loader=r"\EFI\backup\limine.efi"),
            "0005": entry(label="Limine backup"),
        }, "order": ["0002", "0003", "0001", "0004", "0005", "FFFF"]}
        self.after = {"entries": {**self.before["entries"], "0006": entry()}, "order": []}

    def run_registration(self, run=None):
        with mock.patch.object(phases, "capture", return_value=types.SimpleNamespace(stdout=f"3 {UUID}\n")), \
             mock.patch.object(phases, "_read_efibootmgr", return_value=self.after), \
             mock.patch.object(phases.subprocess, "run", side_effect=run) as calls:
            phases._register_limine_efi_entry(Path("/dev/nvme0n1"), 3, LOADER, pre_state=self.before)
            return [call.args[0] for call in calls.call_args_list]

    def test_only_replace_same_partition_and_loader_after_creation(self):
        calls = self.run_registration()
        self.assertIn("--create", calls[0])
        deleted = [c[2] for c in calls if "--delete-bootnum" in c]
        self.assertEqual(deleted, ["0002"])
        self.assertEqual(calls[-1], ["efibootmgr", "--bootorder", "0006,0003,0001,0004,0005"])

    def test_creation_failure_does_not_delete_existing_entries(self):
        calls = []
        def fail(command, **kwargs):
            calls.append(command)
            raise subprocess.CalledProcessError(1, command)
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_registration(fail)
        self.assertEqual(len(calls), 1)
        self.assertIn("--create", calls[0])

    def test_another_disks_limine_does_not_count_as_success(self):
        self.after = {"entries": {"0003": entry(OTHER)}, "order": []}
        with self.assertRaisesRegex(RuntimeError, "target EFI loader"):
            self.run_registration()

    def test_firmware_can_reuse_exact_existing_entry(self):
        self.after = self.before
        calls = self.run_registration()
        self.assertFalse(any("--delete-bootnum" in c for c in calls))
        self.assertEqual(calls[-1][-1], "0002,0003,0001,0004,0005")

    def test_plain_path_mbr_and_different_path_prefix(self):
        entries = {
            "0001": f"Limine\tHD(2,MBR,0x1234abcd,0x800,0x400000)/{LOADER}",
            "0002": f"Limine\tHD(2,MBR,0x1234abcd,0x800,0x400000)/\\backup{LOADER}",
        }
        self.assertEqual(phases._find_limine_target_entries(entries, "1234abcd-02", 2, LOADER), ["0001"])

if __name__ == "__main__":
    unittest.main()
