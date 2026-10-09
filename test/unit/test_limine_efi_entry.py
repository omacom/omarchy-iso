"""Unit tests for _register_limine_efi_entry against a fake efibootmgr.

The fake keeps NVRAM in a JSON file and behaves like efibootmgr 18: a listing
prints each entry's device path after its label, --create takes the lowest free
number and puts it first in BootOrder, --delete-bootnum frees the number again.
A fake lsblk answers the ESP's partition GUID.

The case that matters: a free-space install next to an existing Omarchy must
not delete the other install's "Limine" entry, nor take the first "Limine"
entry in the list as its own.
"""

import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402

OURS = "8e3f52b7-f024-4125-bd27-696adc846a21"
OTHER = "3c105dda-1eb6-4c87-9669-a4c3b6f1b95f"
WINDOWS = "7a511e2f-439f-4c01-81e3-3687d4a7d72f"
LOADER = "\\EFI\\limine\\limine_x64.efi"

FAKE_EFIBOOTMGR = r'''#!/usr/bin/env python3
import json, os, sys
path = os.environ["FAKE_NVRAM"]
nvram = json.load(open(path))
args = sys.argv[1:]
if not args:
    print("BootCurrent: 0001")
    print("BootOrder: " + ",".join(nvram["order"]))
    for num, (label, dp) in sorted(nvram["entries"].items()):
        print(f"Boot{num}* {label}\t{dp}")
    sys.exit(0)
if "--create" in args:
    get = lambda flag: args[args.index(flag) + 1]
    guids = json.loads(os.environ["FAKE_GUIDS"])
    guid = guids[f'{get("--disk")}:{get("--part")}']
    num = next(f"{n:04X}" for n in range(0x10000) if f"{n:04X}" not in nvram["entries"])
    nvram["entries"][num] = [get("--label"), f'HD({get("--part")},GPT,{guid},0x800,0x400000)/{get("--loader")}']
    nvram["order"].insert(0, num)
elif "--delete-bootnum" in args:
    num = args[args.index("--bootnum") + 1]
    del nvram["entries"][num]
    nvram["order"] = [n for n in nvram["order"] if n != num]
elif "--bootorder" in args:
    nvram["order"] = args[args.index("--bootorder") + 1].split(",")
json.dump(nvram, open(path, "w"))
'''

FAKE_LSBLK = r'''#!/usr/bin/env python3
import json, os, sys
dev = sys.argv[-1]
for key, guid in json.loads(os.environ["FAKE_GUIDS"]).items():
    disk, part = key.rsplit(":", 1)
    if "PARTN,PARTUUID" in sys.argv and disk == dev:
        print(part, guid)
    elif "PARTUUID" in sys.argv and dev == f"{disk}p{part}":
        print(guid)
'''

FAKE_FINDMNT = r'''#!/usr/bin/env python3
import os
print(os.environ.get("FAKE_ESP_SOURCE", ""))
'''


class RegisterLimineEfiEntryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(self.tmp)], check=False))
        bin_dir = self.tmp / "bin"
        bin_dir.mkdir()
        for name, text in (("efibootmgr", FAKE_EFIBOOTMGR), ("lsblk", FAKE_LSBLK), ("findmnt", FAKE_FINDMNT)):
            (bin_dir / name).write_text(text)
            (bin_dir / name).chmod(0o755)
        self.nvram = self.tmp / "nvram.json"
        env = {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_NVRAM": str(self.nvram),
            "FAKE_GUIDS": json.dumps({
                "/dev/nvme1n1:3": OURS,
                "/dev/nvme1n1:1": OTHER,
                "/dev/nvme0n1:1": WINDOWS,
            }),
            "FAKE_ESP_SOURCE": "/dev/nvme1n1p3",
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)

    def nvram_with(self, entries, order):
        self.nvram.write_text(json.dumps({"entries": entries, "order": order}))

    def entry(self, label, guid, part=1, loader=LOADER):
        return [label, f"HD({part},GPT,{guid},0x800,0x400000)/{loader}"]

    def register(self):
        phases_impl._register_limine_efi_entry(Path("/dev/nvme1n1"), 3, LOADER)
        return json.loads(self.nvram.read_text())

    def limine_guids(self, nvram):
        return {num: dp for num, (label, dp) in nvram["entries"].items() if label == "Limine"}

    def test_another_installs_entry_survives_behind_ours(self):
        self.nvram_with(
            {
                "0000": self.entry("Windows Boot Manager", WINDOWS, loader="\\EFI\\Microsoft\\Boot\\bootmgfw.efi"),
                "0004": self.entry("Limine", OTHER),
            },
            ["0004", "0000"],
        )
        nvram = self.register()
        limine = self.limine_guids(nvram)
        self.assertEqual(len(limine), 2, nvram)
        ours = next(num for num, dp in limine.items() if OURS in dp)
        self.assertEqual(nvram["order"], [ours, "0004", "0000"])

    def test_this_esps_old_entry_is_replaced(self):
        self.nvram_with(
            {
                "0000": self.entry("Windows Boot Manager", WINDOWS),
                "0003": self.entry("Limine", OURS, part=3),
                "0004": self.entry("Limine", OTHER),
            },
            ["0000", "0004", "0003"],
        )
        nvram = self.register()
        limine = self.limine_guids(nvram)
        self.assertEqual(len([dp for dp in limine.values() if OURS in dp]), 1, nvram)
        self.assertIn("0004", limine)
        ours = next(num for num, dp in limine.items() if OURS in dp)
        self.assertEqual(nvram["order"], [ours, "0000", "0004"])

    def test_the_created_entry_is_ours_even_when_listed_after_another(self):
        # The fake reuses the lowest free number: with 0000 taken by another
        # install's "Limine", ours becomes 0001, and the first "Limine" in the
        # listing is not ours.
        self.nvram_with({"0000": self.entry("Limine", OTHER)}, ["0000"])
        nvram = self.register()
        self.assertEqual(nvram["order"][0], "0001")
        self.assertIn(OURS, nvram["entries"]["0001"][1])
        self.assertEqual(nvram["order"], ["0001", "0000"])

    def test_created_entry_reusing_a_deleted_number_is_found(self):
        self.nvram_with({"0000": self.entry("Limine", OURS, part=3)}, ["0000"])
        nvram = self.register()
        self.assertEqual(nvram["order"], ["0000"])
        self.assertIn(OURS, nvram["entries"]["0000"][1])


    def test_boot_check_does_not_count_another_installs_entry(self):
        # validate_boot: our entry was dropped and no fallback was deployed.
        # The other install's "Limine" entry must not pass for ours.
        esp = self.tmp / "esp"
        esp.mkdir()
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        with mock.patch.object(phases_impl, "error", lambda _message: None):
            with self.assertRaises(RuntimeError):
                phases_impl._validate_uefi_boot_routes(esp)
            self.nvram_with({"0004": self.entry("Limine", OTHER), "0005": self.entry("Limine", OURS, part=3)}, ["0005", "0004"])
            phases_impl._validate_uefi_boot_routes(esp)


if __name__ == "__main__":
    unittest.main()
