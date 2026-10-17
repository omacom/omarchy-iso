"""Validate the boot artifacts selected by Limine's effective UKI setting."""

from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault("orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter"))
from orchestrator import phases_impl as phases  # noqa: E402


# The layout limine-entry-tool and limine-snapper-sync write.
LINUX_ENTRY = """/+Omarchy
comment: Omarchy
  //linux-aarch64
  comment: kernel-id=linux-aarch64
  protocol: linux
  module_path: boot():/machine/7.2/initramfs#abcd
  path: boot():/machine/7.2/vmlinuz#abcd
  cmdline: root=UUID=test rw
"""
SNAPSHOTS = """
     //Snapshots
     ///1 | 2026-10-01 00:00:00
     ////linux-aarch64
     protocol: linux
     module_path: boot():/machine/limine_history/initramfs#abcd
     path: boot():/machine/limine_history/vmlinuz#abcd
     cmdline: root=UUID=test rw rootflags=subvol=/@/.snapshots/1/snapshot
"""


class BootValidationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.ctx = types.SimpleNamespace(
            target=self.root, omarchy_install={"storage": {"kernel": "linux-aarch64"}},
            user_configuration={}, encrypt=False, is_protected=False, defer_provisioning=False,
        )
        self.write("boot/limine.conf", LINUX_ENTRY)
        self.write("etc/kernel/cmdline", "root=UUID=test rw\n")
        self.write("etc/default/limine", "CUSTOM_UKI_NAME=omarchy\n")
        self.write("etc/limine-entry-tool.d/omarchy-uki.conf", "ENABLE_UKI=yes\n")
        self.write("boot/EFI/limine/limine_x64.efi", "bootloader")
        self.write("boot/machine/7.2/vmlinuz", "kernel")
        self.write("boot/machine/7.2/initramfs", "initramfs")
        self.write("usr/lib/modules/7.2/pkgbase", "linux-aarch64\n")
        self.write("usr/lib/modules/7.2/build/include/config/kernel.release", "7.2\n")
        for patch in (
            # The fixtures are x86_64 ones; the Limine binary checked follows the host.
            mock.patch.object(phases.platform, "machine", return_value="x86_64"),
            mock.patch.object(phases, "_assert_boot_hooks_restored"),
            mock.patch.object(phases.arch, "has_uefi", return_value=True, create=True),
            mock.patch.object(phases, "_read_efibootmgr", return_value={"entries": {"0001": "Limine"}}),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def write(self, name, text):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def disable_uki(self):
        self.write("etc/limine-entry-tool.d/zz-omarchy-dgx-spark.conf", "ENABLE_UKI=no\n")

    def test_disabled_uki_accepts_kernel_and_initramfs_without_uki(self):
        self.disable_uki()
        phases.validate_boot(self.ctx)

    def test_default_uki_requires_nonempty_uki(self):
        uki = self.write("boot/EFI/Linux/omarchy_linux-aarch64.efi", "UKI")
        phases.validate_boot(self.ctx)
        uki.write_bytes(b"")
        with self.assertRaisesRegex(RuntimeError, "missing or empty"):
            phases.validate_boot(self.ctx)

    def test_default_limine_overrides_hardware_dropin(self):
        self.disable_uki()
        self.write("etc/default/limine", 'ENABLE_UKI="yes"\n')
        with self.assertRaisesRegex(RuntimeError, "missing or empty"):
            phases.validate_boot(self.ctx)
        self.write("boot/EFI/Linux/omarchy_linux-aarch64.efi", "UKI")
        phases.validate_boot(self.ctx)

    def test_disabled_uki_reads_each_kernel_entry_apart_from_snapshots(self):
        self.disable_uki()
        self.write("boot/machine/limine_history/vmlinuz", "kernel")
        self.write("boot/machine/limine_history/initramfs", "initramfs")
        second = LINUX_ENTRY.split("\n", 2)[2].replace("linux-aarch64", "linux-other")
        self.write("boot/limine.conf", LINUX_ENTRY + second + SNAPSHOTS)
        phases.validate_boot(self.ctx)
        # A snapshot's kernel does not stand in for a missing current kernel.
        (self.root / "boot/machine/7.2/vmlinuz").unlink()
        self.write("boot/limine.conf", LINUX_ENTRY + SNAPSHOTS)
        with self.assertRaisesRegex(RuntimeError, "no bootable Omarchy Linux entry"):
            phases.validate_boot(self.ctx)

    def test_disabled_uki_rejects_missing_and_empty_boot_files(self):
        self.disable_uki()
        for name in ("vmlinuz", "initramfs"):
            path = self.root / "boot/machine/7.2" / name
            for content in (None, ""):
                with self.subTest(name=name, content=content):
                    if content is None:
                        path.unlink()
                    else:
                        path.write_text(content)
                    with self.assertRaisesRegex(RuntimeError, "no bootable Omarchy Linux entry"):
                        phases.validate_boot(self.ctx)
            path.write_text("boot file")

    def test_disabled_uki_rejects_incomplete_or_unrelated_entries(self):
        self.disable_uki()
        for entry in (
            LINUX_ENTRY.replace("protocol: linux", "protocol: efi"),
            LINUX_ENTRY.replace("  module_path: boot():/machine/7.2/initramfs#abcd\n", ""),
            LINUX_ENTRY.replace("root=UUID=test", "quiet"),
            LINUX_ENTRY.replace("/+Omarchy", "/Other OS"),
            LINUX_ENTRY.replace("boot():/machine/7.2/vmlinuz", "uuid(1234):/machine/7.2/vmlinuz"),
            "/Omarchy\n  protocol: efi\n" + LINUX_ENTRY.replace("/+Omarchy", "/Other OS"),
        ):
            with self.subTest(entry=entry):
                self.write("boot/limine.conf", entry)
                with self.assertRaises(RuntimeError):
                    phases.validate_boot(self.ctx)

    def test_encrypted_install_requires_cryptdevice_on_linux_entry(self):
        self.disable_uki()
        self.ctx.encrypt = True
        # A comment or another entry containing cryptdevice is not sufficient.
        self.write("boot/limine.conf", "# cryptdevice=UUID=test:root\n" + LINUX_ENTRY)
        with self.assertRaisesRegex(RuntimeError, "no bootable Omarchy Linux entry"):
            phases.validate_boot(self.ctx)
        self.write("boot/limine.conf", LINUX_ENTRY.replace("rw", "rw cryptdevice=UUID=test:root"))
        phases.validate_boot(self.ctx)

    def test_disabled_uki_still_requires_firmware_bootloader_and_entry(self):
        self.disable_uki()
        with mock.patch.object(phases, "_read_efibootmgr", return_value={"entries": {}}):
            with self.assertRaisesRegex(RuntimeError, "no 'Limine' entry"):
                phases.validate_boot(self.ctx)
        (self.root / "boot/EFI/limine/limine_x64.efi").unlink()
        with self.assertRaisesRegex(RuntimeError, "missing or empty"):
            phases.validate_boot(self.ctx)


if __name__ == "__main__":
    unittest.main()
