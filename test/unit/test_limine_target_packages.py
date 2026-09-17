"""Limine target packages must not depend on the runtime's architecture deps."""

from pathlib import Path
import sys
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import phases_impl as phases  # noqa: E402

TARGET_PACKAGES = ("limine-mkinitcpio-hook", "limine-snapper-sync", "snapper")


class LimineTargetPackagesTest(unittest.TestCase):
    def runtime_packages(self, arch, runtime="omarchy", base="base\n", platform_packages=()):
        ctx = types.SimpleNamespace(state={"hardware_platform": {"packages": list(platform_packages)}})
        targets = {"runtime": runtime, "settings": runtime.replace("omarchy", "omarchy-settings"),
                   "nvim": "omarchy-nvim"}
        with mock.patch.object(phases.platform, "machine", return_value=arch), \
             mock.patch.object(phases, "_package_targets", return_value=targets), \
             mock.patch.object(Path, "read_text", return_value=base):
            return phases._runtime_package_list(ctx)

    def test_boot_stack_is_selected_for_both_architectures_and_package_channels(self):
        for arch in ("aarch64", "x86_64"):
            for runtime in ("omarchy", "omarchy-dev"):
                with self.subTest(arch=arch, runtime=runtime):
                    packages = self.runtime_packages(arch, runtime)
                    self.assertEqual(packages[0], runtime)
                    for package in TARGET_PACKAGES:
                        self.assertIn(package, packages)
                    # Limine itself is already installed in the early phase.
                    self.assertNotIn("limine", packages)

    def test_existing_base_and_platform_selections_are_not_duplicated(self):
        base = "# defaults\nbase\nlimine\n" + "\n".join(TARGET_PACKAGES)
        for arch in ("aarch64", "x86_64"):
            with self.subTest(arch=arch):
                packages = self.runtime_packages(arch, base=base, platform_packages=TARGET_PACKAGES)
                self.assertEqual(len(packages), len(set(packages)))
                for package in TARGET_PACKAGES:
                    self.assertEqual(packages.count(package), 1)

    def test_boot_stack_is_bundled_offline_but_not_installed_in_the_live_root(self):
        bundled = (ROOT / "builder/archinstall.packages").read_text().splitlines()
        live = (ROOT / "configs/packages.aarch64").read_text().splitlines()
        for package in TARGET_PACKAGES:
            with self.subTest(package=package):
                self.assertIn(package, bundled)
                self.assertNotIn(package, live)
                self.assertNotIn(package, phases._early_bootstrap_packages())


if __name__ == "__main__":
    unittest.main()
