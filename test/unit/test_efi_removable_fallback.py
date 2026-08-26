#!/usr/bin/python

"""Firmware that answers efibootmgr reads and then refuses to write.

The HP ProBook that prompted the tolerant decode in command.py fails the next
step too: `efibootmgr --create` returns non-zero rather than registering a
Boot#### variable, and the install died there with a bare CalledProcessError
that said nothing about why. A machine in that state is still bootable — every
UEFI implementation falls back to \\EFI\\BOOT\\BOOTX64.EFI on the ESP when
nothing in NVRAM matches — so these tests pin the rescue rather than the crash,
driving a stand-in efibootmgr that refuses the write the way that firmware does.
"""

import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

# phases_impl imports the archinstall adapter at module scope, which pulls in
# the archinstall library that only exists on the live ISO.
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402

EFIBOOTMGR_LISTING = (
    "BootCurrent: 0003\n"
    "Timeout: 0 seconds\n"
    "BootOrder: 2001,0003\n"
    "Boot0003* Limine\tHD(1,GPT,0d9c9d4f)/File(\\EFI\\limine\\BOOTX64.EFI)\n"
    "Boot2001* USB Drive (UEFI)\tRC\n"
)

# What efibootmgr prints when the variable store will not take another entry.
REFUSAL = "Could not prepare Boot variable: No space left on device"


class EfiRemovableFallbackTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.target = Path(tmp.name)

        # The loader the installer copies out of the target's limine package.
        source = self.target / "usr" / "share" / "limine"
        source.mkdir(parents=True)
        (source / "BOOTX64.EFI").write_bytes(b"limine loader")

        self.bin_dir = self.target / "fakebin"
        self.bin_dir.mkdir()
        path = os.environ["PATH"]
        self.addCleanup(os.environ.__setitem__, "PATH", path)
        os.environ["PATH"] = f"{self.bin_dir}:{path}"

        self.ctx = types.SimpleNamespace(target=self.target)

    def fake_efibootmgr(self, *, create_succeeds: bool) -> None:
        """An efibootmgr that lists entries but may refuse to create one."""
        listing = self.bin_dir / "efibootmgr.out"
        listing.write_text(EFIBOOTMGR_LISTING)
        create = (
            "exit 0"
            if create_succeeds
            else f'printf "%s\\n" "{REFUSAL}" >&2; exit 1'
        )
        script = self.bin_dir / "efibootmgr"
        script.write_text(
            "#!/bin/sh\n"
            'case "${1:-}" in\n'
            f"  --create) {create} ;;\n"
            "  --bootnum|--bootorder) exit 0 ;;\n"
            f'  *) cat "{listing}" ;;\n'
            "esac\n"
        )
        script.chmod(0o755)

    def install(self, **kwargs):
        """Run the EFI install phase with its console output captured."""
        self.messages = []
        with mock.patch.object(phases_impl, "info", self.messages.append), \
             mock.patch.object(phases_impl, "error", self.messages.append):
            phases_impl._install_limine_efi(
                self.ctx,
                esp_mount="/boot",
                disk=Path("/dev/sda"),
                part=1,
                **kwargs,
            )

    @property
    def primary(self) -> Path:
        return self.target / "boot" / "EFI" / "limine" / "limine_x64.efi"

    @property
    def removable(self) -> Path:
        return self.target / "boot" / "EFI" / "BOOT" / "BOOTX64.EFI"

    def hook(self) -> str:
        return (
            self.target / "etc" / "pacman.d" / "hooks" / "99-omarchy-limine.hook"
        ).read_text()

    def test_a_refused_boot_variable_still_leaves_a_bootable_machine(self):
        self.fake_efibootmgr(create_succeeds=False)

        self.install()

        self.assertTrue(
            self.removable.exists(),
            "no loader at the removable path firmware falls back to",
        )
        self.assertEqual(self.removable.read_bytes(), b"limine loader")
        # The configured path stays too, so the machine boots either way if its
        # NVRAM is cleared later and the variable can be written after all.
        self.assertTrue(self.primary.exists())

    def test_a_limine_upgrade_refreshes_the_path_actually_being_booted(self):
        self.fake_efibootmgr(create_succeeds=False)

        self.install()

        hook = self.hook()
        self.assertIn("/boot/EFI/BOOT/BOOTX64.EFI", hook)
        self.assertIn("/boot/EFI/limine/limine_x64.efi", hook)

    def test_what_efibootmgr_said_reaches_whoever_is_watching(self):
        # The whole point of catching this rather than letting check=True raise:
        # "No space left on device" is the diagnosis, and a CalledProcessError
        # discards it.
        self.fake_efibootmgr(create_succeeds=False)

        self.install()

        self.assertTrue(
            any(REFUSAL in m for m in self.messages),
            f"efibootmgr's reason never surfaced: {self.messages}",
        )

    def test_a_removable_install_has_nothing_left_to_fall_back_to(self):
        # Already at \EFI\BOOT\BOOTX64.EFI, so a missing variable costs nothing
        # and the phase should finish quietly rather than copy over itself.
        self.fake_efibootmgr(create_succeeds=False)

        self.install(removable=True)

        self.assertTrue(self.removable.exists())
        self.assertNotIn("&&", self.hook())

    def test_firmware_that_accepts_the_variable_gets_no_fallback_copy(self):
        self.fake_efibootmgr(create_succeeds=True)

        self.install()

        self.assertTrue(self.primary.exists())
        self.assertFalse(
            self.removable.exists(),
            "wrote a removable loader on firmware that took the boot entry",
        )
        self.assertNotIn("&&", self.hook())


if __name__ == "__main__":
    unittest.main()
