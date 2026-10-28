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
from orchestrator import context, phases, phases_impl  # noqa: E402

ROOT_CMDLINE = (
    "cryptdevice=PARTUUID=f073914b-b386-4b56-b181-61ea375509ee:root root=/dev/mapper/root "
    "zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs"
)
PLAIN_ROOT_CMDLINE = "root=PARTUUID=f073914b-b386-4b56-b181-61ea375509ee zswap.enabled=0 rootflags=subvol=@ rw rootfstype=btrfs"
KERNEL = "linux-omarchy"
RESCUE_CMDLINE = (
    f"{ROOT_CMDLINE} console=tty0 acpi=nospcr plymouth.enable=0 nomodeset "
    "systemd.unit=multi-user.target fbcon=map:0 loglevel=7"
)
NORMAL_CMDLINE = (
    " quiet splash loglevel=0 console=tty0 acpi=nospcr loglevel=7 systemd.show_status=1 "
    f"initramfs_async=0 {ROOT_CMDLINE}"
)


# Shaped like the limine.conf limine-entry-tool writes for linux-omarchy with
# its fallback UKI as the rescue entry.
def limine_conf(rescue_cmdline=RESCUE_CMDLINE, normal_cmdline=NORMAL_CMDLINE, rescue=True):
    rescue_entry = f"""\
  //linux-omarchy-fallback
  comment: Kernel version: 7.2.8-8-omarchy
  comment: kernel-id=linux-omarchy-fallback
  protocol: efi
  path: boot():/EFI/Linux/omarchy_linux-omarchy-fallback.efi#5187fcdd
  cmdline: {rescue_cmdline}
""" if rescue else ""
    return f"""\
timeout: 3
default_entry: 2

/+Omarchy
comment: Omarchy
  //linux-omarchy
  comment: Kernel version: 7.2.8-8-omarchy
  comment: kernel-id=linux-omarchy
  protocol: efi
  path: boot():/EFI/Linux/omarchy_linux-omarchy.efi#1ebecba8
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

    def test_platform_detector(self):
        # x86_64 images carry no detector, and one that cannot tell names nothing.
        with tempfile.TemporaryDirectory() as tmp:
            detector = Path(tmp) / "omarchy-hw-platform"
            self.assertEqual(context.hw_platform(detector), "")
            detector.write_text("echo aarch64-qualcomm\n")
            self.assertEqual(context.hw_platform(detector), "aarch64-qualcomm")
            detector.write_text("echo aarch64-qualcomm; exit 1\n")
            self.assertEqual(context.hw_platform(detector), "")


class ConfiguratorMirrorsTest(unittest.TestCase):
    # The configurator pastes these lines into its user_configuration.json
    # heredocs; a stray backslash there made the N1x installer die on
    # "Invalid \\escape" before it touched the disk.
    def test_mirror_lines_are_valid_json_in_the_heredoc(self):
        configurator = (ROOT / "configs/airootfs/root/configurator").read_text()
        block = re.search(r"^if \[\[ \$iso_arch == aarch64 \]\]; then\n  limine_efi_binary=.*?^fi$", configurator, re.M | re.S)
        self.assertIsNotNone(block)
        for arch, first_url in [("aarch64", "https://arm-mirror.omarchy.org/$arch/$repo"),
                                ("x86_64", "https://mirror.omarchy.org/$repo/os/$arch")]:
            with self.subTest(arch=arch):
                script = (f"iso_arch={arch}\n" + block.group()
                          + '\ncat <<-_EOF_\n{"custom_servers": [\n$archinstall_custom_servers\n]}\n_EOF_\n')
                result = subprocess.run(["bash", "-c", script], check=True, capture_output=True, text=True)
                servers = json.loads(result.stdout)["custom_servers"]
                self.assertEqual(servers[0]["url"], first_url)


class N1xLimineContractTest(unittest.TestCase):
    @staticmethod
    def validate(conf, arm_platform):
        phases_impl._validate_platform_boot_entries(conf, arm_platform, KERNEL)

    def test_generated_config_passes(self):
        self.validate(limine_conf(), "n1x")

    def test_other_platforms_are_not_checked(self):
        self.validate(limine_conf(normal_cmdline=ROOT_CMDLINE), "")

    def test_entry_without_panel_console_fails(self):
        with self.assertRaisesRegex(RuntimeError, "linux-omarchy lacks console=tty0"):
            self.validate(limine_conf(normal_cmdline=f"quiet splash acpi=nospcr {ROOT_CMDLINE}"), "n1x")

    def test_entry_without_nospcr_fails(self):
        with self.assertRaisesRegex(RuntimeError, "lacks acpi=nospcr"):
            self.validate(limine_conf(normal_cmdline=f"console=tty0 {ROOT_CMDLINE}"), "n1x")

    def test_parameter_must_be_a_whole_token(self):
        with self.assertRaisesRegex(RuntimeError, "lacks console=tty0"):
            self.validate(limine_conf(normal_cmdline=f"console=tty0,115200 acpi=nospcr {ROOT_CMDLINE}"), "n1x")

    def test_missing_rescue_entry_fails(self):
        with self.assertRaisesRegex(RuntimeError, "no linux-omarchy-fallback rescue entry"):
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


class Aarch64ConsoleTest(unittest.TestCase):
    # arm64 firmware (the N1x, QEMU's virt machine) publishes an ACPI serial
    # console that would take the disk passphrase prompt off the screen.
    def write_defaults(self, machine):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        target = Path(tmp.name)
        templates = target / "usr/share/omarchy/default/limine"
        templates.mkdir(parents=True)
        (templates / "default.conf").write_text('KERNEL_CMDLINE[default]="@@CMDLINE@@"\nESP_PATH="/boot"\n')
        (templates / "limine.conf").write_text("timeout: 3\n")
        ctx = types.SimpleNamespace(target=target, omarchy_path=target / "omarchy")
        # luks_tuning needs archinstall, which only the live ISO has. A plain
        # root, which it passes through unchanged: the console drop-in does not
        # depend on encryption, and an encrypted cmdline needs the rd.luks.name=
        # luks_tuning adds (test_encrypted_cmdline.py).
        luks_tuning = types.SimpleNamespace(with_cmdline_options=lambda cmdline: cmdline)
        with mock.patch.object(phases_impl.platform, "machine", return_value=machine), \
                mock.patch.object(phases_impl.arch, "has_uefi", return_value=True, create=True), \
                mock.patch.dict(sys.modules, {"orchestrator.luks_tuning": luks_tuning}):
            phases_impl._write_limine_defaults(ctx, PLAIN_ROOT_CMDLINE, esp_mount="/boot")
        return target / "etc/limine-entry-tool.d" / phases_impl.AARCH64_CONSOLE_CONF

    def test_aarch64_keeps_the_console_on_the_screen(self):
        console_conf = self.write_defaults("aarch64")
        self.assertIn('KERNEL_CMDLINE[default]+=" console=tty0 acpi=nospcr"', console_conf.read_text())

    def test_x86_64_is_left_alone(self):
        self.assertFalse(self.write_defaults("x86_64").exists())


class PlatformPackageListTest(unittest.TestCase):
    # One image serves every board: the installer installs the default set of
    # the platform the machine is, and the plain one where it has none.
    def chosen(self, detected, *shipped):
        with tempfile.TemporaryDirectory() as tmp:
            share = Path(tmp)
            for name in ("omarchy-base.packages", *shipped):
                (share / name).write_text("")
            with mock.patch.object(phases_impl, "hw_platform", return_value=detected):
                return phases_impl._base_package_file(share).name

    def test_a_platform_gets_its_own_set(self):
        self.assertEqual(
            self.chosen("aarch64-qualcomm", "omarchy-base.aarch64-qualcomm.packages", "omarchy-base.aarch64-n1x.packages"),
            "omarchy-base.aarch64-qualcomm.packages",
        )

    def test_any_other_machine_gets_the_plain_set(self):
        self.assertEqual(self.chosen("aarch64", "omarchy-base.aarch64-n1x.packages"), "omarchy-base.packages")
        self.assertEqual(self.chosen("aarch64-gb10", "omarchy-base.aarch64-n1x.packages"), "omarchy-base.packages")
        self.assertEqual(self.chosen(""), "omarchy-base.packages")

    # The progress bar counts toward the set the machine really gets.
    def expected(self, detected):
        with tempfile.TemporaryDirectory() as tmp:
            share = Path(tmp)
            (share / "expected-packages").write_text("900\n")
            (share / "expected-packages.aarch64-n1x").write_text("960\n")
            with mock.patch.object(phases, "hw_platform", return_value=detected):
                return phases._expected_package_count(share)

    def test_the_package_count_follows_the_platform(self):
        self.assertEqual(self.expected("aarch64-n1x"), 960)
        self.assertEqual(self.expected("aarch64-qualcomm"), 900)
        self.assertEqual(self.expected(""), 900)

    # The image holds the plain set; a platform's set adds what it lacks.
    def delta(self, detected, platform_set, in_image):
        with tempfile.TemporaryDirectory() as tmp:
            share = Path(tmp)
            (share / "omarchy-base.packages").write_text("hyprland\n")
            (share / "omarchy-base.aarch64-n1x.packages").write_text(platform_set)
            with mock.patch.object(phases_impl, "hw_platform", return_value=detected), \
                    mock.patch.object(phases_impl.arch, "target_has_package",
                                      side_effect=lambda _target, name: name in in_image, create=True):
                return phases_impl._platform_delta_packages(Path("/mnt"), share)

    def test_a_platform_gets_what_its_set_adds_to_the_image(self):
        self.assertEqual(
            self.delta("aarch64-n1x", "# the N1x set\nhyprland\nnvidia-open\n\nnvidia-utils\nnvidia-open\n", {"hyprland"}),
            ["nvidia-open", "nvidia-utils"],
        )

    def test_a_machine_without_a_set_of_its_own_gets_nothing(self):
        self.assertEqual(self.delta("aarch64", "nvidia-open\n", {"hyprland"}), [])
        self.assertEqual(self.delta("", "nvidia-open\n", {"hyprland"}), [])


class PlatformBootTest(unittest.TestCase):
    # A board with a platform of its own keeps limine-mkinitcpio, which applies
    # its hardware scripts' boot rules; every other machine takes the image's
    # pre-built UKI.
    def platform_boot(self, machine, detected):
        with mock.patch.object(phases_impl.platform, "machine", return_value=machine), \
                mock.patch.object(phases_impl, "hw_platform", return_value=detected):
            return phases_impl._arm_platform_boot()

    def test_a_platform_board_builds_its_own_entries(self):
        self.assertTrue(self.platform_boot("aarch64", "aarch64-n1x"))
        self.assertTrue(self.platform_boot("aarch64", "aarch64-qualcomm"))

    def test_generic_aarch64_and_x86_64_take_the_image_uki(self):
        self.assertFalse(self.platform_boot("aarch64", "aarch64"))
        self.assertFalse(self.platform_boot("aarch64", ""))
        self.assertFalse(self.platform_boot("x86_64", ""))


class N1xHardwareGateTest(unittest.TestCase):
    # The same image installs every board, so the N1x boot contract is enforced
    # only where the target's own detector says the machine is one.
    def installed_platform(self, returncode, machine="aarch64"):
        ctx = types.SimpleNamespace(target=Path("/mnt"))
        with mock.patch.object(phases_impl.platform, "machine", return_value=machine), \
                mock.patch.object(phases_impl.subprocess, "run", return_value=mock.Mock(returncode=returncode)) as run:
            platform = phases_impl._installed_arm_platform(ctx)
        return platform, run

    def test_n1x_hardware_is_checked(self):
        platform, run = self.installed_platform(0)
        self.assertEqual(platform, "n1x")
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0], ["arch-chroot", "/mnt", "omarchy-hw-n1x"])

    def test_other_hardware_is_not(self):
        self.assertEqual(self.installed_platform(1)[0], "")

    def test_x86_64_is_never_asked(self):
        platform, run = self.installed_platform(0, machine="x86_64")
        self.assertEqual(platform, "")
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
