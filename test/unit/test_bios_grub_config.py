"""BIOS installs also leave a grub.cfg so GRUB-payload firmware can boot."""

import sys
import tempfile
import types
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import phases_impl  # noqa: E402

LIMINE_CONF = """\
/+Omarchy
comment: Omarchy
  //linux-omarchy
  protocol: linux
  module_path: boot():/259e396943e742b1b8da1d7e735ffa34/linux-omarchy/initramfs#a8a6176df22f
  path: boot():/259e396943e742b1b8da1d7e735ffa34/linux-omarchy/vmlinuz#631a6a528d04
  cmdline: cryptdevice=PARTUUID=c8986d2a-02:root root=/dev/mapper/root rw
"""


class BiosGrubConfigTest(unittest.TestCase):
    def test_boot_path_strips_prefix_and_hash(self):
        self.assertEqual(
            phases_impl._limine_entry_boot_path(LIMINE_CONF, "path"),
            "259e396943e742b1b8da1d7e735ffa34/linux-omarchy/vmlinuz",
        )
        self.assertEqual(
            phases_impl._limine_entry_boot_path(LIMINE_CONF, "module_path"),
            "259e396943e742b1b8da1d7e735ffa34/linux-omarchy/initramfs",
        )
        self.assertIsNone(phases_impl._limine_entry_boot_path("", "path"))

    def test_writes_grub_cfg_with_kernel_cmdline_and_ucode(self):
        with tempfile.TemporaryDirectory() as tmp:
            esp = Path(tmp)
            (esp / "limine.conf").write_text(LIMINE_CONF)
            (esp / "intel-ucode.img").write_text("ucode")

            phases_impl._write_bios_grub_config(
                esp, "cryptdevice=PARTUUID=c8986d2a-02:root root=/dev/mapper/root rw"
            )

            grub = (esp / "grub/grub.cfg").read_text()
            self.assertIn('menuentry "Omarchy"', grub)
            self.assertIn(
                "linux /259e396943e742b1b8da1d7e735ffa34/linux-omarchy/vmlinuz "
                "cryptdevice=PARTUUID=c8986d2a-02:root root=/dev/mapper/root rw",
                grub,
            )
            self.assertIn(
                "initrd /intel-ucode.img "
                "/259e396943e742b1b8da1d7e735ffa34/linux-omarchy/initramfs",
                grub,
            )

    def test_skips_when_entry_paths_are_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            esp = Path(tmp)
            (esp / "limine.conf").write_text("/+Omarchy\n")
            phases_impl._write_bios_grub_config(esp, "root=/dev/mapper/root")
            self.assertFalse((esp / "grub/grub.cfg").exists())


if __name__ == "__main__":
    unittest.main()
