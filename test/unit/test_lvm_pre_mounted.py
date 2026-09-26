"""Unit tests for the LVM install mode's orchestrator side.

Covers the three things that decide whether an install into existing logical
volumes survives its first reboot: the fstab written for an adopted /home and
swap, the mkinitcpio drop-in that lets the initramfs assemble the volume
group, and the validation that catches either one going missing.

The hazard behind the fstab tests: an adopted /home must REPLACE the @home
subvolume line, not join it. Two entries for /home mount two filesystems at
the same point, and the one that wins is not the one the owner asked to keep.
"""

import sys
import types
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl  # noqa: E402


ROOT_UUID = "11111111-1111-1111-1111-111111111111"
ESP_UUID = "2222-2222"
HOME_UUID = "33333333-3333-3333-3333-333333333333"
SWAP_UUID = "44444444-4444-4444-4444-444444444444"

UUIDS = {
    "/dev/pool/omarchy": ROOT_UUID,
    "/dev/nvme0n1p1": ESP_UUID,
    "/dev/pool/data": HOME_UUID,
    "/dev/pool/swap": SWAP_UUID,
}

TYPES = {
    "/dev/pool/data": "ext4",
}


class FakeContext:
    """Only what the fstab and drop-in writers actually read."""

    def __init__(self, target, storage):
        self.target = Path(target)
        self.is_protected = True
        self.omarchy_install = {
            "boot": {"esp_mount": "/boot"},
            "storage": storage,
        }


def storage_intent(**overrides):
    storage = {
        "esp_device": "/dev/nvme0n1p1",
        "root_device": "/dev/pool/omarchy",
        "root_mapper": "/dev/pool/omarchy",
        "kernel": "linux",
    }
    storage.update(overrides)
    return storage


def fake_blkid(argv, _description):
    tag, device = argv[2], argv[-1]
    if tag == "UUID":
        return UUIDS[device]
    return TYPES[device]


class LvmFstabTest(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name)
        (self.target / "etc").mkdir(parents=True)
        patcher = mock.patch.object(phases_impl, "capture_identifier", fake_blkid)
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, **overrides):
        ctx = FakeContext(self.target, storage_intent(**overrides))
        phases_impl._write_pre_mounted_fstab(ctx)
        return (self.target / "etc" / "fstab").read_text()

    def home_lines(self, fstab):
        return [line for line in fstab.splitlines() if " /home " in f" {line} "]

    def test_without_a_home_volume_the_home_subvolume_is_used(self):
        fstab = self.write()
        lines = self.home_lines(fstab)
        self.assertEqual(len(lines), 1)
        self.assertIn("subvol=@home", lines[0])
        self.assertIn(ROOT_UUID, lines[0])

    def test_an_adopted_home_replaces_the_home_subvolume(self):
        fstab = self.write(home_device="/dev/pool/data")
        lines = self.home_lines(fstab)
        self.assertEqual(len(lines), 1, f"exactly one /home entry expected:\n{fstab}")
        self.assertIn(HOME_UUID, lines[0])
        self.assertNotIn("subvol=@home", fstab)

    def test_an_adopted_home_keeps_its_own_filesystem_type(self):
        fstab = self.write(home_device="/dev/pool/data")
        self.assertIn("ext4", self.home_lines(fstab)[0])

    def test_the_root_subvolumes_are_unchanged_by_an_adopted_home(self):
        fstab = self.write(home_device="/dev/pool/data")
        for subvol in ("subvol=@ ", "subvol=@log", "subvol=@pkg"):
            self.assertIn(subvol, fstab)

    def test_an_adopted_swap_volume_is_written(self):
        fstab = self.write(swap_device="/dev/pool/swap")
        swap = [line for line in fstab.splitlines() if line.endswith("0 0") and "swap" in line]
        self.assertEqual(len(swap), 1)
        self.assertIn(SWAP_UUID, swap[0])

    def test_no_swap_line_without_a_swap_volume(self):
        self.assertNotIn("swap", self.write())


