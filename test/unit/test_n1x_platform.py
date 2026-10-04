"""aarch64 N1x images: platform kernel selection and the Limine console contract."""

import json
import re
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import context, phases_impl  # noqa: E402

ROOT_CMDLINE = (
    "cryptdevice=PARTUUID=f073914b-b386-4b56-b181-61ea375509ee:root root=/dev/mapper/root "
    "zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs"
)
KERNEL = "linux-omarchy-n1x"
RESCUE_CMDLINE = (
    f"{ROOT_CMDLINE} console=tty0 acpi=nospcr plymouth.enable=0 nomodeset "
    "systemd.unit=multi-user.target fbcon=map:0 loglevel=7"
)
NORMAL_CMDLINE = (
    " quiet splash loglevel=0 console=tty0 acpi=nospcr loglevel=7 systemd.show_status=1 "
    f"initramfs_async=0 {ROOT_CMDLINE}"
)


# Shaped like the limine.conf limine-entry-tool writes for linux-omarchy-n1x with
# its fallback UKI as the rescue entry.
def limine_conf(rescue_cmdline=RESCUE_CMDLINE, normal_cmdline=NORMAL_CMDLINE, rescue=True):
    rescue_entry = f"""\
  //linux-omarchy-n1x-fallback
  comment: Kernel version: 7.2.5-9-omarchy-n1x
  comment: kernel-id=linux-omarchy-n1x-fallback
  protocol: efi
  path: boot():/EFI/Linux/omarchy_linux-omarchy-n1x-fallback.efi#5187fcdd
  cmdline: {rescue_cmdline}
""" if rescue else ""
    return f"""\
timeout: 3
default_entry: 2

/+Omarchy
comment: Omarchy
  //linux-omarchy-n1x
  comment: Kernel version: 7.2.5-9-omarchy-n1x
  comment: kernel-id=linux-omarchy-n1x
  protocol: efi
  path: boot():/EFI/Linux/omarchy_linux-omarchy-n1x.efi#1ebecba8
  cmdline: {normal_cmdline}
{rescue_entry}
/EFI fallback
comment: Default EFI loader
protocol: efi
path: boot():/EFI/BOOT/BOOTAA64.EFI
"""


