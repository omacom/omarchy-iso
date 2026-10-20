"""The target's region comes from its timezone, using the runtime's profiles."""

import json
import os
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
from orchestrator import context, phases_impl, region  # noqa: E402


def write_profiles(root: Path) -> Path:
    regions = root / "regions"
    cn = regions / "cn"
    (cn / "pacman").mkdir(parents=True)
    (cn / "timezones").write_text("# China\nAsia/Shanghai\n\n  Asia/Urumqi  \n")
    for channel in ("stable", "rc", "edge"):
        (cn / f"pacman/mirrorlist-{channel}.prepend").write_text(f"Server = https://{channel}.example.invalid/$repo/os/$arch\n")
        (cn / f"pacman/omarchy-{channel}.prepend").write_text(f"Server = https://pkgs.example.invalid/{channel}/$arch\n")
    return regions


class RegionSelectionTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.regions = write_profiles(self.root)
        patcher = mock.patch.object(region, "REGIONS_DIR", self.regions)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_timezone_selects_region(self):
        for timezone, expected in [
            ("Asia/Shanghai", "cn"),
            ("Asia/Urumqi", "cn"),
            # Hong Kong, Macau and Taiwan are never part of any region.
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
                self.assertEqual(region.region_for_timezone(timezone), expected)

    def test_iso_without_profiles_is_global(self):
        self.assertEqual(region.region_for_timezone("Asia/Shanghai", self.root / "missing"), "global")
        self.assertEqual(region.resolve_region({}, "Asia/Shanghai", self.root / "missing"), "global")

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
        }, clear=True), mock.patch.object(context, "_default_kernel", return_value="linux-omarchy"), \
                mock.patch.object(context, "PRESET", self.root / "no-preset.json"):
            return context.InstallContext.from_env()

    def test_context_resolves_region_before_install(self):
        self.assertEqual(self.from_env({"timezone": "Asia/Shanghai"}).region, "cn")
        self.assertEqual(self.from_env({"timezone": "Europe/Berlin"}).region, "global")
        # Deferred installs carry UTC until first boot, so they are global
        # unless the autoinstall config names a region.
        self.assertEqual(self.from_env({"timezone": "UTC"}).region, "global")
        self.assertEqual(self.from_env({"timezone": "UTC", "omarchy_install": {"region": "cn"}}).region, "cn")
        with self.assertRaises(RuntimeError):
            self.from_env({"omarchy_install": {"region": "zz"}})

    def test_marker_is_written_only_for_regional_targets(self):
        target = self.root / "target"
        phases_impl._write_region_marker(types.SimpleNamespace(target=target, region="global"))
        self.assertFalse((target / "etc/omarchy/region").exists())

        phases_impl._write_region_marker(types.SimpleNamespace(target=target, region="cn"))
        marker = target / "etc/omarchy/region"
        self.assertEqual(marker.read_text(), "cn\n")
        self.assertEqual(marker.stat().st_mode & 0o777, 0o644)

    def test_region_adds_no_packages_and_marks_only_regional_targets(self):
        for selected in ("global", "cn"):
            with self.subTest(region=selected), ExitStack() as stack:
                events = []
                installer = mock.MagicMock()
                installer.add_additional_packages.side_effect = lambda packages: events.append(packages)
                config = types.SimpleNamespace(
                    kernels=["linux-omarchy"], locale_config=None, mirror_config=None,
                    swap=None, auth_config=None, app_config=None, timezone=None,
                    ntp=False, hostname="test", pacman_config="/etc/pacman.conf",
                )
                ctx = types.SimpleNamespace(
                    state={"arch_config_handler": types.SimpleNamespace(config=config), "mirror_handler": None},
                    target=self.root / "target", tailscale_authkey_path=None, omarchy_install={},
                    region=selected,
                )
                for name in ("_mount_offline_package_cache", "_mask_mkinitcpio_pacman_hooks",
                             "_unmask_mkinitcpio_pacman_hooks", "_configure_limine_boot",
                             "_write_pre_mounted_fstab", "_install_early_packages"):
                    stack.enter_context(mock.patch.object(phases_impl, name))
                stack.enter_context(mock.patch.object(
                    phases_impl, "_unmount_offline_package_cache", side_effect=lambda _: events.append("unmount")))
                stack.enter_context(mock.patch.object(phases_impl, "configure_keyboard", return_value=True))
                stack.enter_context(mock.patch.object(phases_impl, "_runtime_package_list", return_value=["omarchy"]))
                for name, value in (("is_pre_mount", True), ("root_user", None)):
                    stack.enter_context(mock.patch.object(phases_impl.arch, name, return_value=value, create=True))
                stack.enter_context(mock.patch.object(phases_impl.arch, "sanity_check", create=True))
                opened = stack.enter_context(mock.patch.object(phases_impl.arch, "open_installer", create=True))
                opened.return_value.__enter__.return_value = installer

                phases_impl.arch_install_system(ctx)

                self.assertEqual(events, [["linux-omarchy-headers"], ["omarchy"], "unmount"])
                self.assertEqual((ctx.target / "etc/omarchy/region").exists(), selected != "global")

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


class PresetTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.regions = write_profiles(self.root)

    def test_never_regional_even_if_a_profile_lists_it(self):
        (self.regions / "cn/timezones").write_text("Asia/Shanghai\nAsia/Hong_Kong\nAsia/Taipei\nAsia/Macau\n")
        for timezone in sorted(region.NEVER_REGIONAL):
            with self.subTest(timezone=timezone):
                self.assertEqual(region.region_for_timezone(timezone, self.regions), "global")
                self.assertEqual(region.region_for_install(timezone, "cn", self.regions), "global")

    def test_preset_region_fills_in_where_the_timezone_names_none(self):
        for timezone, preset, expected in [
            ("Asia/Shanghai", None, "cn"),
            ("UTC", None, "global"),
            ("UTC", "cn", "cn"),
            ("Europe/Copenhagen", "cn", "cn"),
            ("UTC", "zz", "global"),
            ("UTC", "../cn", "global"),
            ("UTC", "global", "global"),
        ]:
            with self.subTest(timezone=timezone, preset=preset):
                self.assertEqual(region.region_for_install(timezone, preset, self.regions), expected)

    def test_language_is_validated_against_the_registry(self):
        registry = self.root / "locales.json"
        registry.write_text(json.dumps({"en": {}, "zh-CN": {}}))
        for language in (None, "", "en", "zh-CN"):
            context.validate_language(language, registry)
        for language in ("zh_CN", "xx", "../zh-CN", "zh-CN; reboot", "zh-CN\n", 7, ["zh-CN"]):
            with self.subTest(language=language), self.assertRaises(RuntimeError):
                context.validate_language(language, registry)

    def test_without_a_registry_only_english_is_accepted(self):
        missing = self.root / "missing.json"
        context.validate_language("en", missing)
        with self.assertRaises(RuntimeError):
            context.validate_language("zh-CN", missing)

    def from_env(self, config: dict, preset: dict | None) -> context.InstallContext:
        preset_path = self.root / "preset.json"
        if preset is None:
            preset_path.unlink(missing_ok=True)
        else:
            preset_path.write_text(json.dumps(preset))
        registry = self.root / "locales.json"
        registry.write_text(json.dumps({"en": {}, "zh-CN": {}, "da": {}}))
        config_path, creds_path = self.root / "config.json", self.root / "creds.json"
        config_path.write_text(json.dumps(config))
        creds_path.write_text(json.dumps({"users": [{"username": "test"}]}))
        with mock.patch.dict(os.environ, {
            "OMARCHY_INSTALL_CONFIG": str(config_path),
            "OMARCHY_INSTALL_CREDS": str(creds_path),
            "OMARCHY_INSTALL_STATE_DIR": str(self.root / "state"),
        }, clear=True), mock.patch.object(context, "_default_kernel", return_value="linux-omarchy"), \
                mock.patch.object(context, "PRESET", preset_path), mock.patch.object(context, "LANGUAGES", registry), \
                mock.patch.object(region, "REGIONS_DIR", self.regions):
            return context.InstallContext.from_env()

    def test_preset_fills_in_only_what_the_config_leaves_unset(self):
        china = {"keyboard": "Chinese (Simplified, Pinyin)", "timezone": "Asia/Shanghai", "language": "zh-CN", "region": "cn"}
        ctx = self.from_env({"timezone": "UTC"}, china)  # an autoinstall drive, or a deferred install, with neither field
        self.assertEqual((ctx.region, ctx.omarchy_install["language"]), ("cn", "zh-CN"))
        # The fallback region is left for first-boot owner setup to settle.
        self.assertEqual(ctx.omarchy_install["form_defaults"], {"keyboard": "Chinese (Simplified, Pinyin)", "timezone": "Asia/Shanghai", "region": "cn"})
        self.assertNotIn("region", self.from_env({"timezone": "Asia/Shanghai"}, china).omarchy_install["form_defaults"])
        self.assertNotIn("region", self.from_env({"timezone": "UTC", "omarchy_install": {"region": "cn"}}, china).omarchy_install["form_defaults"])
        ctx = self.from_env({"timezone": "UTC", "omarchy_install": {"language": "da", "region": "global"}}, china)
        self.assertEqual((ctx.region, ctx.omarchy_install["language"]), ("global", "da"))
        # English picked in the installer's language picker overrides the preset's language.
        self.assertEqual(self.from_env({"timezone": "Asia/Shanghai", "omarchy_install": {"language": "en"}}, china).omarchy_install["language"], "en")
        self.assertEqual(self.from_env({"timezone": "Asia/Taipei"}, china).region, "global")
        ctx = self.from_env({"timezone": "UTC"}, None)
        self.assertEqual((ctx.region, ctx.omarchy_install.get("language"), ctx.omarchy_install["form_defaults"]), ("global", None, {}))

    def test_form_defaults_are_written_as_data_only_for_a_preset(self):
        target = self.root / "target"
        phases_impl._write_form_defaults(types.SimpleNamespace(target=target, omarchy_install={"form_defaults": {}}))
        self.assertFalse((target / "etc/omarchy/form-defaults").exists())
        phases_impl._write_form_defaults(types.SimpleNamespace(target=target, omarchy_install={"form_defaults": {
            "keyboard": "Chinese (Simplified, Pinyin)", "timezone": "Asia/Shanghai\nKEYBOARD=evil", "region": "cn"}}))
        self.assertEqual((target / "etc/omarchy/form-defaults").read_text(), "KEYBOARD=Chinese (Simplified, Pinyin)\nREGION=cn\n")

    def test_preset_takes_the_language_pickers_keys(self):
        # The installer's language picker reads the same file, and its own key is not the orchestrator's to read.
        preset_path = self.root / "preset.json"
        preset_path.write_text(json.dumps({"language": "zh-CN", "language_prompt": False, "keyboard": "Chinese (Simplified, Pinyin)", "timezone": "Asia/Shanghai", "region": "cn"}))
        self.assertEqual(context.load_preset(preset_path), {"language": "zh-CN", "keyboard": "Chinese (Simplified, Pinyin)", "timezone": "Asia/Shanghai", "region": "cn"})

    def test_language_marker_is_written_only_for_a_language_other_than_english(self):
        target = self.root / "target"
        for omarchy_install in ({}, {"language": ""}, {"language": "en"}):
            phases_impl._write_language_marker(types.SimpleNamespace(target=target, omarchy_install=omarchy_install))
            self.assertFalse((target / "etc/omarchy/language").exists())
        phases_impl._write_language_marker(types.SimpleNamespace(target=target, omarchy_install={"language": "zh-CN"}))
        marker = target / "etc/omarchy/language"
        self.assertEqual(marker.read_text(), "zh-CN\n")
        self.assertEqual(marker.stat().st_mode & 0o777, 0o644)


class RegionPackagesTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.regions = write_profiles(self.root)
        (self.regions / "cn/packages-skip").write_text("# blocked\nchromium\n")
        (self.regions / "cn/packages-add").write_text("wechat-bin\nwps-office-cn\n\nfeishu-bin\n")
        self.base = self.root / "omarchy-base.packages"
        self.base.write_text("chromium\nmpv\n")

    def package_list(self, region_name: str, carried: set[str]) -> list[str]:
        with mock.patch.object(region, "REGIONS_DIR", self.regions), \
                mock.patch.object(phases_impl, "_early_packages", return_value=[]), \
                mock.patch.object(phases_impl, "_package_targets", return_value={"runtime": "omarchy", "settings": "omarchy-settings", "nvim": "omarchy-nvim"}), \
                mock.patch.object(phases_impl, "_offline_package_names", return_value=carried), \
                mock.patch.object(phases_impl.platform, "machine", return_value="x86_64"), \
                mock.patch.object(phases_impl, "info"):
            return phases_impl._runtime_package_list(types.SimpleNamespace(region=region_name), self.base)

    def test_profiles_name_packages_to_skip_and_add(self):
        self.assertEqual(region.region_packages("cn", self.regions), (["chromium"], ["wechat-bin", "wps-office-cn", "feishu-bin"]))
        for name in ("global", "us", "../cn", "CN"):
            with self.subTest(region=name):
                self.assertEqual(region.region_packages(name, self.regions), ([], []))

    def test_a_region_skips_defaults_and_adds_only_what_the_iso_carries(self):
        world = self.package_list("global", {"wechat-bin"})
        china = self.package_list("cn", {"wechat-bin", "wps-office-cn"})  # an aarch64 ISO would lack wps-office-cn
        self.assertEqual(world[1:], ["chromium", "mpv"])
        self.assertEqual(china[1:], ["mpv", "wechat-bin", "wps-office-cn"])
        self.assertEqual(self.package_list("cn", set())[1:], ["mpv"])

    def test_offline_names_come_from_the_repository_index(self):
        import io
        import tarfile
        mirror = self.root / "mirror"
        mirror.mkdir()
        with tarfile.open(mirror / "offline.db.tar.gz", "w:gz") as archive:
            for entry in ("wechat-bin-4.1.13.26-1", "lib32-foo-bar-1:2.0-3", "mpv-1:0.40-1"):
                folder = tarfile.TarInfo(entry)
                folder.type = tarfile.DIRTYPE
                archive.addfile(folder)
                desc = tarfile.TarInfo(entry + "/desc")
                desc.size = 0
                archive.addfile(desc, io.BytesIO(b""))
        self.assertEqual(phases_impl._offline_package_names(mirror), {"wechat-bin", "lib32-foo-bar", "mpv"})
        self.assertEqual(phases_impl._offline_package_names(self.root / "none"), set())


