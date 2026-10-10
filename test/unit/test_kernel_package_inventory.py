"""The offline roots must supply the kernel and headers chosen by the installer."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
from orchestrator import context  # noqa: E402


class KernelPackageInventoryTest(unittest.TestCase):
    def check_inventory(self, package_lists):
        for target in ("aarch64/snapdragon", "aarch64/generic", "x86_64/pc"):
            arch = target.split("/")[0]
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                with mock.patch.object(context.platform, "machine", return_value=arch):
                    kernel = context._default_kernel(Path(tmp))
                result = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", '''
source "$1/builder/architecture.sh"
source "$1/builder/filter-packages.sh"
shift
offline_package_roots <(printf '%s\n' "$ISO_KERNEL") "$@"
''', "inventory", str(ROOT), *map(str, package_lists),
                     str(ROOT / "builder/archinstall.packages")],
                    env={**os.environ, "OMARCHY_ARCH": arch, "OMARCHY_MEDIA_TARGET": target,
                         "OMARCHY_RUNTIME_PACKAGE": "omarchy-dev",
                         "OMARCHY_SETTINGS_PACKAGE": "omarchy-settings-dev",
                         "OMARCHY_NVIM_PACKAGE": "omarchy-nvim"},
                    check=True, capture_output=True, text=True,
                )
                roots = set(result.stdout.splitlines())
                # Require both before platform extras: Spark's extra headers must
                # not conceal their absence from Snapdragon's common inventory.
                self.assertIn(kernel, roots)
                self.assertIn(f"{kernel}-headers", roots)
                if arch == "aarch64":
                    self.assertTrue({"linux-omarchy", "linux-omarchy-headers"}.isdisjoint(roots))
                else:
                    self.assertTrue({"linux-aarch64", "linux-aarch64-headers"}.isdisjoint(roots))

    def test_default_kernel_and_headers_for_each_media_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            packages = Path(tmp) / "runtime.packages"
            packages.write_text("# Runtime default kernel\nlinux-omarchy\nlinux-omarchy-headers\n")
            self.check_inventory([packages])

    @unittest.skipUnless(os.environ.get("OMARCHY_RUNTIME_PATH"),
                         "set OMARCHY_RUNTIME_PATH to check real runtime package lists")
    def test_actual_runtime_package_lists(self):
        runtime = Path(os.environ["OMARCHY_RUNTIME_PATH"])
        lists = [runtime / "install" / name for name in
                 ("omarchy-base.packages", "omarchy-other.packages")]
        for path in lists:
            self.assertTrue(path.is_file(), f"Missing runtime package list: {path}")
        self.check_inventory(lists)
