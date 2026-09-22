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
    return f"{label}\tHD({part},GPT,{uuid},0x800,0x400000)/{loader}"

class LimineEFIEntriesTest(unittest.TestCase):
    def setUp(self):
        self.before = {"entries": {
            "0001": "ubuntu", "0002": entry().upper(),
            "0003": entry(OTHER), "0004": entry(loader=r"\EFI\backup\limine.efi"),
            "0005": entry(label="Limine backup"),
        }, "order": ["0002", "0003", "0001", "0004", "0005", "FFFF"]}
        self.after = {"entries": {**self.before["entries"], "0006": entry()}, "order": []}

    def run_registration(self, run=None):
        with mock.patch.object(phases, "_read_efibootmgr", return_value=self.after), \
             mock.patch.object(phases, "info"), \
             mock.patch.object(phases.subprocess, "run", side_effect=run) as calls:
            phases._register_limine_efi_entry(Path("/dev/nvme0n1"), 3, LOADER, pre_state=self.before)
            return [call.args[0] for call in calls.call_args_list]

    def deleted(self, calls):
        return [c[2] for c in calls if "--delete-bootnum" in c]

    def test_only_exact_duplicates_are_replaced_after_creation(self):
        calls = self.run_registration()
        self.assertIn("--create", calls[0])
        # 0003 is another disk's Limine entry with the same label and loader.
        self.assertEqual(self.deleted(calls), ["0002"])
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

    def test_failed_cleanup_does_not_abort_installation(self):
        def run(command, **kwargs):
            return types.SimpleNamespace(returncode=1 if "--delete-bootnum" in command else 0)
        calls = self.run_registration(run)
        self.assertEqual(self.deleted(calls), ["0002"])
        self.assertEqual(calls[-1][-1], "0006,0003,0001,0004,0005")

    def test_label_only_listing_deletes_nothing(self):
        self.before["entries"] = {"0002": "Limine", "0003": "Limine"}
        self.after = {"entries": {**self.before["entries"], "0006": "Limine"}, "order": []}
        calls = self.run_registration()
        self.assertEqual(self.deleted(calls), [])

    def test_reused_entry_is_left_in_place(self):
        self.after = self.before
        calls = self.run_registration()
        self.assertEqual(len(calls), 1)
        self.assertIn("--create", calls[0])

if __name__ == "__main__":
    unittest.main()
