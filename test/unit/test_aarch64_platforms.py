import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path, PurePosixPath
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "configs/aarch64/platforms.json"

sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402


class Aarch64PlatformManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.document = json.loads(MANIFEST.read_text())
        cls.platforms = cls.document["platforms"]

    def test_schema_version_is_supported(self):
        self.assertEqual(self.document["schema_version"], 1)

    def test_platform_ids_and_dtbs_are_unique(self):
        ids = [platform["id"] for platform in self.platforms]
        dtbs = [
            platform["boot"]["dtb"]
            for platform in self.platforms
            if "dtb" in platform["boot"]
        ]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertEqual(len(dtbs), len(set(dtbs)))

    def test_each_platform_has_safe_boot_data(self):
        self.assertTrue(self.platforms)
        for platform in self.platforms:
            with self.subTest(platform=platform.get("id")):
                self.assertRegex(platform["id"], r"^[a-z0-9][a-z0-9-]*$")
                self.assertTrue(platform["name"].strip())
                self.assertTrue(platform["match"])

                for selector in platform["match"]:
                    self.assertTrue(selector)
                    self.assertLessEqual(
                        set(selector), {"sys_vendor", "product_name", "product_version"}
                    )
                    self.assertTrue(all(value.strip() for value in selector.values()))

                boot = platform["boot"]
                self.assertIn(
                    boot["hardware_description"], {"firmware", "dtb-override"}
                )
                if boot["hardware_description"] == "dtb-override":
                    dtb = PurePosixPath(boot["dtb"])
                    self.assertFalse(dtb.is_absolute())
                    self.assertNotIn("..", dtb.parts)
                    self.assertEqual(dtb.suffix, ".dtb")
                else:
                    self.assertNotIn("dtb", boot)

                for argument in boot["kernel_cmdline"]:
                    self.assertTrue(argument)
                    self.assertNotRegex(argument, r"\s")

                kernel = platform["kernel"]
                self.assertIn(kernel["availability"], {"iso", "vendor-required"})
                self.assertTrue(kernel.get("package") or kernel.get("family"))

                modules = platform.get("initramfs", {}).get("modules", [])
                self.assertEqual(len(modules), len(set(modules)))
                for module in modules:
                    self.assertRegex(module, r"^[A-Za-z0-9][A-Za-z0-9_-]*$")

                files = platform.get("initramfs", {}).get("files", [])
                self.assertEqual(len(files), len(set(files)))
                for file in files:
                    path = PurePosixPath(file)
                    self.assertTrue(path.is_absolute())
                    self.assertNotIn("..", path.parts)
                    self.assertTrue(str(path).startswith("/usr/lib/firmware/"))

                omitted_hooks = platform.get("initramfs", {}).get("omit_hooks", [])
                self.assertEqual(len(omitted_hooks), len(set(omitted_hooks)))
                for hook in omitted_hooks:
                    self.assertRegex(hook, r"^[a-z0-9][a-z0-9_-]*$")

                packages = platform.get("packages", [])
                self.assertEqual(len(packages), len(set(packages)))
                for package in packages:
                    self.assertRegex(package, r"^[a-z0-9][a-z0-9@._+-]*$")

    def test_yoga_initramfs_includes_typec_display_graph(self):
        """The MSM component graph needs the full Type-C stack before LUKS."""
        yoga = next(
            platform
            for platform in self.platforms
            if platform["id"] == "lenovo-yoga-slim7x"
        )

        required_modules = {
            "ps883x",
            "qrtr",
            "pmic_glink",
            "pmic_glink_altmode",
            "ucsi_glink",
        }
        self.assertLessEqual(required_modules, set(yoga["initramfs"]["modules"]))


class Aarch64PlatformMatchingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dmi = Path(self.tmp.name) / "dmi"
        self.dmi.mkdir()

    def write_dmi(self, vendor, product):
        (self.dmi / "sys_vendor").write_text(vendor + "\n")
        (self.dmi / "product_name").write_text(product + "\n")

    def matched(self):
        with (
            mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"),
            mock.patch.object(phases_impl, "AARCH64_PLATFORM_MANIFEST", MANIFEST),
            mock.patch.object(phases_impl, "DMI_ID_ROOT", self.dmi),
        ):
            return phases_impl._current_aarch64_platform()

    def test_matches_yoga_by_vendor_and_product(self):
        self.write_dmi("LENOVO", "83ED")
        self.assertEqual(self.matched()["id"], "lenovo-yoga-slim7x")

    def test_matches_dgx_spark(self):
        self.write_dmi("NVIDIA", "NVIDIA_DGX_Spark")
        matched = self.matched()
        self.assertEqual(matched["id"], "nvidia-dgx-spark")
        self.assertNotIn("dtb", matched["boot"])
        self.assertIn("nvidia-open-dkms", matched["packages"])

    def test_matches_asus_gx10(self):
        self.write_dmi("ASUSTeK COMPUTER INC.", "GX10")
        matched = self.matched()
        self.assertEqual(matched["id"], "asus-ascent-gx10")
        self.assertNotIn("dtb", matched["boot"])
        self.assertIn("nvidia-open-dkms", matched["packages"])

    def test_does_not_guess_from_product_name_alone(self):
        self.write_dmi("NOT NVIDIA", "NVIDIA_DGX_Spark")
        self.assertIsNone(self.matched())