class PrepareRegionsTest(unittest.TestCase):
    def run_prepare(self, regions: Path, root: Path) -> tuple[Path, str]:
        payload = root / "payload"
        payload.mkdir()
        stubs = root / "bin"
        stubs.mkdir()
        log = root / "calls.log"
        for name in ("pacman", "pacman-key"):
            stub = stubs / name
            stub.write_text(f'#!/bin/bash\necho "{name} $*" >> "{log}"\n')
            stub.chmod(0o755)
        subprocess.run(
            ["bash", str(ROOT / "builder/prepare-regions.sh"), str(regions), str(payload)],
            env={**os.environ, "PATH": f"{stubs}:{os.environ['PATH']}"},
            check=True, capture_output=True, text=True,
        )
        return payload, log.read_text() if log.exists() else ""

    def test_ships_every_profile_and_trusts_nothing_new(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            regions = write_profiles(root)
            payload, calls = self.run_prepare(regions, root)
            self.assertEqual((payload / "regions/cn/timezones").read_text(), (regions / "cn/timezones").read_text())
            self.assertEqual((payload / "regions/cn/pacman/omarchy-rc.prepend").read_text(),
                             (regions / "cn/pacman/omarchy-rc.prepend").read_text())
            # Staging a profile downloads nothing and imports no key.
            self.assertEqual(calls, "")

    def settings_package(self, root: Path, with_regions: bool) -> Path:
        tree = root / "pkgroot"
        (tree / "usr/share/omarchy/default/pacman").mkdir(parents=True)
        if with_regions:
            write_profiles(root / "src")
            (root / "src/regions").rename(tree / "usr/share/omarchy/default/regions")
        package = root / "omarchy-settings-1-1-any.pkg.tar.zst"
        subprocess.run(["bsdtar", "--zstd", "-cf", str(package), "-C", str(tree), "usr"], check=True)
        return package

    def test_published_build_reads_profiles_from_the_settings_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload, calls = self.run_prepare(self.settings_package(root, with_regions=True), root)
            self.assertTrue((payload / "regions/cn/pacman/omarchy-stable.prepend").is_file())
            self.assertEqual(calls, "")

    def test_settings_package_without_profiles_builds_a_global_iso(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload, calls = self.run_prepare(self.settings_package(root, with_regions=False), root)
            self.assertFalse((payload / "regions").exists())
            self.assertEqual(calls, "")

    def test_unreadable_settings_package_fails_the_build(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            package = root / "omarchy-settings-1-1-any.pkg.tar.zst"
            package.write_text("not an archive")
            with self.assertRaises(subprocess.CalledProcessError):
                self.run_prepare(package, root)

    def test_runtime_without_profiles_builds_a_global_iso(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload, calls = self.run_prepare(root / "missing", root)
            self.assertFalse((payload / "regions").exists())
            self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