class LvmMkinitcpioDropinTest(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name)

    def dropin(self):
        return self.target / "etc/mkinitcpio.conf.d" / phases_impl.LVM_MKINITCPIO_DROPIN

    def test_no_dropin_when_the_install_is_not_on_lvm(self):
        phases_impl._write_lvm_mkinitcpio_dropin(FakeContext(self.target, storage_intent()))
        self.assertFalse(self.dropin().exists())

    def test_dropin_written_for_an_lvm_install(self):
        phases_impl._write_lvm_mkinitcpio_dropin(
            FakeContext(self.target, storage_intent(lvm_volume_group="pool"))
        )
        self.assertIn("lvm2", self.dropin().read_text())

    def test_the_dropin_sorts_after_the_hooks_file_it_must_survive(self):
        # omarchy-settings ships omarchy_hooks.conf, which ASSIGNS HOOKS=(...).
        # mkinitcpio sources drop-ins in lexical order, so a name sorting
        # before it is silently discarded. This is the whole reason for zz-.
        self.assertGreater(phases_impl.LVM_MKINITCPIO_DROPIN, "omarchy_hooks.conf")


class LvmEarlyPackagesTest(unittest.TestCase):
    """lvm2 must reach the target before the initramfs is built.

    Without it mkinitcpio cannot resolve the lvm2 hook, the build fails, and
    the install dies at "Validating boot setup" reporting a missing UKI — a
    symptom that names nothing about LVM, which is why this is pinned here.
    """

    def install(self, **overrides):
        installed = []
        fake_installer = mock.Mock()
        fake_installer.add_additional_packages.side_effect = lambda pkgs: installed.extend(pkgs)
        ctx = FakeContext("/nonexistent", storage_intent(**overrides))
        with mock.patch.object(phases_impl, "_early_bootstrap_packages", return_value=["base-devel"]), \
             mock.patch.object(phases_impl, "_early_user_seed_packages", return_value=[]), \
             mock.patch.object(phases_impl, "EARLY_LUAROCKS_PACKAGES", []), \
             mock.patch.object(phases_impl, "info"):
            phases_impl._install_early_packages(ctx, fake_installer)
        return installed

    def test_lvm_install_gets_lvm2(self):
        self.assertIn("lvm2", self.install(lvm_volume_group="pool"))

    def test_non_lvm_install_does_not(self):
        self.assertNotIn("lvm2", self.install())


class LvmValidationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name)
        (self.target / "etc").mkdir(parents=True)
        patcher = mock.patch.object(phases_impl, "capture_identifier", fake_blkid)
        patcher.start()
        self.addCleanup(patcher.stop)

    def context(self, **overrides):
        return FakeContext(self.target, storage_intent(**overrides))

    def test_a_missing_home_entry_is_rejected(self):
        ctx = self.context(home_device="/dev/pool/data")
        phases_impl._write_pre_mounted_fstab(ctx)
        fstab = self.target / "etc" / "fstab"
        fstab.write_text(fstab.read_text().replace(HOME_UUID, "not-the-home-uuid"))
        with self.assertRaises(RuntimeError) as caught:
            phases_impl._validate_pre_mounted_filesystems(ctx)
        self.assertIn(HOME_UUID, str(caught.exception))

    def test_a_missing_lvm_dropin_is_rejected(self):
        ctx = self.context(lvm_volume_group="pool")
        phases_impl._write_pre_mounted_fstab(ctx)
        with self.assertRaises(RuntimeError) as caught:
            phases_impl._validate_pre_mounted_filesystems(ctx)
        self.assertIn(phases_impl.LVM_MKINITCPIO_DROPIN, str(caught.exception))

    def test_a_complete_lvm_install_validates(self):
        ctx = self.context(
            lvm_volume_group="pool",
            home_device="/dev/pool/data",
            swap_device="/dev/pool/swap",
        )
        phases_impl._write_pre_mounted_fstab(ctx)
        phases_impl._write_lvm_mkinitcpio_dropin(ctx)
        phases_impl._validate_pre_mounted_filesystems(ctx)


if __name__ == "__main__":
    unittest.main()