class Aarch64LiminePlatformHookTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "target"
        self.esp = self.target / "boot"
        self.dtb = "qcom/x1e80100-lenovo-yoga-slim7x.dtb"
        (self.esp / "dtbs" / Path(self.dtb).parent).mkdir(parents=True)
        (self.esp / "dtbs" / self.dtb).write_bytes(b"\xd0\x0d\xfe\xedtest")
        self.ctx = types.SimpleNamespace(
            target=self.target,
            omarchy_install={"boot": {"esp_mount": "/boot"}},
            is_protected=False,
        )
        self.yoga = next(
            platform
            for platform in json.loads(MANIFEST.read_text())["platforms"]
            if platform["id"] == "lenovo-yoga-slim7x"
        )

    def configure(self):
        with (
            mock.patch.object(
                phases_impl, "_current_aarch64_platform", return_value=self.yoga
            ),
            mock.patch.object(phases_impl, "AARCH64_PLATFORM_MANIFEST", MANIFEST),
            mock.patch.object(phases_impl, "info"),
        ):
            return phases_impl._configure_aarch64_platform_boot(self.ctx)

    def test_installs_persistent_cmdline_and_dtb_hook(self):
        matched = self.configure()
        self.assertEqual(matched["id"], "lenovo-yoga-slim7x")

        dropin = self.target / "etc/limine-entry-tool.d/80-omarchy-aarch64-platform.conf"
        self.assertIn("clk_ignore_unused", dropin.read_text())
        self.assertIn("efi=noruntime", dropin.read_text())

        initramfs_dropin = (
            self.target
            / "etc/mkinitcpio.conf.d/zz-omarchy-aarch64-platform.conf"
        )
        initramfs_text = initramfs_dropin.read_text()
        self.assertIn("sbsa_gwdt", initramfs_text)
        self.assertIn("msm", initramfs_text)
        self.assertIn("ps883x", initramfs_text)
        self.assertIn("qrtr", initramfs_text)
        self.assertIn("pmic_glink", initramfs_text)
        self.assertIn("pmic_glink_altmode", initramfs_text)
        self.assertIn("ucsi_glink", initramfs_text)
        self.assertIn("i2c_hid_of", initramfs_text)
        self.assertIn("qcdxkmsuc8380.mbn", initramfs_text)
        result = subprocess.run(
            [
                "bash",
                "-c",
                'HOOKS=(base udev plymouth kms block encrypt); MODULES=(); source "$1"; '
                'printf "hooks=%s\\n" "${HOOKS[*]}"; '
                'printf "modules=%s\\n" "${MODULES[*]}"; '
                'printf "files=%s\\n" "${FILES[*]}"',
                "bash",
                str(initramfs_dropin),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertIn("hooks=base udev plymouth kms block encrypt", result.stdout)
        self.assertIn("modules=sbsa_gwdt msm", result.stdout)
        self.assertIn("ps883x", result.stdout)
        self.assertIn("qrtr", result.stdout)
        self.assertIn("pmic_glink", result.stdout)
        self.assertIn("pmic_glink_altmode", result.stdout)
        self.assertIn("ucsi_glink", result.stdout)
        self.assertIn("files=/usr/lib/firmware/qcom/gen70500_sqe.fw", result.stdout)

        hook = self.target / "etc/boot/hooks/post.d/80-omarchy-aarch64-platform"
        self.assertTrue(hook.stat().st_mode & 0o111)
        subprocess.run(["bash", "-n", str(hook)], check=True)

    def test_hook_adds_dtb_to_every_linux_entry_idempotently(self):
        self.configure()
        config = self.esp / "limine.conf"
        config.write_text(
            "/+Omarchy\n"
            "  //linux-aarch64\n"
            "  protocol: linux\n"
            "  path: boot():/vmlinuz\n"
            "  //fallback\n"
            "    protocol: linux\n"
            "    path: boot():/fallback\n"
        )
        hook = self.target / "etc/boot/hooks/post.d/80-omarchy-aarch64-platform"
        env = {**os.environ, "OMARCHY_LIMINE_ESP": str(self.esp)}
        subprocess.run([str(hook)], check=True, env=env)
        subprocess.run([str(hook)], check=True, env=env)

        text = config.read_text()
        expected = f"dtb_path: boot():/dtbs/{self.dtb}"
        self.assertEqual(text.count(expected), 2)
        self.assertIn(f"  {expected}", text)
        self.assertIn(f"    {expected}", text)


if __name__ == "__main__":
    unittest.main()
