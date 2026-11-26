"""The target's region comes from its timezone, using the runtime's profiles,
and falls back to the media's region (a --preset ISO's) for any timezone no
profile lists."""

import json
import os
import shutil
import sys
import tempfile
import types
import unittest
from contextlib import ExitStack
from itertools import product
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import context, phases_impl, region  # noqa: E402


def write_profiles(root: Path) -> Path:
    regions = root / "regions"
    for profile in ("global", "cn"):
        (regions / profile).mkdir(parents=True)
    (regions / "global/timezones").write_text("Asia/Hong_Kong\nHongkong\nAsia/Macau\nAsia/Macao\nAsia/Taipei\nROC\n")
    (regions / "cn/timezones").write_text("# China\nAsia/Shanghai\n\n  Asia/Urumqi  \n")
    return regions


class RegionSelectionTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.regions = write_profiles(self.root)
        self.preset = self.root / "preset.json"
        for name, value in (("REGIONS_DIR", self.regions), ("PRESET", self.preset)):
            patcher = mock.patch.object(region, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_timezone_selects_region(self):
        for timezone, expected in [
            ("Asia/Shanghai", "cn"),
            ("Asia/Urumqi", "cn"),
            # The global profile lists Hong Kong, Macau and Taiwan.
            ("Asia/Hong_Kong", "global"),
            ("Hongkong", "global"),
            ("Asia/Macau", "global"),
            ("Asia/Macao", "global"),
            ("Asia/Taipei", "global"),
            ("ROC", "global"),
            ("America/New_York", "global"),
            ("UTC", "global"),
            ("# China", "global"),
            ("", "global"),
            (None, "global"),
        ]:
            with self.subTest(timezone=timezone):
                self.assertEqual(region.resolve_region({}, timezone), expected)

    def test_media_region_holds_where_no_profile_claims_the_timezone(self):
        # A China ISO used abroad stays China, but Hong Kong, Macau and Taiwan
        # are global on every media.
        self.preset.write_text(json.dumps({"language": "zh-CN", "region": "cn"}))
        for timezone, expected in [
            ("Asia/Shanghai", "cn"),
            ("America/New_York", "cn"),
            ("UTC", "cn"),
            (None, "cn"),
            ("Asia/Hong_Kong", "global"),
            ("Asia/Taipei", "global"),
            ("Asia/Macau", "global"),
        ]:
            with self.subTest(timezone=timezone):
                self.assertEqual(region.resolve_region({}, timezone), expected)
        # A preset without a region is global media; one naming a region this
        # ISO lacks is refused.
        self.preset.write_text(json.dumps({"language": "zh-CN", "timezone": "Asia/Shanghai"}))
        self.assertEqual(region.resolve_region({}, "Europe/Berlin"), "global")
        self.preset.write_text(json.dumps({"region": "zz"}))
        with self.assertRaisesRegex(RuntimeError, "Unsupported region"):
            region.resolve_region({}, "Europe/Berlin")

    def test_the_language_plays_no_part(self):
        for language in ("en", "zh-CN", "zh-TW"):
            with self.subTest(language=language):
                self.assertEqual(region.resolve_region({"language": language}, "Asia/Shanghai"), "cn")
                self.assertEqual(region.resolve_region({"language": language}, "America/New_York"), "global")

    def test_iso_without_profiles_is_global(self):
        with mock.patch.object(region, "REGIONS_DIR", self.root / "missing"):
            self.assertEqual(region.resolve_region({}, "Asia/Shanghai"), "global")

    def test_autoinstall_region_overrides_timezone(self):
        self.assertEqual(region.resolve_region({"region": "cn"}, "UTC"), "cn")
        self.assertEqual(region.resolve_region({"region": "global"}, "Asia/Shanghai"), "global")
        self.assertEqual(region.resolve_region({}, "Asia/Shanghai"), "cn")
        for bad in ("us", "CN", "..", "cn/../cn", True, 1, ["cn"]):
            with self.subTest(region=bad), self.assertRaises(RuntimeError):
                region.resolve_region({"region": bad}, "UTC")

    def from_env(self, config: dict) -> context.InstallContext:
        config_path = self.root / "config.json"
        creds_path = self.root / "creds.json"
        config_path.write_text(json.dumps(config))
        creds_path.write_text(json.dumps({"users": [{"username": "test"}]}))
        with mock.patch.dict(os.environ, {
            "OMARCHY_INSTALL_CONFIG": str(config_path),
            "OMARCHY_INSTALL_CREDS": str(creds_path),
            "OMARCHY_INSTALL_STATE_DIR": str(self.root / "state"),
        }, clear=True), mock.patch.object(context, "_default_kernel", return_value="linux-omarchy"):
            return context.InstallContext.from_env()

    def test_context_resolves_region_before_install(self):
        self.assertEqual(self.from_env({"timezone": "Asia/Shanghai"}).region, "cn")
        self.assertEqual(self.from_env({"timezone": "Europe/Berlin"}).region, "global")
        self.assertEqual(self.from_env({"timezone": "UTC"}).region, "global")
        # A deferred install's timezone is a placeholder, so it takes the
        # media's region unless the autoinstall config names one.
        deferred = {"timezone": "Asia/Shanghai", "omarchy_install": {"defer_provisioning": True}}
        self.assertEqual(self.from_env(deferred).region, "global")
        self.assertEqual(self.from_env({"timezone": "UTC", "omarchy_install": {"region": "cn"}}).region, "cn")
        with self.assertRaises(RuntimeError):
            self.from_env({"omarchy_install": {"region": "zz"}})

    def test_invalid_override_is_refused_before_install_state_is_created(self):
        for invalid in ("zz", "CN", "../cn", True, 1):
            with self.subTest(region=invalid), self.assertRaisesRegex(RuntimeError, "Unsupported region"):
                self.from_env({"timezone": "UTC", "omarchy_install": {"region": invalid}})
            self.assertFalse((self.root / "state").exists())

    def test_marker_is_written_only_for_regional_targets(self):
        target = self.root / "target"
        phases_impl._write_region_marker(types.SimpleNamespace(target=target, region="global", defer_provisioning=False))
        self.assertFalse((target / "etc/omarchy").exists())

        phases_impl._write_region_marker(types.SimpleNamespace(target=target, region="cn", defer_provisioning=False))
        marker = target / "etc/omarchy/region"
        self.assertEqual(marker.read_text(), "cn\n")
        self.assertEqual(marker.stat().st_mode & 0o777, 0o644)
        self.assertFalse((target / "etc/omarchy/form-defaults").exists())

    def test_a_deferred_install_leaves_its_region_for_first_boot(self):
        # First-boot setup (configure_region) settles REGION against the
        # owner's timezone; global media must say so too, or a Shanghai owner
        # would keep the global region.
        for selected, marker in (("global", None), ("cn", "cn\n")):
            with self.subTest(region=selected):
                target = self.root / selected
                phases_impl._write_region_marker(
                    types.SimpleNamespace(target=target, region=selected, defer_provisioning=True, omarchy_install={}))
                defaults = target / "etc/omarchy/form-defaults"
                self.assertEqual(defaults.read_text(), f"REGION={selected}\n")
                self.assertEqual(defaults.stat().st_mode & 0o777, 0o644)
                path = target / "etc/omarchy/region"
                self.assertEqual(path.read_text() if path.exists() else None, marker)
        # A region the config named stands: first boot leaves it alone.
        target = self.root / "named"
        phases_impl._write_region_marker(
            types.SimpleNamespace(target=target, region="global", defer_provisioning=True, omarchy_install={"region": "global"}))
        self.assertFalse((target / "etc/omarchy/form-defaults").exists())

    def test_region_survives_root_image_install_without_changing_package_delta(self):
        cases = (
            ("Asia/Shanghai", None, "cn"),
            ("Asia/Urumqi", None, "cn"),
            ("Europe/Copenhagen", None, "global"),
            ("Asia/Hong_Kong", None, "global"),
            ("Asia/Shanghai", "global", "global"),
            ("UTC", "cn", "cn"),
        )
        for (timezone, override, expected), pre_mounted in product(cases, (False, True)):
            with self.subTest(timezone=timezone, override=override, pre_mounted=pre_mounted), ExitStack() as stack:
                packages_added = []
                installer = mock.MagicMock()
                installer.add_additional_packages.side_effect = packages_added.extend
                config = types.SimpleNamespace(
                    kernels=["linux-omarchy"], locale_config=None, mirror_config=None, disk_config=None,
                    swap=None, auth_config=None, app_config=None, timezone=None,
                    ntp=False, hostname="test", pacman_config="/etc/pacman.conf",
                )
                ctx = self.from_env({"timezone": timezone, "omarchy_install": {"region": override}})
                ctx.target = self.root / "target"
                ctx.state = {"arch_config_handler": types.SimpleNamespace(config=config), "mirror_handler": None}

                # Unpacking the shared root replaces everything on the target.
                # Writing the marker before that would silently lose it.
                def unpack_image(_ctx):
                    if ctx.target.exists():
                        shutil.rmtree(ctx.target)
                    (ctx.target / "etc").mkdir(parents=True)

                stack.enter_context(mock.patch.object(phases_impl, "_install_root_image", side_effect=unpack_image))
                for name in ("_mount_offline_package_cache", "_mask_mkinitcpio_pacman_hooks",
                             "_unmask_mkinitcpio_pacman_hooks", "_configure_limine_boot",
                             "_write_pre_mounted_fstab", "_unmount_offline_package_cache",
                             "_start_target_keyring_init"):
                    stack.enter_context(mock.patch.object(phases_impl, name))
                stack.enter_context(mock.patch.object(phases_impl, "configure_keyboard", return_value=True))
                stack.enter_context(mock.patch.object(phases_impl, "_platform_delta_packages", return_value=[]))
                stack.enter_context(mock.patch.object(phases_impl.arch, "target_missing_packages", return_value=[], create=True))
                for name, value in (("is_pre_mount", pre_mounted), ("is_encrypted", False), ("root_user", None)):
                    stack.enter_context(mock.patch.object(phases_impl.arch, name, return_value=value, create=True))
                for name in ("sanity_check", "perform_filesystem_operations", "install_base_delta", "defer_argon2_keyslot"):
                    stack.enter_context(mock.patch.object(phases_impl.arch, name, create=True))
                opened = stack.enter_context(mock.patch.object(phases_impl.arch, "open_installer", create=True))
                opened.return_value.__enter__.return_value = installer

                phases_impl.arch_install_system(ctx)

                self.assertEqual(packages_added, [])
                marker = ctx.target / "etc/omarchy/region"
                self.assertEqual(marker.read_text() if marker.exists() else None, "cn\n" if expected == "cn" else None)

    def test_finalizer_adds_no_trust_for_any_region(self):
        for selected in ("global", "cn"):
            with self.subTest(region=selected), \
                    mock.patch.object(phases_impl, "_run_target_setup_command") as run, \
                    mock.patch.object(phases_impl, "_mask_mkinitcpio_pacman_hooks"), \
                    mock.patch.object(phases_impl, "_unmask_mkinitcpio_pacman_hooks"):
                ctx = types.SimpleNamespace(region=selected, defer_provisioning=True, target=Path("/unused"))
                phases_impl.run_system_finalizer(ctx)
                commands = [call.args[1] for call in run.call_args_list]
                self.assertEqual(commands[:-1], [])
                self.assertEqual(commands[-1][0], "/usr/bin/omarchy-apply-system")


if __name__ == "__main__":
    unittest.main()
