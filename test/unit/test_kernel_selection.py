"""Fresh installs use the Omarchy kernel, except for T2 Macs."""

import json
import os
import re
import subprocess
import sys
import tempfile
import types
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import context, phases_impl  # noqa: E402


class KernelSelectionTest(unittest.TestCase):
    def test_hardware_detection(self):
        # Run the configurator's actual probe without starting its disk wizard.
        configurator = (ROOT / "configs/airootfs/root/configurator").read_text()
        probe = re.search(r"^detect_kernel\(\) \{\n.*?^\}", configurator, re.M | re.S)
        self.assertIsNotNone(probe)
        cases = [
            ("00:02.0 VGA compatible controller [0300]: Intel [8086:b080]", "linux-omarchy"),
            ("00:01.0 Ethernet controller [0200]: Apple [106b:2001]", "linux-omarchy"),
            ("04:00.0 Mass storage controller [0180]: Apple [106b:1801]", "linux-t2"),
            ("04:00.0 Mass storage controller [0180]: Apple [106b:1802]", "linux-t2"),
            ("", "linux-omarchy"),
        ]
        for devices, expected in cases:
            with self.subTest(devices=devices):
                result = subprocess.run(
                    ["bash", "-c", 'lspci() { printf "%s\\n" "$TEST_PCI"; }\n'
                     + probe.group() + "\ndetect_kernel"],
                    env={**os.environ, "TEST_PCI": devices},
                    check=True, capture_output=True, text=True,
                )
                self.assertEqual(result.stdout.strip(), expected)

    def test_unattended_kernel_default_uses_pci_hardware(self):
        for vendor, device, expected in [
            ("0x8086", "0xb080", "linux-omarchy"),
            ("0x106b", "0x2001", "linux-omarchy"),
            ("0x106b", "0x1801", "linux-t2"),
            ("0x106b", "0x1802", "linux-t2"),
        ]:
            with self.subTest(device=device), tempfile.TemporaryDirectory() as tmp:
                pci = Path(tmp)
                slot = pci / "0000:00:00.0"
                slot.mkdir()
                (slot / "vendor").write_text(vendor + "\n")
                (slot / "device").write_text(device + "\n")
                self.assertEqual(context._default_kernel(pci), expected)
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(context._default_kernel(Path(tmp)), "linux-omarchy")

    def test_context_passes_effective_kernels_to_archinstall(self):
        for config, default, expected in [
            ({}, "linux-omarchy", ["linux-omarchy"]),
            ({"kernels": []}, "linux-omarchy", ["linux-omarchy"]),
            ({"kernels": None}, "linux-t2", ["linux-t2"]),
            ({}, "linux-t2", ["linux-t2"]),
            ({"kernels": ["linux-lts"]}, "linux-omarchy", ["linux-lts"]),
            ({"kernels": ["linux-omarchy", "linux-lts"]}, "linux-t2", ["linux-omarchy", "linux-lts"]),
            ({"omarchy_install": {"storage": {"kernel": "linux-t2"}}}, "linux-omarchy", ["linux-t2"]),
        ]:
            with self.subTest(config=config, default=default), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                config_path = root / "config.json"
                creds_path = root / "creds.json"
                config_path.write_text(json.dumps(config))
                creds_path.write_text(json.dumps({"users": [{"username": "test"}]}))
                with mock.patch.dict(os.environ, {
                    "OMARCHY_INSTALL_CONFIG": str(config_path),
                    "OMARCHY_INSTALL_CREDS": str(creds_path),
                    "OMARCHY_INSTALL_STATE_DIR": str(root / "state"),
                }, clear=True), mock.patch.object(context, "_default_kernel", return_value=default):
                    ctx = context.InstallContext.from_env()
                self.assertEqual(ctx.user_configuration["kernels"], expected)
                self.assertEqual(json.loads(ctx.arch_config_path.read_text())["kernels"], expected)

    def test_headers_install_before_dkms_packages(self):
        for kernels in (["linux-omarchy"], ["linux-t2"], ["linux-omarchy", "linux-lts"]):
            for fail_headers in (False, True):
                with self.subTest(kernels=kernels, fail_headers=fail_headers), ExitStack() as stack:
                    events = []
                    installer = mock.MagicMock()
                    installer.minimal_installation.side_effect = lambda **kwargs: events.append("base")

                    def install_packages(packages):
                        events.append(packages)
                        if fail_headers:
                            raise RuntimeError("header install failed")

                    installer.add_additional_packages.side_effect = install_packages
                    config = types.SimpleNamespace(
                        kernels=kernels, locale_config=None, mirror_config=None,
                        swap=None, auth_config=None, app_config=None, timezone=None,
                        ntp=False, hostname="test", pacman_config="/etc/pacman.conf",
                    )
                    ctx = types.SimpleNamespace(
                        state={"arch_config_handler": types.SimpleNamespace(config=config), "mirror_handler": None},
                        target=Path("/unused"), tailscale_authkey_path=None, omarchy_install={},
                    )
                    for name in ("_mount_offline_package_cache", "_mask_mkinitcpio_pacman_hooks",
                                 "_configure_limine_boot", "_write_pre_mounted_fstab"):
                        stack.enter_context(mock.patch.object(phases_impl, name))
                    unmask = stack.enter_context(mock.patch.object(phases_impl, "_unmask_mkinitcpio_pacman_hooks"))
                    unmount = stack.enter_context(mock.patch.object(phases_impl, "_unmount_offline_package_cache"))
                    stack.enter_context(mock.patch.object(phases_impl, "configure_keyboard", return_value=True))
                    stack.enter_context(mock.patch.object(phases_impl, "_install_early_packages", side_effect=lambda inst: events.append("early")))
                    stack.enter_context(mock.patch.object(phases_impl, "_runtime_package_list", return_value=["omarchy"]))
                    stack.enter_context(mock.patch.object(phases_impl.arch, "is_pre_mount", return_value=True, create=True))
                    stack.enter_context(mock.patch.object(phases_impl.arch, "root_user", return_value=None, create=True))
                    opened = stack.enter_context(mock.patch.object(phases_impl.arch, "open_installer", create=True))
                    opened.return_value.__enter__.return_value = installer
                    if fail_headers:
                        with self.assertRaisesRegex(RuntimeError, "header install failed"):
                            phases_impl.arch_install_system(ctx)
                    else:
                        phases_impl.arch_install_system(ctx)
                    expected = ["base", [f"{kernel}-headers" for kernel in kernels]]
                    if not fail_headers:
                        expected += ["early", ["omarchy"]]
                    self.assertEqual(events, expected)
                    unmask.assert_called_once_with(ctx)
                    unmount.assert_called_once_with(ctx)

    def test_validation_rejects_missing_or_mismatched_headers(self):
        for kernel in ("linux-omarchy", "linux-t2"):
            with self.subTest(kernel=kernel), tempfile.TemporaryDirectory() as tmp:
                target = Path(tmp)
                ctx = types.SimpleNamespace(target=target)
                with self.assertRaisesRegex(RuntimeError, "no installed kernel"):
                    phases_impl._validate_kernel_headers(ctx)
                modules = target / "usr/lib/modules/7.2-test"
                modules.mkdir(parents=True)
                (modules / "pkgbase").write_text(kernel + "\n")
                with self.assertRaisesRegex(RuntimeError, "no kernel headers"):
                    phases_impl._validate_kernel_headers(ctx)
                header_release = modules / "build/include/config/kernel.release"
                header_release.parent.mkdir(parents=True)
                header_release.write_text("7.2-stock\n")
                with self.assertRaisesRegex(RuntimeError, "headers do not match"):
                    phases_impl._validate_kernel_headers(ctx)
                header_release.write_text("7.2-test\n")
                phases_impl._validate_kernel_headers(ctx)

    def test_boot_validation_uses_default_or_explicit_kernel(self):
        for storage, configuration, expected in [
            ({}, {}, "linux-omarchy"),
            ({}, {"kernels": ["linux-t2"]}, "linux-t2"),
            ({"kernel": "linux-t2"}, {"kernels": ["linux-omarchy"]}, "linux-t2"),
            ({}, {"kernels": ["linux-lts"]}, "linux-lts"),
        ]:
            with self.subTest(kernel=expected, storage=storage), tempfile.TemporaryDirectory() as tmp:
                target = Path(tmp)
                files = {
                    f"usr/lib/modules/7.2-test/pkgbase": expected + "\n",
                    "usr/lib/modules/7.2-test/build/include/config/kernel.release": "7.2-test\n",
                    "boot/limine.conf": "/Omarchy\n",
                    "etc/kernel/cmdline": "root=UUID=test\n",
                    "etc/default/limine": "CUSTOM_UKI_NAME=omarchy\n",
                    "boot/EFI/limine/limine_x64.efi": "bootloader",
                    f"boot/EFI/Linux/omarchy_{expected}.efi": "UKI",
                }
                for name, content in files.items():
                    path = target / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text(content)
                ctx = types.SimpleNamespace(
                    target=target, omarchy_install={"storage": storage},
                    user_configuration=configuration, encrypt=False,
                    is_protected=False, defer_provisioning=False,
                )
                with mock.patch.object(phases_impl, "_assert_boot_hooks_restored"), \
                     mock.patch.object(phases_impl.arch, "has_uefi", return_value=True, create=True), \
                     mock.patch.object(phases_impl, "_read_efibootmgr", return_value={
                         "entries": {"0001": "Limine\tHD(1,GPT,test)"},
                     }):
                    phases_impl.validate_boot(ctx)
                    (target / f"boot/EFI/Linux/omarchy_{expected}.efi").unlink()
                    with self.assertRaisesRegex(RuntimeError, "missing or empty"):
                        phases_impl.validate_boot(ctx)


if __name__ == "__main__":
    unittest.main()
