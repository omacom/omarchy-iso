"""T2 targets must discard the baked stock kernel and validate linux-t2."""

import sys
import tempfile
import types
import unittest
from pathlib import Path
from subprocess import CompletedProcess
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


class RemoveBakedStockKernelForT2Test(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        self.target.mkdir()
        self.ctx = types.SimpleNamespace(target=self.target)
        self.packages = {"linux": True, "linux-t2": True}

        package_patch = mock.patch.object(
            phases_impl.arch,
            "target_has_package",
            side_effect=lambda _target, name: self.packages.get(name, False),
            create=True,
        )
        package_patch.start()
        self.addCleanup(package_patch.stop)
        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

    def config(self, *kernels):
        return types.SimpleNamespace(kernels=list(kernels))

    def remove_succeeds(self, command, **_kwargs):
        self.assertEqual(
            command,
            ["arch-chroot", str(self.target), "pacman", "-Rdd", "--noconfirm", "linux"],
        )
        self.packages["linux"] = False
        return CompletedProcess(command, 0, stdout="", stderr="")

    def test_t2_target_removes_baked_stock_kernel(self):
        with mock.patch.object(phases_impl.subprocess, "run", side_effect=self.remove_succeeds) as run:
            phases_impl._remove_baked_stock_kernel_for_t2(self.ctx, self.config("linux-t2"))

        run.assert_called_once()
        self.assertFalse(self.packages["linux"])

    def test_explicit_dual_kernel_target_keeps_both(self):
        with mock.patch.object(phases_impl.subprocess, "run") as run:
            phases_impl._remove_baked_stock_kernel_for_t2(
                self.ctx, self.config("linux", "linux-t2")
            )
        run.assert_not_called()

    def test_normal_target_keeps_baked_stock_kernel(self):
        with mock.patch.object(phases_impl.subprocess, "run") as run:
            phases_impl._remove_baked_stock_kernel_for_t2(self.ctx, self.config("linux"))
        run.assert_not_called()

    def test_t2_target_with_no_stock_kernel_is_already_clean(self):
        self.packages["linux"] = False
        with mock.patch.object(phases_impl.subprocess, "run") as run:
            phases_impl._remove_baked_stock_kernel_for_t2(self.ctx, self.config("linux-t2"))
        run.assert_not_called()

    def test_missing_selected_t2_kernel_fails_before_removal(self):
        self.packages["linux-t2"] = False
        with mock.patch.object(phases_impl.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "linux-t2 is not installed"):
                phases_impl._remove_baked_stock_kernel_for_t2(
                    self.ctx, self.config("linux-t2")
                )
        run.assert_not_called()

    def test_failed_stock_kernel_removal_is_fatal(self):
        failed = CompletedProcess([], 1, stdout="", stderr="dependency failure")
        with mock.patch.object(phases_impl.subprocess, "run", return_value=failed):
            with self.assertRaisesRegex(RuntimeError, "dependency failure"):
                phases_impl._remove_baked_stock_kernel_for_t2(
                    self.ctx, self.config("linux-t2")
                )

    def test_success_that_leaves_stock_kernel_is_fatal(self):
        completed = CompletedProcess([], 0, stdout="", stderr="")
        with mock.patch.object(phases_impl.subprocess, "run", return_value=completed):
            with self.assertRaisesRegex(RuntimeError, "remains installed"):
                phases_impl._remove_baked_stock_kernel_for_t2(
                    self.ctx, self.config("linux-t2")
                )


class T2BootValidationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"

        for kernel in ("linux", "linux-t2"):
            pkgbase = self.target / "usr/lib/modules" / f"1-{kernel}" / "pkgbase"
            pkgbase.parent.mkdir(parents=True, exist_ok=True)
            pkgbase.write_text(f"{kernel}\n")

        (self.target / "boot/EFI/limine").mkdir(parents=True)
        (self.target / "boot/EFI/limine/limine_x64.efi").write_bytes(b"efi")
        (self.target / "boot/EFI/Linux").mkdir()
        (self.target / "boot/EFI/Linux/omarchy_linux.efi").write_bytes(b"stock")
        (self.target / "boot/limine.conf").write_text("/Omarchy\n")
        (self.target / "etc/kernel").mkdir(parents=True)
        (self.target / "etc/kernel/cmdline").write_text("quiet\n")
        (self.target / "etc/default").mkdir(parents=True)
        (self.target / "etc/default/limine").write_text('CUSTOM_UKI_NAME="omarchy"\n')
        hook = self.target / phases_impl.UNENCRYPTED_HOOKS_DROPIN
        hook.parent.mkdir(parents=True, exist_ok=True)
        hook.write_text("HOOKS=()\n")

        self.ctx = types.SimpleNamespace(
            target=self.target,
            omarchy_install={"storage": {"kernel": "linux-t2"}},
            user_configuration={"disk_config": {}, "kernels": ["linux-t2"]},
            encrypt=False,
            is_protected=False,
            defer_provisioning=False,
        )

    def validate(self):
        with mock.patch.object(phases_impl, "_assert_boot_hooks_restored"), \
             mock.patch.object(phases_impl.arch, "has_uefi", return_value=True, create=True), \
             mock.patch.object(
                 phases_impl,
                 "_read_efibootmgr",
                 return_value={"entries": {"0001": "Limine"}, "order": ["0001"]},
             ):
            phases_impl.validate_boot(self.ctx)

    def test_stock_uki_cannot_hide_missing_t2_uki(self):
        with self.assertRaisesRegex(RuntimeError, "omarchy_linux-t2.efi.*missing or empty"):
            self.validate()

    def test_selected_t2_uki_passes(self):
        (self.target / "boot/EFI/Linux/omarchy_linux-t2.efi").write_bytes(b"t2")
        self.validate()

    def test_hardware_replacement_kernel_still_validates_from_disk(self):
        for kernel_dir in (self.target / "usr/lib/modules").iterdir():
            for child in kernel_dir.iterdir():
                child.unlink()
            kernel_dir.rmdir()
        pkgbase = self.target / "usr/lib/modules/1-linux-ptl/pkgbase"
        pkgbase.parent.mkdir(parents=True)
        pkgbase.write_text("linux-ptl\n")
        (self.target / "boot/EFI/Linux/omarchy_linux-ptl.efi").write_bytes(b"ptl")
        self.ctx.omarchy_install["storage"]["kernel"] = "linux"
        self.ctx.user_configuration["kernels"] = ["linux"]

        self.validate()


if __name__ == "__main__":
    unittest.main()
