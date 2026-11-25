"""UEFI x86_64 installs boot through systemd-boot.

The image carries Limine's stack (omarchy-boot), which BIOS installs keep. A
UEFI install swaps it for omarchy-boot-systemd, puts systemd-boot on the ESP
with an "Omarchy Boot" entry, writes the cmdline where systemd-boot's boot
images read it, and has omarchy-boot-switch install build those images at the
end. validate_boot checks what the firmware will find. Tested against a
synthesised target and ESP, with pacman, arch-chroot and efibootmgr recorded
instead of run.
"""

import subprocess
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
from orchestrator.uki_cmdline import read_cmdline  # noqa: E402
from test_uki_cmdline import uki  # noqa: E402

MACHINE_ID = "0123456789abcdef0123456789abcdef"
# The tests record subprocess.run instead of running it; the builder's own
# shell is run for real.
RUN = subprocess.run
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
        self.apple = False
        self.commands = []
        for patch in (
            mock.patch.object(phases, "OFFLINE_MIRROR", self.mirror),
            mock.patch.object(phases.platform, "machine", return_value="x86_64"),
            mock.patch.object(phases.arch, "has_uefi", lambda: self.has_uefi, create=True),
            mock.patch.object(phases, "_is_apple_t2_hardware", lambda: self.apple),
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

    def test_intel_macs_keep_limine_as_omarchy_boot_switch_keeps_them(self):
        for setup in (
            lambda: setattr(self, "apple", True),
            lambda: self.ctx.user_configuration.__setitem__("kernels", ["linux-t2"]),
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

    def test_system_setup_defers_both_of_omarchy_boot_systemd_s_hooks(self):
        hooks = self.root / "etc/pacman.d/hooks"
        for name in ("60-mkinitcpio-remove.hook", "90-mkinitcpio-install.hook"):
            self.write(f"etc/pacman.d/hooks/{name}", "[Trigger]\n")
        masked = []

        def setup(_ctx, _cmd, **_kwargs):
            masked.extend(sorted(p.name for p in hooks.iterdir() if phases._is_devnull_symlink(p)))

        self.ctx.username = "omarchy"
        with mock.patch.object(phases, "_runtime_populates_target_keyring", return_value=False), \
                mock.patch.object(phases, "_run_target_setup_command", setup):
            phases.run_system_finalizer(self.ctx)
        self.assertEqual(masked, ["60-mkinitcpio-remove.hook", "90-mkinitcpio-install.hook"])
        self.assertEqual((hooks / "60-mkinitcpio-remove.hook").read_text(), "[Trigger]\n")
        phases._assert_boot_hooks_restored(self.ctx)

    def test_oem_scripts_run_with_the_boot_store_mounted(self):
        scripts = self.root.parent / "oem/scripts"
        scripts.mkdir(parents=True)
        (scripts / "10-firmware.sh").write_text("pacman -S --noconfirm some-firmware\n")
        self.ctx.oem_dir = scripts.parent
        runs = []
        with mock.patch.object(phases, "_join_target_keyring_init"), \
                mock.patch.object(phases, "_run_target_setup_command",
                                  lambda _ctx, cmd, **kwargs: runs.append((cmd, kwargs))):
            phases.run_oem_setup(self.ctx)
            self.ctx.state["boot_loader"] = "limine"
            phases.run_oem_setup(self.ctx)
        script = ["/bin/bash", f"/{phases.OEM_SCRIPTS_TARGET_DIR}/10-firmware.sh"]
        (systemd_boot, kwargs), (limine, limine_kwargs) = runs
        self.assertEqual(systemd_boot[:4], ["env", "OMARCHY_BOOT_ESP=/boot", "/bin/bash", "-c"])
        self.assertIn("mount /var/lib/omarchy/boot", systemd_boot[4])
        self.assertEqual(systemd_boot[-2:], script)
        self.assertEqual(kwargs, {"private_mounts": True})
        self.assertEqual((limine, limine_kwargs), (script, {}))

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

    def test_validation_wants_systemd_boot_itself_beside_another_system_s_fallback_loader(self):
        self.installed()
        self.ctx.is_protected = True
        self.ctx.omarchy_install["boot"] = {"enable_fallback": False}
        (self.root / "boot/EFI/systemd/systemd-bootx64.efi").unlink()
        with mock.patch.object(phases, "_validate_pre_mounted_filesystems"), \
                self.assertRaisesRegex(RuntimeError, "systemd-bootx64.efi missing"):
            self.validate()

    def test_a_boot_image_cut_short_inside_its_cmdline_is_refused(self):
        self.installed()
        image = self.root / f"boot/EFI/Linux/omarchy-{MACHINE_ID[:8]}-linux-omarchy-abc123.efi"
        image.write_bytes(image.read_bytes()[:0x400 + CMDLINE.index("rootflags")])
        self.assertIsNone(read_cmdline(image))
        with self.assertRaisesRegex(RuntimeError, "no readable cmdline"):
            self.validate()

    def test_the_esp_is_where_the_installer_mounted_it(self):
        luks_tuning = types.ModuleType("orchestrator.luks_tuning")
        luks_tuning.with_cmdline_options = lambda cmdline: f"{cmdline} rd.luks.name=p=root"
        with mock.patch.dict(sys.modules, {"orchestrator.luks_tuning": luks_tuning}):
            phases._write_limine_defaults(self.ctx, CMDLINE, esp_mount="/efi")
        self.write("etc/snapper/configs/root", "")
        with mock.patch.object(phases, "_drop_initramfs_modules_the_kernel_lacks"):
            phases.finalize_boot(self.ctx)
        self.assertTrue(any("OMARCHY_BOOT_ESP=/efi" in command for command in self.commands))
        self.installed()
        (self.root / "boot").rename(self.root / "efi")
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


class PrebuiltInitramfsTest(unittest.TestCase):
    """The image's pre-built initramfs stands in for mkinitcpio on the image's
    kernel when the machine changed nothing it is built from, under the
    conditions Limine's pre-built UKI has, and goes once the boot is set up."""

    ARGUMENT = "linux-omarchy=/var/lib/omarchy-iso/prebuilt-initramfs.img"
    record = SystemdBootInstallTest.record
    write = SystemdBootInstallTest.write

    def setUp(self):
        SystemdBootInstallTest.setUp(self)
        self.write("etc/snapper/configs/root", "")
        self.write("etc/kernel/cmdline", CMDLINE + "\n")
        self.write("usr/lib/modules/7.2.1-omarchy/pkgbase", "linux-omarchy\n")
        self.write("etc/mkinitcpio.conf", "HOOKS=()\n")
        self.write("etc/mkinitcpio.conf.d/thunderbolt_module.conf", "  MODULES+=(thunderbolt)\n")
        self.write("etc/mkinitcpio.conf.d/00-omarchy-hooks.conf", "HOOKS=(base udev encrypt omarchy-restore)\n")
        self.write("etc/modprobe.d/omarchy-usb-autosuspend.conf", "options usbcore autosuspend=5\n")
        self.write("usr/lib/modprobe.d/systemd.conf", "options bonding max_bonds=0\n")
        self.write("etc/vconsole.conf", "KEYMAP=us\nFONT=default8x16\n")
        records = "var/lib/omarchy-iso"
        self.write(f"{records}/prebuilt-initramfs.img", b"\0" * 4096)
        self.write(f"{records}/prebuilt-initramfs.kernel", "linux-omarchy\n")
        self.write(f"{records}/prebuilt-initramfs.kver", "7.2.1-omarchy\n")
        self.write(f"{records}/prebuilt-initramfs.keymap", "\n")
        self.write(f"{records}/prebuilt-initramfs.inputs", "".join(
            f"{digest}  {path}\n" for path, digest in sorted(phases._initramfs_inputs(self.root).items())))
        self.messages = []
        for patch in (
            mock.patch.object(phases, "_drop_initramfs_modules_the_kernel_lacks"),
            mock.patch.object(phases, "info", self.messages.append),
        ):
            patch.start()
            self.addCleanup(patch.stop)

    def install_command(self):
        self.commands.clear()
        with mock.patch.object(phases, "_time_step", wraps=phases._time_step) as step:
            phases.finalize_boot(self.ctx)
        self.label = step.call_args.args[0]
        return next(command for command in self.commands if "omarchy-boot-switch" in command)

    def assert_fast(self):
        command = self.install_command()
        self.assertEqual(command[-2:], ["--initramfs", self.ARGUMENT])
        self.assertIn("pre-built initramfs", self.label)
        self.assertTrue(any("using the pre-built initramfs for linux-omarchy" in m for m in self.messages), self.messages)

    def assert_built_here(self, message):
        command = self.install_command()
        self.assertNotIn("--initramfs", command)
        self.assertIn("built on this machine", self.label)
        self.assertTrue(any(message in m for m in self.messages), self.messages)

    def test_a_machine_that_changed_nothing_takes_the_pre_built_initramfs(self):
        self.assert_fast()

    def test_what_every_machine_writes_keeps_the_fast_path(self):
        # What _drop_initramfs_modules_the_kernel_lacks writes, word for word.
        self.write(f"etc/mkinitcpio.conf.d/{phases.INITRAMFS_MODULES_CONF}", (
            "_omarchy_absent=(thunderbolt)\n_omarchy_kept=()\n"
            'for _omarchy_module in "${MODULES[@]}"; do\n  _omarchy_kept+=("$_omarchy_module")\ndone\n'
            'MODULES=("${_omarchy_kept[@]}")\nunset _omarchy_absent _omarchy_kept _omarchy_module\n'))
        self.write("etc/modprobe.d/omarchy-toprow.conf", "options hid_apple fnmode=1\n")
        self.write("etc/vconsole.conf", "KEYMAP=us\nXKBLAYOUT=us\nFONT=default8x16\n")
        self.assert_fast()

    def test_another_kernel_preferred_still_takes_it_for_the_image_s_kernel(self):
        self.write("usr/lib/modules/6.12-lts/pkgbase", "linux-lts\n")
        self.ctx.user_configuration["kernels"] = ["linux-lts"]
        command = self.install_command()
        self.assertEqual(command[-4:], ["--prefer", "linux-lts", "--initramfs", self.ARGUMENT])

    def test_an_image_without_one_builds_here(self):
        (self.root / "var/lib/omarchy-iso/prebuilt-initramfs.img").unlink()
        command = self.install_command()
        self.assertNotIn("--initramfs", command)
        self.assertIn("built on this machine", self.label)

    def test_an_esp_shared_with_another_system_builds_here(self):
        self.ctx.is_protected = True
        self.assert_built_here("shared with another system")

    def test_the_pre_built_initramfs_goes_once_the_boot_is_set_up(self):
        for loader in ("systemd-boot", "limine"):
            with self.subTest(loader=loader):
                self.setUp()
                if loader == "systemd-boot":
                    phases.finalize_boot(self.ctx)
                else:
                    phases._remove_prebuilt_initramfs(self.ctx)
                self.assertEqual(list((self.root / "var/lib/omarchy-iso").glob("prebuilt-initramfs.*")), [])

    def test_another_build_of_the_image_s_kernel_builds_here(self):
        (self.root / "usr/lib/modules/7.2.1-omarchy").rename(self.root / "usr/lib/modules/7.2.2-omarchy")
        self.assert_built_here("isn't installed")

    def test_modules_a_hardware_script_added_build_here(self):
        self.write("etc/mkinitcpio.conf.d/nvidia.conf", "MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)\n")
        self.assert_built_here("differs from the image's (etc/mkinitcpio.conf.d/nvidia.conf)")

    def test_another_keyboard_layout_builds_here(self):
        self.write("etc/vconsole.conf", "KEYMAP=fr\nXKBLAYOUT=fr\n")
        self.assert_built_here("keyboard layout fr differs")

    def test_the_provisioning_key_builds_here(self):
        self.write(phases.PROVISION_KEY_DROPIN, "FILES+=(/etc/omarchy/provisioning.key)\n")
        self.assert_built_here(f"differs from the image's ({phases.PROVISION_KEY_DROPIN})")

    def test_a_board_with_a_platform_of_its_own_builds_here(self):
        with mock.patch.object(phases.platform, "machine", return_value="aarch64"), \
                mock.patch.object(phases, "hw_platform", return_value="aarch64-n1x"):
            self.assert_built_here("platform's rules")

    def test_a_generic_aarch64_machine_takes_it(self):
        with mock.patch.object(phases.platform, "machine", return_value="aarch64"), \
                mock.patch.object(phases, "hw_platform", return_value="aarch64"):
            self.assert_fast()

    def test_any_other_change_to_what_it_is_built_from_builds_here(self):
        for name, change in (
            ("etc/modprobe.d/hid_apple.conf", lambda path: self.write(path, "options hid_apple fnmode=2\n")),
            ("etc/initcpio/install/omarchy-quiet-efivars", lambda path: self.write(path, "build() { :; }\n")),
            ("etc/mkinitcpio.conf.d/omarchy_resume.conf", lambda path: self.write(path, "HOOKS+=(resume)\n")),
            ("etc/mkinitcpio.conf.d/00-omarchy-hooks.conf", lambda path: self.write(path, "HOOKS=(base systemd)\n")),
            ("etc/modprobe.d/omarchy-usb-autosuspend.conf", lambda path: (self.root / path).unlink()),
            ("etc/modprobe.d/blacklist.conf", lambda path: (self.root / path).symlink_to("/dev/null")),
        ):
            with self.subTest(name=name):
                self.setUp()
                change(name)
                self.assert_built_here(f"differs from the image's ({name})")

    def test_the_builder_records_the_inputs_as_the_installer_reads_them(self):
        self.write("etc/initcpio/hooks/omarchy-quiet-efivars", "run_hook() { :; }\n")
        (self.root / "etc/modprobe.d/nouveau.conf").symlink_to("/dev/null")
        builder = ROOT / "builder/build-root-image.sh"
        script = (
            "set -euo pipefail\n"
            f"eval \"$(sed -n '/^initramfs_inputs() {{$/,/^}}$/p' {builder})\"\n"
            'initramfs_inputs "$1"\n'
        )
        recorded = RUN(["bash", "-c", script, "_", str(self.root)], capture_output=True, text=True, check=True).stdout
        self.assertIn("etc/initcpio/hooks/omarchy-quiet-efivars", recorded)
        self.assertEqual(phases._recorded_initramfs_inputs(self.write("recorded", recorded)), phases._initramfs_inputs(self.root))


if __name__ == "__main__":
    unittest.main()
