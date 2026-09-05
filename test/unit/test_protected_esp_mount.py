#!/usr/bin/python

"""Regression coverage for the protected/pre-mounted ESP handoff."""

import sys
import subprocess
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

# The live ISO supplies archinstall; unit tests only need the adapter symbol.
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402


class ProtectedEspMountTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        self.target.mkdir()
        self.esp_device = Path(self.tmp.name) / "esp-device"
        self.esp_device.touch()
        self.ctx = types.SimpleNamespace(
            target=self.target,
            is_protected=True,
            omarchy_install={
                "mode": "protected",
                "boot": {"esp_mount": "/boot"},
                "storage": {
                    "esp_device": str(self.esp_device),
                    "root_device": str(self.target),
                    "kernel": "linux-aarch64",
                },
            },
        )

    def test_prepare_target_mounts_an_absent_esp_before_install(self):
        esp_mount = self.target / "boot"
        mounted = False

        def is_mountpoint(path):
            if path == self.target:
                return True
            if path == esp_mount:
                return mounted
            return False

        def run(command, **kwargs):
            nonlocal mounted
            self.assertEqual(command, ["mount", str(self.esp_device), str(esp_mount)])
            self.assertTrue(kwargs["check"])
            mounted = True

        with (
            mock.patch.object(phases_impl, "_is_mountpoint", side_effect=is_mountpoint),
            mock.patch.object(phases_impl.subprocess, "run", side_effect=run) as run_mock,
            mock.patch.object(phases_impl, "info"),
        ):
            phases_impl.prepare_install_target(self.ctx)

        self.assertTrue(mounted)
        self.assertTrue(esp_mount.is_dir())
        run_mock.assert_called_once()

    def test_prepare_target_stops_if_mount_did_not_take_effect(self):
        def is_mountpoint(path):
            return path == self.target

        with (
            mock.patch.object(phases_impl, "_is_mountpoint", side_effect=is_mountpoint),
            mock.patch.object(phases_impl.subprocess, "run"),
            mock.patch.object(phases_impl, "info"),
            self.assertRaisesRegex(RuntimeError, "mount reported success"),
        ):
            phases_impl.prepare_install_target(self.ctx)

    def test_pre_mounted_arch_config_rechecks_esp_even_without_protected_mode(self):
        # disk_config.config_type is what tells archinstall not to mount a
        # layout.  The ESP safeguard must follow that fact rather than rely
        # solely on the separate Omarchy mode label agreeing with it.
        config = object()
        ctx = types.SimpleNamespace(
            target=self.target,
            is_protected=False,
            state={
                "arch_config_handler": types.SimpleNamespace(config=config),
                "mirror_handler": object(),
            },
        )

        with (
            mock.patch.object(
                phases_impl.arch, "is_pre_mount", return_value=True, create=True
            ),
            mock.patch.object(phases_impl, "verify_protected_mounts") as verify,
            mock.patch.object(
                phases_impl.arch,
                "open_installer",
                side_effect=RuntimeError("stop after mount boundary"),
                create=True,
            ),
            mock.patch.object(phases_impl, "info"),
            self.assertRaisesRegex(RuntimeError, "stop after mount boundary"),
        ):
            phases_impl.arch_install_system(ctx)

        verify.assert_called_once_with(ctx)


