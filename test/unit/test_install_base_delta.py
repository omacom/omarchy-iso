"""install_base_delta against archinstall 4.4's and 4.5's Installer.

The adapter replays Installer.minimal_installation itself, so it calls the
Installer internals that minimal_installation calls, and those changed in 4.5:
_prepare_fs_type lost its mountpoint (archinstall/lib/installer.py, 4.4:878,
4.5:869), and minimal_installation enables _post_base_install_services after
the post-install hooks (4.5:978), an attribute 4.4 does not have. The stand-in
installers below take exactly those signatures.
"""

import shutil
import sys
import types
import unittest
from contextlib import nullcontext
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from archinstall_fakes import adapter  # noqa: E402


class Installer44:
    def __init__(self, target):
        self.target = target
        self.calls = []
        self._base_packages = []
        self._helper_flags = {}
        self._disable_fstrim = True
        self.post_base_install = [lambda installer: self.calls.append("post-install hook")]
        part = types.SimpleNamespace(fs_type="btrfs", mountpoint=Path("/"))
        self._disk_config = types.SimpleNamespace(
            lvm_config=None,
            device_modifications=[types.SimpleNamespace(partitions=[part])],
        )
        self._disk_encryption = types.SimpleNamespace(partitions=[])
        self.pacman = types.SimpleNamespace(strap=lambda packages: self.calls.append(("strap", packages)))

    def _prepare_fs_type(self, fs_type, mountpoint):
        self.calls.append(("prepare", fs_type, mountpoint))

    def _get_microcode(self):
        return None

    def enable_service(self, services):
        self.calls.append(("enable", services))


class Installer45(Installer44):
    def __init__(self, target, services):
        super().__init__(target)
        self._post_base_install_services = services

    def _prepare_fs_type(self, fs_type):
        self.calls.append(("prepare", fs_type))


class PacmanConfig:
    def __init__(self, target): pass
    def enable(self, repositories): pass
    def apply(self): pass
    def persist(self): pass


class InstallBaseDeltaTest(unittest.TestCase):
    def run_delta(self, installer):
        arch = self.enterContext(adapter({"archinstall.lib.pacman.config": {"PacmanConfig": PacmanConfig}}, version="4.5"))
        # install_base_delta times its steps with phases_impl's timer.
        timer = types.SimpleNamespace(_time_step=lambda name: nullcontext())
        self.enterContext(mock.patch.dict(sys.modules, {"orchestrator.phases_impl": timer}))
        config = types.SimpleNamespace(mirror_config=None, pacman_config=None)
        arch.install_base_delta(installer, config, hostname=None, locale_config=None)
        return installer.calls

    def target(self):
        return Path(self.enterContext(TemporaryDirectory()))

    def test_archinstall_44_gets_the_mountpoint(self):
        calls = self.run_delta(Installer44(self.target()))
        self.assertIn(("prepare", "btrfs", Path("/")), calls)
        self.assertNotIn("enable", [call[0] for call in calls if isinstance(call, tuple)])

    def test_archinstall_45_gets_no_mountpoint(self):
        calls = self.run_delta(Installer45(self.target(), []))
        self.assertIn(("prepare", "btrfs"), calls)

    def test_archinstall_45_enables_queued_services_after_the_hooks(self):
        calls = self.run_delta(Installer45(self.target(), ["iwd"]))
        self.assertEqual(calls[-2:], ["post-install hook", ("enable", ["iwd"])])

    def test_archinstall_45_with_no_queued_services_enables_nothing(self):
        calls = self.run_delta(Installer45(self.target(), []))
        self.assertEqual(calls[-1], "post-install hook")


class TargetPackagesTest(unittest.TestCase):
    """What the delta counts as already installed: what pacman says satisfies
    the name in the target's own database. The aarch64 image carries
    dotnet-runtime-bin where the default sets name dotnet-runtime."""

    def setUp(self):
        self.arch = self.enterContext(adapter())
        self.target = Path(self.enterContext(TemporaryDirectory()))

    def install(self, name, version, provides=()):
        local = self.target / "var/lib/pacman/local"
        (local / f"{name}-{version}").mkdir(parents=True)
        (local / "ALPM_DB_VERSION").write_text("9\n")
        desc = f"%NAME%\n{name}\n\n%VERSION%\n{version}\n\n"
        if provides:
            desc += "%PROVIDES%\n" + "".join(f"{p}\n" for p in provides) + "\n"
        (local / f"{name}-{version}" / "desc").write_text(desc)

    @unittest.skipUnless(shutil.which("pacman"), "needs pacman")
    def test_a_package_that_provides_the_name_counts(self):
        self.install("hyprland", "0.52.1-1")
        self.install("dotnet-runtime-bin", "10.0.403-1", ["dotnet-runtime=10.0.14", "dotnet-runtime-10.0"])
        names = ["dotnet-runtime", "hyprland", "nvidia-utils", "dotnet-runtime-10.0"]
        self.assertEqual(self.arch.target_missing_packages(self.target, names), ["nvidia-utils"])
        self.assertTrue(self.arch.target_has_package(self.target, "dotnet-runtime"))
        self.assertFalse(self.arch.target_has_package(self.target, "nvidia-utils"))

    def test_the_image_check_reads_names_not_what_they_provide(self):
        self.assertEqual(self.arch.target_package_names(self.target), set())
        self.install("omarchy-dev", "4.5.0.r7311.g2fca7fe-1", ["omarchy=4.5.0.r7311.g2fca7fe"])
        self.install("limine", "11.2.1-1")
        self.assertEqual(self.arch.target_package_names(self.target), {"omarchy-dev", "limine"})

    def test_no_names_or_no_database_asks_no_pacman(self):
        with mock.patch.object(self.arch, "capture") as capture:
            self.assertEqual(self.arch.target_missing_packages(self.target, []), [])
            self.assertEqual(self.arch.target_missing_packages(self.target, ["linux"]), ["linux"])
        capture.assert_not_called()
        self.assertFalse((self.target / "var").exists())


if __name__ == "__main__":
    unittest.main()
