"""UEFI x86_64 installs boot through systemd-boot.

The image carries Limine's stack (omarchy-boot), which BIOS installs keep. A
UEFI install swaps it for omarchy-boot-systemd, puts systemd-boot on the ESP
with an "Omarchy Boot" entry, writes the cmdline where systemd-boot's boot
images read it, and has omarchy-boot-switch install build those images at the
end. validate_boot checks what the firmware will find. Tested against a
synthesised target and ESP, with pacman, arch-chroot and efibootmgr recorded
instead of run.
"""

import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.path.insert(0, str(ROOT / "test/unit"))
sys.modules.setdefault("orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter"))
from orchestrator import phases_impl as phases  # noqa: E402
from test_uki_cmdline import uki  # noqa: E402

MACHINE_ID = "0123456789abcdef0123456789abcdef"
CMDLINE = "cryptdevice=PARTUUID=p:root root=/dev/mapper/root zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs"


class SystemdBootInstallTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "target"
        self.mirror = Path(temporary.name) / "mirror"
        self.mirror.mkdir(parents=True)
        (self.mirror / "omarchy-boot-systemd-1-1-x86_64.pkg.tar.zst").write_text("package")
        self.ctx = types.SimpleNamespace(
            target=self.root, state={}, omarchy_install={"storage": {"kernel": "linux-omarchy"}},
            user_configuration={}, encrypt=True, is_protected=False, defer_provisioning=False,
        )
        self.has_uefi = True
        self.commands = []
        for patch in (
            mock.patch.object(phases, "OFFLINE_MIRROR", self.mirror),
            mock.patch.object(phases.platform, "machine", return_value="x86_64"),
            mock.patch.object(phases.arch, "has_uefi", lambda: self.has_uefi, create=True),
            mock.patch.object(phases.subprocess, "run", self.record),
            mock.patch.dict(phases.os.environ, {}, clear=False),
        ):
            patch.start()
            self.addCleanup(patch.stop)
        phases.os.environ.pop("OMARCHY_ISO_BOOT_LOADER", None)

    def record(self, command, **_kwargs):
        self.commands.append(list(command))
        return types.SimpleNamespace(returncode=0, stdout="", stderr="")

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(data, bytes):
            path.write_bytes(data)
        else:
            path.write_text(data)
        return path

    def installed(self):
        """What omarchy-boot-switch install leaves on a full-disk install."""
        self.write("etc/machine-id", MACHINE_ID + "\n")
        self.write("etc/kernel/cmdline", CMDLINE + "\n")
        self.write("etc/fstab", "UUID=x /var/lib/omarchy/boot btrfs subvol=/@omarchy-boot 0 0\n")
        self.write("boot/EFI/systemd/systemd-bootx64.efi", "loader")
        self.write("boot/EFI/BOOT/BOOTX64.EFI", "loader")
        self.write("boot/loader/loader.conf", "timeout 0\n")
        self.write(f"boot/EFI/Linux/omarchy-{MACHINE_ID[:8]}-linux-omarchy-abc123.efi", uki(CMDLINE.encode()))
        self.write("usr/lib/modules/7.2/pkgbase", "linux-omarchy\n")
        self.write("usr/lib/modules/7.2/build/include/config/kernel.release", "7.2\n")

    def validate(self):
        efi = {"entries": {"0003": f"Omarchy Boot\tHD(1,GPT,guid,0x800,0x1000)/\\EFI\\systemd\\systemd-bootx64.efi"}, "order": ["0003"]}
        with mock.patch.object(phases, "_assert_boot_hooks_restored"), \
                mock.patch.object(phases, "_validate_kernel_headers"), \
                mock.patch.object(phases, "_validate_package_signing"), \
                mock.patch.object(phases, "_mounted_partition_guid", return_value="guid"), \
                mock.patch.object(phases, "_read_efibootmgr", return_value=efi):
            phases.validate_boot(self.ctx)

    def test_uefi_x86_installs_get_systemd_boot(self):
        self.assertEqual(phases._boot_loader(self.ctx), "systemd-boot")

    def test_bios_an_override_or_a_mirror_without_the_stack_keep_limine(self):
        for setup in (
            lambda: setattr(self, "has_uefi", False),
            lambda: phases.os.environ.__setitem__("OMARCHY_ISO_BOOT_LOADER", "limine"),
            lambda: (self.mirror / "omarchy-boot-systemd-1-1-x86_64.pkg.tar.zst").unlink(),
        ):
            with self.subTest(setup=setup):
                self.setUp()
                setup()
                self.assertEqual(phases._boot_loader(self.ctx), "limine")

    def test_aarch64_uefi_installs_get_systemd_boot_with_the_console_on_screen(self):
        luks_tuning = types.ModuleType("orchestrator.luks_tuning")
        luks_tuning.with_cmdline_options = lambda cmdline: f"{cmdline} rd.luks.name=p=root"
        with mock.patch.object(phases.platform, "machine", return_value="aarch64"), \
                mock.patch.dict(sys.modules, {"orchestrator.luks_tuning": luks_tuning}):
            self.assertEqual(phases._boot_loader(self.ctx), "systemd-boot")
            phases._write_limine_defaults(self.ctx, CMDLINE, esp_mount="/boot")
        self.assertEqual((self.root / "etc/cmdline.d/00-omarchy-console.conf").read_text(), "console=tty0 acpi=nospcr\n")
        self.assertFalse((self.root / "etc/limine-entry-tool.d").exists())

    def test_an_n1x_boot_image_keeps_the_console_off_the_serial_port(self):
        self.installed()
        with mock.patch.object(phases, "_installed_arm_platform", return_value="n1x"):
            with self.assertRaisesRegex(RuntimeError, "console=tty0 acpi=nospcr"):
                self.validate()
            (self.root / f"boot/EFI/Linux/omarchy-{MACHINE_ID[:8]}-linux-omarchy-abc123.efi").write_bytes(
                uki(f"{CMDLINE} console=tty0 acpi=nospcr".encode()))
            self.validate()

    def test_the_stack_swap_replaces_limine_s_packages(self):
        phases._install_systemd_boot_stack(self.ctx)
        swap = self.commands[0]
        self.assertEqual(swap[:3], ["pacman", "--root", str(self.root)])
        self.assertIn("--ask=4", swap)
        self.assertEqual(swap[-1], "omarchy-boot-systemd")

    def test_the_loader_goes_on_the_esp_with_an_omarchy_boot_entry(self):
        self.write("usr/lib/systemd/boot/efi/systemd-bootx64.efi", "loader")
        with mock.patch.object(phases, "_register_limine_efi_entry") as register:
            phases._install_limine_efi(self.ctx, esp_mount="/boot", disk=Path("/dev/vda"), part=1)
        self.assertTrue((self.root / "boot/EFI/systemd/systemd-bootx64.efi").is_file())
        self.assertFalse((self.root / "etc/pacman.d/hooks/99-omarchy-limine.hook").exists())
        register.assert_called_once()
        self.assertEqual(register.call_args.args[2], "\\EFI\\systemd\\systemd-bootx64.efi")
        self.assertEqual(register.call_args.kwargs["label"], "Omarchy Boot")

    def test_the_cmdline_goes_where_systemd_boot_s_images_read_it(self):
        luks_tuning = types.ModuleType("orchestrator.luks_tuning")
        luks_tuning.with_cmdline_options = lambda cmdline: f"{cmdline} rd.luks.name=p=root"
        with mock.patch.dict(sys.modules, {"orchestrator.luks_tuning": luks_tuning}):
            phases._write_limine_defaults(self.ctx, CMDLINE, esp_mount="/boot")
        written = (self.root / "etc/kernel/cmdline").read_text()
        self.assertIn("root=/dev/mapper/root", written)
        self.assertIn(phases.CONSOLE_NO_ANSI_QUERY, written)
        self.assertFalse((self.root / "etc/default/limine").exists())
        self.assertFalse((self.root / "boot/limine.conf").exists())
        self.assertTrue(self.ctx.state["boot_fallback"])

    def test_omarchy_boot_switch_install_builds_the_boot_images(self):
        self.write("etc/snapper/configs/root", "")
        self.write("etc/kernel/cmdline", CMDLINE + "\n")
        self.ctx.state["boot_fallback"] = False
        with mock.patch.object(phases, "_drop_initramfs_modules_the_kernel_lacks"), \
                mock.patch.object(phases, "_is_apple_t2_hardware", return_value=False):
            phases.finalize_boot(self.ctx)
        self.assertIn(
            ["arch-chroot", str(self.root), "env", "OMARCHY_BOOT_ESP=/boot",
             "omarchy-boot-switch", "install", "--no-efi-register", "--no-fallback"],
            self.commands,
        )

    def test_a_free_space_install_s_esp_at_efi_reaches_the_install(self):
        self.write("etc/snapper/configs/root", "")
        self.write("etc/kernel/cmdline", CMDLINE + "\n")
        self.ctx.omarchy_install["boot"] = {"esp_mount": "/efi"}
        with mock.patch.object(phases, "_drop_initramfs_modules_the_kernel_lacks"), \
                mock.patch.object(phases, "_is_apple_t2_hardware", return_value=False):
            phases.finalize_boot(self.ctx)
        self.assertTrue(any("OMARCHY_BOOT_ESP=/efi" in command for command in self.commands))
        self.assertFalse(any("limine" in " ".join(command) for command in self.commands))

    def test_a_complete_install_validates(self):
        self.installed()
        self.validate()

    def test_validation_wants_a_boot_image_with_the_install_s_cmdline(self):
        self.installed()
        (self.root / f"boot/EFI/Linux/omarchy-{MACHINE_ID[:8]}-linux-omarchy-abc123.efi").write_bytes(uki(b"root=/dev/sda2 rw"))
        with self.assertRaisesRegex(RuntimeError, "cryptdevice"):
            self.validate()
        (self.root / f"boot/EFI/Linux/omarchy-{MACHINE_ID[:8]}-linux-omarchy-abc123.efi").unlink()
        with self.assertRaisesRegex(RuntimeError, "no boot image"):
            self.validate()

    def test_a_damaged_boot_image_fails_validation_next_to_a_good_one(self):
        self.installed()
        self.write(f"boot/EFI/Linux/omarchy-{MACHINE_ID[:8]}-linux-omarchy-zzz999.efi", b"not a PE image")
        with self.assertRaisesRegex(RuntimeError, "no readable cmdline"):
            self.validate()

    def test_validation_wants_the_boot_store_mounted_at_boot(self):
        self.installed()
        self.write("etc/fstab", "UUID=x / btrfs subvol=/@ 0 0\n")
        with self.assertRaisesRegex(RuntimeError, "boot store"):
            self.validate()

    def test_the_provisioning_unlock_is_a_cmdline_drop_in(self):
        self.ctx.omarchy_install["provisioning"] = {}
        provisioning = self.root / "var/lib/omarchy/provisioning"
        provisioning.mkdir(parents=True)
        with mock.patch.object(phases, "_provision_encryption_password", return_value="secret"):
            phases._stage_provisioning_luks_unlock(self.ctx, provisioning)
        self.assertEqual(
            (self.root / "etc/cmdline.d/99-omarchy-provisioning-unlock.conf").read_text(),
            "cryptkey=rootfs:/etc/omarchy/provisioning.key\n",
        )
        self.assertFalse((self.root / "etc/limine-entry-tool.d/99-omarchy-provisioning-unlock.conf").exists())
        self.assertIn("etc/cmdline.d/99-omarchy-provisioning-unlock.conf", phases.FACTORY_SCRUB_PATHS)


if __name__ == "__main__":
    unittest.main()