class Aarch64LimineKernelLayoutTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        (self.target / "etc/mkinitcpio.d").mkdir(parents=True)
        (self.target / "boot").mkdir()
        self.kver = "7.2.2-2-aarch64-ARCH"
        (self.target / "usr/lib/modules" / self.kver).mkdir(parents=True)
        hook = self.target / "usr/share/libalpm/scripts/limine-mkinitcpio-install"
        hook.parent.mkdir(parents=True)
        hook.write_text(
            'process_kernel() {\n'
            '  pacman -Qqo "$pkgbase_file" &>/dev/null || return 0\n'
            '}\n'
        )
        (self.target / "etc/mkinitcpio.d/linux-aarch64.preset").write_text(
            f'ALL_kver="{self.kver}"\n'
        )
        (self.target / "boot/Image").write_bytes(b"arm64-kernel-image")
        self.ctx = types.SimpleNamespace(target=self.target)

    def test_bridges_alarm_kernel_layout_for_limine_discovery(self):
        with (
            mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"),
            mock.patch.object(phases_impl, "info"),
        ):
            phases_impl._prepare_aarch64_limine_kernel_layout(self.ctx)

        modules = self.target / "usr/lib/modules" / self.kver
        self.assertEqual((modules / "pkgbase").read_text(), "linux-aarch64\n")
        self.assertEqual(
            (modules / "vmlinuz").read_bytes(),
            (self.target / "boot/Image").read_bytes(),
        )
        self.assertEqual(phases_impl._installed_kernels(self.ctx), ["linux-aarch64"])
        hook = self.target / "usr/share/libalpm/scripts/limine-mkinitcpio-install"
        hook_text = hook.read_text()
        self.assertIn('$(<"$pkgbase_file") == "linux-aarch64"', hook_text)
        self.assertIn("pacman -Q linux-aarch64", hook_text)
        self.assertNotIn(
            'pacman -Qqo "$pkgbase_file" &>/dev/null || return 0', hook_text
        )
        subprocess.run(["bash", "-n", str(hook)], check=True)

        compat = self.target / "etc/mkinitcpio.conf.d/zz-omarchy-module-compat.conf"
        self.assertTrue(compat.exists())
        compat_text = compat.read_text()
        self.assertIn('modinfo -k "$KERNELVERSION" thunderbolt', compat_text)
        self.assertIn('[[ $_omarchy_module == thunderbolt ]]', compat_text)
        subprocess.run(["bash", "-n", str(compat)], check=True)

    def test_current_limine_modules_builtin_discovery_needs_no_patch(self):
        hook = self.target / "usr/share/libalpm/scripts/limine-mkinitcpio-install"
        current_hook = (
            'process_kernel() {\n'
            '  local kernel_dir="$1" kernel_name=""\n'
            '  [[ -f "${kernel_dir}/modules.builtin" ]] || return 0\n'
            '  kernel_name="$(pacman -Qqo "${kernel_dir}/modules.builtin" '
            '2>/dev/null)" || return 0\n'
            '  set_kernel_context "$kernel_dir" "$kernel_name" || return 0\n'
            '}\n'
        )
        hook.write_text(current_hook)
        modules = self.target / "usr/lib/modules" / self.kver
        (modules / "modules.builtin").write_text("kernel/drivers/test.ko\n")

        with (
            mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"),
            mock.patch.object(phases_impl, "info"),
        ):
            phases_impl._prepare_aarch64_limine_kernel_layout(self.ctx)

        self.assertEqual(hook.read_text(), current_hook)
        self.assertEqual((modules / "pkgbase").read_text(), "linux-aarch64\n")
        self.assertEqual((modules / "vmlinuz").read_bytes(), b"arm64-kernel-image")
        subprocess.run(["bash", "-n", str(hook)], check=True)

    def test_missing_alarm_image_fails_before_limine_update(self):
        (self.target / "boot/Image").unlink()

        with (
            mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"),
            self.assertRaisesRegex(RuntimeError, "kernel image missing or empty"),
        ):
            phases_impl._prepare_aarch64_limine_kernel_layout(self.ctx)

    def test_compat_dropin_filters_only_a_module_missing_from_selected_kernel(self):
        with (
            mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"),
            mock.patch.object(phases_impl, "info"),
        ):
            phases_impl._prepare_aarch64_limine_kernel_layout(self.ctx)

        compat = self.target / "etc/mkinitcpio.conf.d/zz-omarchy-module-compat.conf"
        command = r'''
MODULES=(nvme thunderbolt qcom_q6v5_pas)
KERNELVERSION=test-kernel
modinfo() { return 1; }
source "$1"
printf '%s\n' "${MODULES[@]}"
'''
        result = subprocess.run(
            ["bash", "-c", command, "bash", str(compat)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.stdout.splitlines(), ["nvme", "qcom_q6v5_pas"])

    def test_compat_dropin_runs_after_thunderbolt_default(self):
        with (
            mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"),
            mock.patch.object(phases_impl, "info"),
        ):
            phases_impl._prepare_aarch64_limine_kernel_layout(self.ctx)

        conf_dir = self.target / "etc/mkinitcpio.conf.d"
        (conf_dir / "thunderbolt_module.conf").write_text(
            "MODULES+=(thunderbolt)\n"
        )
        names = [path.name for path in conf_dir.glob("*.conf")]
        ordered = subprocess.run(
            ["sort", "-V"],
            input="\n".join(names) + "\n",
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
        self.assertLess(
            ordered.index("thunderbolt_module.conf"),
            ordered.index("zz-omarchy-module-compat.conf"),
        )

        command = r'''
MODULES=(nvme)
KERNELVERSION=test-kernel
modinfo() { return 1; }
for config in "$@"; do source "$config"; done
printf '%s\n' "${MODULES[@]}"
'''
        result = subprocess.run(
            ["bash", "-c", command, "bash", *[str(conf_dir / name) for name in ordered]],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.stdout.splitlines(), ["nvme"])

    def test_compat_dropin_keeps_thunderbolt_when_selected_kernel_has_it(self):
        with (
            mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"),
            mock.patch.object(phases_impl, "info"),
        ):
            phases_impl._prepare_aarch64_limine_kernel_layout(self.ctx)

        compat = self.target / "etc/mkinitcpio.conf.d/zz-omarchy-module-compat.conf"
        command = r'''
MODULES=(nvme thunderbolt)
KERNELVERSION=test-kernel
modinfo() { return 0; }
source "$1"
printf '%s\n' "${MODULES[@]}"
'''
        result = subprocess.run(
            ["bash", "-c", command, "bash", str(compat)],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.stdout.splitlines(), ["nvme", "thunderbolt"])

    def test_non_arm_target_is_unchanged(self):
        with mock.patch.object(phases_impl.platform, "machine", return_value="x86_64"):
            phases_impl._prepare_aarch64_limine_kernel_layout(self.ctx)

        modules = self.target / "usr/lib/modules" / self.kver
        self.assertFalse((modules / "pkgbase").exists())
        self.assertFalse((modules / "vmlinuz").exists())
        self.assertFalse(
            (self.target / "etc/mkinitcpio.conf.d/zz-omarchy-module-compat.conf").exists()
        )


class LimineUkiConfigurationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        (self.target / "usr/share/omarchy/default/limine").mkdir(parents=True)
        (self.target / "usr/share/omarchy/default/limine/default.conf").write_text(
            'ESP_PATH="/boot"\nKERNEL_CMDLINE[default]+="@@CMDLINE@@"\n'
        )
        (self.target / "usr/share/omarchy/default/limine/limine.conf").write_text(
            "Omarchy\n"
        )
        self.ctx = types.SimpleNamespace(
            target=self.target,
            omarchy_path=Path(self.tmp.name) / "unused",
        )

    def test_explicit_uki_false_overrides_installed_omarchy_default(self):
        config = types.SimpleNamespace(
            bootloader_config=types.SimpleNamespace(uki=False)
        )
        with mock.patch.object(phases_impl.arch, "has_uefi", return_value=True, create=True):
            phases_impl._write_limine_defaults(
                self.ctx,
                "root=/dev/mapper/omarchy_root",
                esp_mount="/boot",
                enable_uki=phases_impl._configured_uki(config),
            )

        defaults = (self.target / "etc/default/limine").read_text()
        self.assertIn("ENABLE_UKI=no", defaults)

    def test_unspecified_uki_does_not_override_package_default(self):
        config = types.SimpleNamespace(
            bootloader_config=types.SimpleNamespace(uki=None)
        )
        with mock.patch.object(phases_impl.arch, "has_uefi", return_value=True, create=True):
            phases_impl._write_limine_defaults(
                self.ctx,
                "root=/dev/mapper/omarchy_root",
                esp_mount="/boot",
                enable_uki=phases_impl._configured_uki(config),
            )

        defaults = (self.target / "etc/default/limine").read_text()
        self.assertNotIn("ENABLE_UKI=", defaults)


if __name__ == "__main__":
    unittest.main()
