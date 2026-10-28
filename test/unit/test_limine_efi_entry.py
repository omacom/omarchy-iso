"""Unit tests for _register_limine_efi_entry against a fake efibootmgr.

The fake keeps NVRAM in a JSON file and behaves like efibootmgr 18: a listing
(plain or --verbose, as the orchestrator asks) prints each entry's device path
after its label and a "*" on active ones, --create takes the lowest free
number and puts it first in BootOrder, --delete-bootnum frees the number again,
--bootnext refuses a number that has no entry. Every call is logged, and the
fake can stand in for firmware that refuses a create, has no room left in
NVRAM, or answers a create of an existing option with that option.
A fake lsblk answers the ESP's partition GUID.

The case that matters: a free-space install next to an existing Omarchy must
not delete the other install's "Limine" entry, nor take the first "Limine"
entry in the list as its own. And a reinstall onto the same ESP keeps the
entry that already boots it: nothing is deleted to make way for a new one.
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
args = sys.argv[1:]
with open(path + ".log", "a") as log:
    log.write(json.dumps(args) + "\n")
# FAKE_NO_EFIVARS: a kernel without EFI runtime services (efi=noruntime, or
# firmware that faulted and had them turned off), as efibootmgr 18 reports it.
if os.environ.get("FAKE_NO_EFIVARS"):
    print("EFI variables are not supported on this system.", file=sys.stderr)
    sys.exit(2)
nvram = json.load(open(path))
if args in ([], ["--verbose"], ["-v"]):
    if "next" in nvram:
        print("BootNext: " + nvram["next"])
    print("BootCurrent: 0001")
    print("BootOrder: " + ",".join(nvram["order"]))
    for num, (label, dp, *flags) in sorted(nvram["entries"].items()):
        # The "*" marks an active option; an entry listed as
        # [label, path, "inactive"] has it cleared.
        star = " " if "inactive" in flags else "*"
        # FAKE_NO_PATHS: an efibootmgr that lists labels only.
        print(f"Boot{num}{star} {label}" if os.environ.get("FAKE_NO_PATHS") else f"Boot{num}{star} {label}\t{dp}")
    sys.exit(0)
if "--create" in args and os.environ.get("FAKE_REFUSE_CREATE"):
    print("Could not prepare Boot variable: Invalid argument", file=sys.stderr)
    sys.exit(2)
if "--delete-bootnum" in args and os.environ.get("FAKE_REFUSE_DELETE"):
    print("Could not delete variable: Permission denied", file=sys.stderr)
    sys.exit(3)
if "--create" in args:
    get = lambda flag: args[args.index(flag) + 1]
    guids = json.loads(os.environ["FAKE_GUIDS"])
    guid = guids[f'{get("--disk")}:{get("--part")}']
    created = [get("--label"), f'HD({get("--part")},GPT,{guid},0x800,0x400000)/{get("--loader")}']
    # FAKE_SLOTS: an NVRAM store with room for that many boot options.
    if len(nvram["entries"]) >= int(os.environ.get("FAKE_SLOTS", "65536")):
        print("Could not prepare Boot variable: No space left on device", file=sys.stderr)
        sys.exit(28)
    # FAKE_REUSE: firmware that keeps one option per device path and loader
    # answers a create of an existing one with that one, writing nothing.
    if not (os.environ.get("FAKE_REUSE") and created in nvram["entries"].values()):
        num = next(f"{n:04X}" for n in range(0x10000) if f"{n:04X}" not in nvram["entries"])
        nvram["entries"][num] = created
        nvram["order"].insert(0, num)
elif "--delete-bootnum" in args:
    num = args[args.index("--bootnum") + 1]
    del nvram["entries"][num]
    nvram["order"] = [n for n in nvram["order"] if n != num]
elif "--bootorder" in args:
    nvram["order"] = args[args.index("--bootorder") + 1].split(",")
elif "--bootnext" in args:
    num = args[args.index("--bootnext") + 1]
    if os.environ.get("FAKE_REFUSE_BOOTNEXT") or num not in nvram["entries"]:
        print("Could not set BootNext: Invalid argument", file=sys.stderr)
        sys.exit(5)
    nvram["next"] = num
json.dump(nvram, open(path, "w"))
# FAKE_NON_UTF8: firmware whose legacy entries carry raw bytes. efibootmgr
# prints the boot list after every write (test_command_capture.py has the
# bytes from a real machine), and its own messages come through stderr.
if os.environ.get("FAKE_NON_UTF8"):
    sys.stdout.buffer.write(b"Boot0000* Notebook Hard Drive\tBBS(HD,\x80\x7f\xff\x04\xe0\x7f,)\n")
    sys.stderr.buffer.write(b"efibootmgr: \xff\xfe\n")
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

    def calls(self):
        log = Path(str(self.nvram) + ".log")
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def writes(self):
        """The efibootmgr calls that change NVRAM, by their action flag."""
        actions = ("--create", "--delete-bootnum", "--bootorder", "--bootnext")
        return [next(flag for flag in actions if flag in args) for args in self.calls()
                if any(flag in args for flag in actions)]

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

    def test_a_reinstall_onto_the_same_esp_reuses_its_entry(self):
        # 0003 already starts this loader from this ESP, which is exactly the
        # entry a create would add. It is reused: nothing is created or
        # deleted, and BootOrder and BootNext point at it.
        old = {
            "0000": self.entry("Windows Boot Manager", WINDOWS),
            "0003": self.entry("Limine", OURS, part=3),
            "0004": self.entry("Limine", OTHER),
        }
        self.nvram_with(old, ["0000", "0004", "0003"])
        nvram = self.register()
        self.assertEqual(nvram["entries"], old)
        self.assertEqual(self.writes(), ["--bootorder", "--bootnext"])
        self.assertEqual(nvram["order"], ["0003", "0000", "0004"])
        self.assertEqual(nvram.get("next"), "0003", nvram)

    def test_duplicates_of_the_reused_entry_go(self):
        # Two identical entries, left by an efibootmgr that printed no paths:
        # the first is reused and the other deleted, never the reused one.
        self.nvram_with(
            {
                "0001": self.entry("Limine", OURS, part=3),
                "0003": self.entry("Limine", OURS, part=3),
                "0004": self.entry("Limine", OTHER),
            },
            ["0003", "0004", "0001"],
        )
        nvram = self.register()
        self.assertEqual(sorted(nvram["entries"]), ["0001", "0004"])
        self.assertNotIn("--create", self.writes())
        self.assertEqual(nvram["order"], ["0001", "0004"])
        self.assertEqual(nvram.get("next"), "0001", nvram)

    def test_the_created_entry_is_ours_even_when_listed_after_another(self):
        # The fake reuses the lowest free number: with 0000 taken by another
        # install's "Limine", ours becomes 0001, and the first "Limine" in the
        # listing is not ours.
        self.nvram_with({"0000": self.entry("Limine", OTHER)}, ["0000"])
        nvram = self.register()
        self.assertEqual(nvram["order"][0], "0001")
        self.assertIn(OURS, nvram["entries"]["0001"][1])
        self.assertEqual(nvram["order"], ["0001", "0000"])

    def test_the_next_boot_is_ours_whatever_the_firmware_does_to_bootorder(self):
        # An MSI MAG Z690 Tomahawk rewrites BootOrder at the next POST and
        # puts a new entry behind its own, here the other install's "Limine".
        # BootNext is read before BootOrder.
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        nvram = self.register()
        ours = next(num for num, (_, dp) in nvram["entries"].items() if OURS in dp)
        self.assertEqual(nvram.get("next"), ours, nvram)

    def test_a_refused_bootnext_keeps_the_bootorder_route(self):
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        errors = []
        with mock.patch.dict(os.environ, {"FAKE_REFUSE_BOOTNEXT": "1"}):
            with mock.patch.object(phases_impl, "error", errors.append):
                nvram = self.register()
        ours = next(num for num, (_, dp) in nvram["entries"].items() if OURS in dp)
        self.assertNotIn("next", nvram)
        self.assertEqual(nvram["order"], [ours, "0004"])
        self.assertTrue(any("BootNext" in message for message in errors), errors)

    def test_an_inactive_identical_entry_is_not_reused(self):
        # Someone switched the old entry off in the firmware; BootOrder skips
        # it. A create writes an active one, so 0003 is not identical to it:
        # a new entry is created and booted next, and 0003 is left alone.
        inactive = self.entry("Limine", OURS, part=3) + ["inactive"]
        self.nvram_with({"0003": inactive, "0004": self.entry("Limine", OTHER)}, ["0004", "0003"])
        nvram = self.register()
        self.assertEqual(nvram["entries"]["0000"], self.entry("Limine", OURS, part=3))
        self.assertEqual(nvram["entries"]["0003"], inactive)
        self.assertNotIn("--delete-bootnum", self.writes())
        self.assertEqual(nvram["order"], ["0000", "0004", "0003"])
        self.assertEqual(nvram.get("next"), "0000", nvram)

    def test_a_label_only_listing_deletes_nothing(self):
        # Without device paths no entry can be shown to be this ESP's.
        self.nvram_with({"0004": self.entry("Limine", OTHER), "0003": self.entry("Limine", OURS, part=3)}, ["0004", "0003"])
        with mock.patch.dict(os.environ, {"FAKE_NO_PATHS": "1"}):
            nvram = self.register()
        self.assertIn("0004", nvram["entries"])
        self.assertIn("0003", nvram["entries"])

    def test_a_refused_delete_does_not_stop_the_install(self):
        # The duplicate 0003 refuses to go. The reused 0001 boots first and
        # the duplicate is left behind it.
        self.nvram_with(
            {
                "0001": self.entry("Limine", OURS, part=3),
                "0003": self.entry("Limine", OURS, part=3),
                "0004": self.entry("Limine", OTHER),
            },
            ["0003", "0004", "0001"],
        )
        with mock.patch.dict(os.environ, {"FAKE_REFUSE_DELETE": "1"}), \
                mock.patch.object(phases_impl, "error", lambda _message: None):
            nvram = self.register()
        self.assertEqual(sorted(nvram["entries"]), ["0001", "0003", "0004"])
        self.assertEqual(nvram["order"], ["0001", "0003", "0004"])
        self.assertEqual(nvram.get("next"), "0001", nvram)

    def test_a_loader_whose_name_only_starts_with_ours_is_not_ours(self):
        # \EFI\limine\limine_x64.efi.bak, listed before the real entry, is a
        # separate boot option: it is neither reused nor deleted, and BootNext
        # goes to the entry that starts the real loader.
        backup = self.entry("Limine", OURS, part=3, loader=LOADER + ".bak")
        ours = self.entry("Limine", OURS, part=3)
        self.nvram_with({"0001": backup, "0003": ours}, ["0001", "0003"])
        nvram = self.register()
        self.assertEqual(nvram["entries"], {"0001": backup, "0003": ours})
        self.assertEqual(nvram.get("next"), "0003")
        self.assertNotIn("--delete-bootnum", self.writes())

    def test_other_loaders_on_this_esp_survive(self):
        # Only an entry identical to the one a create would add is reused:
        # same label, this ESP and this loader. A backup loader on the same
        # ESP, or an entry someone labelled differently, is neither reused
        # nor deleted. The identical entry still counts when the listing
        # prints its path in upper case, and a BootOrder number with no entry
        # behind it is dropped.
        backup = self.entry("Limine", OURS, part=3, loader="\\EFI\\backup\\limine.efi")
        relabelled = self.entry("Limine backup", OURS, part=3)
        self.nvram_with(
            {
                "0003": [label.upper() for label in self.entry("Limine", OURS, part=3)],
                "0005": backup,
                "0006": relabelled,
            },
            ["0003", "0005", "0006", "FFFF"],
        )
        nvram = self.register()
        self.assertNotIn("--create", self.writes())
        self.assertNotIn("--delete-bootnum", self.writes())
        self.assertEqual(nvram["entries"]["0005"], backup)
        self.assertEqual(nvram["entries"]["0006"], relabelled)
        self.assertEqual(nvram["order"], ["0003", "0005", "0006"])
        self.assertEqual(nvram.get("next"), "0003", nvram)

    def test_an_old_entry_is_not_taken_for_the_new_one(self):
        # A label-only listing cannot show 0001 to be identical, so a new
        # entry is created; 0000 is taken and it lands on 0002. 0001 was
        # there before, so BootNext and the front of BootOrder go to 0002
        # and 0001 stays behind it.
        self.nvram_with(
            {
                "0000": self.entry("Windows Boot Manager", WINDOWS, loader="\\EFI\\Microsoft\\Boot\\bootmgfw.efi"),
                "0001": self.entry("Limine", OURS, part=3),
            },
            ["0001", "0000"],
        )
        with mock.patch.dict(os.environ, {"FAKE_NO_PATHS": "1"}):
            nvram = self.register()
        self.assertEqual(nvram["entries"]["0002"], self.entry("Limine", OURS, part=3))
        self.assertEqual(nvram.get("next"), "0002", nvram)
        self.assertEqual(nvram["order"], ["0002", "0001", "0000"])

    def test_the_new_entry_is_the_one_that_starts_this_loader(self):
        # Another install's "Limine" entry that the earlier listing did not
        # show is new too, and it holds the lower number.
        self.nvram_with({"0000": self.entry("Limine", OTHER)}, ["0000"])
        phases_impl._register_limine_efi_entry(
            Path("/dev/nvme1n1"), 3, LOADER, pre_state={"entries": {}, "order": []}
        )
        nvram = json.loads(self.nvram.read_text())
        self.assertIn(OURS, nvram["entries"]["0001"][1])
        self.assertEqual(nvram.get("next"), "0001", nvram)
        self.assertEqual(nvram["order"][0], "0001")

    def test_a_refused_create_leaves_other_installs_alone(self):
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_REFUSE_CREATE": "1"}), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            nvram = self.register()
        self.assertEqual(nvram, {"entries": {"0004": self.entry("Limine", OTHER)}, "order": ["0004"]})
        self.assertEqual(len(warnings), 1)

    def test_firmware_that_refuses_creates_keeps_this_esps_entry(self):
        # The identical entry is reused, so no create is sent for the
        # firmware to refuse and the entry stays this install's boot route;
        # a protected target may have no removable loader to fall back on.
        old = {"0003": self.entry("Limine", OURS, part=3), "0004": self.entry("Limine", OTHER)}
        self.nvram_with(old, ["0003", "0004"])
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_REFUSE_CREATE": "1"}), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            nvram = self.register()
        self.assertEqual(nvram, {"entries": old, "order": ["0003", "0004"], "next": "0003"})
        self.assertEqual(self.writes(), ["--bootorder", "--bootnext"])
        self.assertEqual(warnings, [])

    def test_an_entry_the_firmware_answers_a_create_with_is_ours(self):
        # Firmware that keeps one option per device path and loader answers a
        # create of an existing option with that option, adding no number.
        # When the earlier listing did not show it, it is the new entry.
        self.nvram_with(
            {"0000": self.entry("Windows Boot Manager", WINDOWS), "0003": self.entry("Limine", OURS, part=3)},
            ["0000", "0003"],
        )
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_REUSE": "1"}), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            phases_impl._register_limine_efi_entry(
                Path("/dev/nvme1n1"), 3, LOADER,
                pre_state={"entries": {"0000": "Windows Boot Manager"}, "order": ["0000"]},
            )
        nvram = json.loads(self.nvram.read_text())
        self.assertEqual(sorted(nvram["entries"]), ["0000", "0003"])
        self.assertNotIn("--delete-bootnum", self.writes())
        self.assertEqual(nvram["order"], ["0003", "0000"])
        self.assertEqual(nvram.get("next"), "0003", nvram)
        self.assertEqual(warnings, [])

    def test_a_full_nvram_keeps_the_identical_entry(self):
        # No room for another option, even once one is deleted (one slot).
        # The identical entry is reused: nothing is created or deleted, so
        # the entry that boots this install cannot be lost to a create that
        # fails after it.
        old = {"0000": self.entry("Limine", OURS, part=3), "0004": self.entry("Limine", OTHER)}
        for slots in ("2", "1"):
            with self.subTest(slots=slots):
                self.nvram_with(old, ["0004", "0000"])
                Path(str(self.nvram) + ".log").unlink(missing_ok=True)
                warnings = []
                with mock.patch.dict(os.environ, {"FAKE_SLOTS": slots}), \
                        mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
                    nvram = self.register()
                self.assertEqual(nvram["entries"], old)
                self.assertEqual(self.writes(), ["--bootorder", "--bootnext"])
                self.assertEqual(nvram["order"], ["0000", "0004"])
                self.assertEqual(nvram.get("next"), "0000", nvram)
                self.assertEqual(warnings, [])

    def test_a_full_nvram_without_an_identical_entry_deletes_nothing(self):
        # Neither another install's entry nor a backup loader on this ESP is
        # ours to make room with. The create is refused, the warning says
        # why, and the install goes on to the removable loader.
        old = {
            "0000": self.entry("Windows Boot Manager", WINDOWS),
            "0004": self.entry("Limine", OTHER),
            "0005": self.entry("Limine", OURS, part=3, loader="\\EFI\\backup\\limine.efi"),
        }
        self.nvram_with(old, ["0000", "0004", "0005"])
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_SLOTS": "3"}), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            nvram = self.register()
        self.assertEqual(nvram, {"entries": old, "order": ["0000", "0004", "0005"]})
        self.assertEqual(self.writes(), ["--create"])
        self.assertEqual(len(warnings), 1)
        self.assertIn("No space left on device", warnings[0])


    def test_boot_check_does_not_count_another_installs_entry(self):
        # validate_boot: our entry was dropped and no fallback was deployed.
        # The other install's "Limine" entry must not pass for ours.
        esp = self.tmp / "esp"
        esp.mkdir()
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        with mock.patch.object(phases_impl, "error", lambda _message: None):
            with self.assertRaises(RuntimeError):
                phases_impl._validate_uefi_boot_routes(esp, loader=LOADER, fallback_is_ours=True)
            self.nvram_with({"0004": self.entry("Limine", OTHER), "0005": self.entry("Limine", OURS, part=3)}, ["0005", "0004"])
            phases_impl._validate_uefi_boot_routes(esp, loader=LOADER, fallback_is_ours=True)

    def test_boot_check_counts_only_an_active_entry_that_starts_our_loader(self):
        # validate_boot: our entry was refused and no fallback was deployed.
        # A "Limine" entry on this ESP that firmware skips (no "*"), or one
        # that starts another loader there, starts nothing of this install.
        esp = self.tmp / "esp"
        esp.mkdir()
        unusable = {
            "switched off": self.entry("Limine", OURS, part=3) + ["inactive"],
            "a backup loader": self.entry("Limine", OURS, part=3, loader="\\EFI\\backup\\limine.efi"),
        }
        with mock.patch.object(phases_impl, "error", lambda _message: None):
            for name, entry in unusable.items():
                with self.subTest(name):
                    self.nvram_with({"0003": entry}, ["0003"])
                    with self.assertRaises(RuntimeError):
                        phases_impl._validate_uefi_boot_routes(esp, loader=LOADER, fallback_is_ours=True)
            self.nvram_with({"0003": self.entry("Limine", OURS, part=3)}, ["0003"])
            phases_impl._validate_uefi_boot_routes(esp, loader=LOADER, fallback_is_ours=True)

    def test_raw_bytes_in_the_firmware_listing_do_not_stop_the_install(self):
        # A legacy entry with bytes that are not UTF-8, in the list
        # efibootmgr prints after each write and in its messages.
        self.nvram_with({"0004": self.entry("Limine", OTHER)}, ["0004"])
        with mock.patch.dict(os.environ, {"FAKE_NON_UTF8": "1"}), \
                mock.patch.object(phases_impl, "error", lambda _message: None):
            nvram = self.register()
        self.assertEqual(self.writes(), ["--create", "--bootorder", "--bootnext"])
        self.assertEqual(nvram.get("next"), nvram["order"][0])

    def test_an_unreadable_variable_store_skips_registration(self):
        # Every NVRAM write would fail the same way, so none is tried, and
        # the install goes on to write the removable loader.
        self.nvram_with({}, [])
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_NO_EFIVARS": "1"}), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            self.register()
        self.assertEqual(self.writes(), [])
        self.assertEqual(len(warnings), 1)
        self.assertIn("EFI variables are not supported", warnings[0])

    def test_an_unreadable_variable_store_does_not_stop_a_free_space_install(self):
        # The Windows entry check compares a listing before and after; with
        # no listing to compare, it is skipped instead of failing the phase.
        self.nvram_with({}, [])
        ctx = types.SimpleNamespace(
            is_protected=True,
            omarchy_install={"boot": {"enable_fallback": True}, "storage": {"esp_device": "/dev/nvme1n1p3"}},
        )
        warnings = []
        with mock.patch.dict(os.environ, {"FAKE_NO_EFIVARS": "1"}), \
                mock.patch.object(phases_impl, "_split_partition_device", return_value=("/dev/nvme1n1", 3)), \
                mock.patch.object(phases_impl, "_install_limine_efi",
                                  lambda _ctx, *, disk, part, pre_state, **_: phases_impl._register_limine_efi_entry(
                                      disk, part, LOADER, pre_state=pre_state)), \
                mock.patch.object(phases_impl, "_warn_boot_entry_refused", warnings.append):
            phases_impl._install_pre_mounted_limine(ctx)
        self.assertEqual(self.writes(), [])
        self.assertEqual(len(warnings), 1)

    def test_an_unreadable_variable_store_leaves_only_our_fallback_as_a_route(self):
        esp = self.tmp / "esp"
        (esp / "EFI" / "BOOT").mkdir(parents=True)
        (esp / "EFI" / "BOOT" / "BOOTX64.EFI").write_bytes(b"MZ")
        errors = []
        with mock.patch.dict(os.environ, {"FAKE_NO_EFIVARS": "1"}), \
                mock.patch.object(phases_impl.platform, "machine", return_value="x86_64"), \
                mock.patch.object(phases_impl, "error", errors.append):
            phases_impl._validate_uefi_boot_routes(esp, loader=LOADER, fallback_is_ours=True)
            self.assertEqual(len(errors), 1)
            self.assertIn("cannot be read", errors[0])
            with self.assertRaises(RuntimeError) as caught:
                phases_impl._validate_uefi_boot_routes(esp, loader=LOADER, fallback_is_ours=False)
        self.assertIn("cannot be read", str(caught.exception))


if __name__ == "__main__":
    unittest.main()