class PlatformKernelTest(unittest.TestCase):
    def test_configurator_selects_the_platform_kernel(self):
        configurator = (ROOT / "configs/airootfs/root/configurator").read_text()
        probe = re.search(r"^detect_kernel\(\) \{\n.*?^\}", configurator, re.M | re.S)
        self.assertIsNotNone(probe)
        for arch, kernel, expected in [("aarch64", KERNEL, KERNEL), ("x86_64", "", "linux-omarchy")]:
            with self.subTest(arch=arch):
                result = subprocess.run(
                    ["bash", "-c", f"lspci() {{ :; }}\niso_arch={arch}\niso_kernel={kernel}\n"
                     + probe.group() + "\ndetect_kernel"],
                    check=True, capture_output=True, text=True,
                )
                self.assertEqual(result.stdout.strip(), expected)

    def test_platform_kernel_is_installed(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(context._default_kernel(Path(tmp), platform_kernel=KERNEL), KERNEL)

    def test_no_platform_kernel_keeps_x86_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(context._default_kernel(Path(tmp), platform_kernel=""), "linux-omarchy")

    def test_kernel_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "omarchy_kernel"
            self.assertEqual(context.iso_kernel(path), "")
            path.write_text(f"{KERNEL}\n")
            self.assertEqual(context.iso_kernel(path), KERNEL)

    def test_platform_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "omarchy_arm_platform"
            self.assertEqual(context.iso_arm_platform(path), "")
            path.write_text("\n")
            self.assertEqual(context.iso_arm_platform(path), "")
            path.write_text("n1x\n")
            self.assertEqual(context.iso_arm_platform(path), "n1x")


class ConfiguratorMirrorsTest(unittest.TestCase):
    # The configurator pastes these lines into its user_configuration.json
    # heredocs; a stray backslash there made the N1x installer die on
    # "Invalid \\escape" before it touched the disk.
    def test_mirror_lines_are_valid_json_in_the_heredoc(self):
        configurator = (ROOT / "configs/airootfs/root/configurator").read_text()
        block = re.search(r"^if \[\[ \$iso_arch == aarch64 \]\]; then\n  limine_efi_binary=.*?^fi$", configurator, re.M | re.S)
        self.assertIsNotNone(block)
        for arch, first_url in [("aarch64", "http://mirror.archlinuxarm.org/$arch/$repo"),
                                ("x86_64", "https://mirror.omarchy.org/$repo/os/$arch")]:
            with self.subTest(arch=arch):
                script = (f"iso_arch={arch}\n" + block.group()
                          + '\ncat <<-_EOF_\n{"custom_servers": [\n$archinstall_custom_servers\n]}\n_EOF_\n')
                result = subprocess.run(["bash", "-c", script], check=True, capture_output=True, text=True)
                servers = json.loads(result.stdout)["custom_servers"]
                self.assertEqual(servers[0]["url"], first_url)


class NodeTarballTest(unittest.TestCase):
    def test_stages_the_tarball_for_the_running_cpu(self):
        for machine, bundled in [("aarch64", "node-v26.10.0-linux-arm64.tar.gz"), ("x86_64", "node-v26.10.0-linux-x64.tar.gz")]:
            with self.subTest(machine=machine), tempfile.TemporaryDirectory() as tmp:
                packages, provisioning = Path(tmp) / "packages", Path(tmp) / "provisioning"
                packages.mkdir()
                (packages / "node-v26.10.0-linux-arm64.tar.gz" if machine == "x86_64" else packages / "node-v26.10.0-linux-x64.tar.gz").write_text("other cpu")
                (packages / bundled).write_text("node")
                with mock.patch.object(phases_impl, "NODE_PACKAGES_DIR", packages), \
                        mock.patch.object(phases_impl.platform, "machine", return_value=machine):
                    phases_impl._stage_node_tarball(None, provisioning)
                self.assertEqual([p.name for p in (provisioning / "packages").iterdir()], [bundled])

    def test_missing_tarball_for_the_cpu_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            packages = Path(tmp)
            (packages / "node-v26.10.0-linux-x64.tar.gz").write_text("x86")
            with mock.patch.object(phases_impl, "NODE_PACKAGES_DIR", packages), \
                    mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"), \
                    self.assertRaisesRegex(RuntimeError, "no bundled Node tarball"):
                phases_impl._stage_node_tarball(None, packages / "provisioning")


class N1xLimineContractTest(unittest.TestCase):
    @staticmethod
    def validate(conf, arm_platform):
        phases_impl._validate_platform_boot_entries(conf, arm_platform, KERNEL)

    def test_generated_config_passes(self):
        self.validate(limine_conf(), "n1x")

    def test_other_platforms_are_not_checked(self):
        self.validate(limine_conf(normal_cmdline=ROOT_CMDLINE), "")

    def test_entry_without_panel_console_fails(self):
        with self.assertRaisesRegex(RuntimeError, "linux-omarchy-n1x lacks console=tty0"):
            self.validate(limine_conf(normal_cmdline=f"quiet splash acpi=nospcr {ROOT_CMDLINE}"), "n1x")

    def test_entry_without_nospcr_fails(self):
        with self.assertRaisesRegex(RuntimeError, "lacks acpi=nospcr"):
            self.validate(limine_conf(normal_cmdline=f"console=tty0 {ROOT_CMDLINE}"), "n1x")

    def test_parameter_must_be_a_whole_token(self):
        with self.assertRaisesRegex(RuntimeError, "lacks console=tty0"):
            self.validate(limine_conf(normal_cmdline=f"console=tty0,115200 acpi=nospcr {ROOT_CMDLINE}"), "n1x")

    def test_missing_rescue_entry_fails(self):
        with self.assertRaisesRegex(RuntimeError, "no linux-omarchy-n1x-fallback rescue entry"):
            self.validate(limine_conf(rescue=False), "n1x")

    # The 2026-09-03 failure: the rescue entry carried the normal cmdline, so
    # it booted the graphical target like the normal entry.
    def test_rescue_with_the_normal_cmdline_fails(self):
        with self.assertRaisesRegex(RuntimeError, "does not boot to a text login"):
            self.validate(limine_conf(rescue_cmdline=NORMAL_CMDLINE), "n1x")

    def test_rescue_with_plymouth_fails(self):
        with self.assertRaisesRegex(RuntimeError, "does not boot to a text login"):
            self.validate(limine_conf(rescue_cmdline=RESCUE_CMDLINE.replace(" plymouth.enable=0", "")), "n1x")

    def test_no_kernel_entries_fails(self):
        with self.assertRaisesRegex(RuntimeError, "no kernel entries"):
            self.validate("timeout: 3\n/EFI fallback\nprotocol: efi\npath: boot():/EFI/BOOT/BOOTAA64.EFI\n", "n1x")


class N1xHardwareGateTest(unittest.TestCase):
    # An N1x image installed somewhere that is not an N1x (a VM, say) gets the
    # generic aarch64 setup, so the N1x boot contract must not be enforced.
    def installed_platform(self, returncode):
        ctx = types.SimpleNamespace(target=Path("/mnt"))
        with mock.patch.object(phases_impl, "iso_arm_platform", return_value="n1x"), \
                mock.patch.object(phases_impl.subprocess, "run", return_value=mock.Mock(returncode=returncode)) as run, \
                mock.patch.object(phases_impl, "info"):
            platform = phases_impl._installed_arm_platform(ctx)
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0], ["arch-chroot", "/mnt", "omarchy-hw-n1x"])
        return platform

    def test_n1x_hardware_is_checked(self):
        self.assertEqual(self.installed_platform(0), "n1x")

    def test_other_hardware_is_not(self):
        self.assertEqual(self.installed_platform(1), "")


if __name__ == "__main__":
    unittest.main()
