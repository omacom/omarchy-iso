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
    (cn / "packages").write_text("# keyring first\narchlinuxcn-keyring\nextra-tool\n")
    (cn / "pacman/pacman.conf.append").write_text("[archlinuxcn]\nServer = https://example.invalid/$arch\n")
    for channel in ("stable", "rc", "edge"):
        (cn / f"pacman/mirrorlist-{channel}.prepend").write_text(f"Server = https://{channel}.example.invalid/$repo/os/$arch\n")
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
            ("Asia/Hong_Kong", "global"),
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

    def test_profile_packages_and_keyrings(self):
        self.assertEqual(region.region_packages("cn"), ["archlinuxcn-keyring", "extra-tool"])
        self.assertEqual(region.region_keyrings("cn"), ["archlinuxcn"])
        self.assertEqual(region.region_packages("global"), [])
        self.assertEqual(region.region_keyrings("global"), [])

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

    def test_region_packages_install_while_the_offline_mirror_is_mounted(self):
        for selected, expected_packages in [("global", []), ("cn", [["archlinuxcn-keyring", "extra-tool"]])]:
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

                self.assertEqual(events, [["linux-omarchy-headers"], ["omarchy"], *expected_packages, "unmount"])
                self.assertEqual((ctx.target / "etc/omarchy/region").exists(), selected != "global")

    def test_finalizer_trusts_only_the_selected_region(self):
        for selected, expected in [
            ("global", []),
            ("cn", [["pacman-key", "--init"], ["pacman-key", "--populate", "archlinux", "archlinuxcn"]]),
        ]:
            with self.subTest(region=selected), \
                    mock.patch.object(phases_impl, "_run_target_setup_command") as run, \
                    mock.patch.object(phases_impl, "_mask_mkinitcpio_pacman_hooks"), \
                    mock.patch.object(phases_impl, "_unmask_mkinitcpio_pacman_hooks"):
                ctx = types.SimpleNamespace(region=selected, defer_provisioning=True, target=Path("/unused"))
                phases_impl.run_system_finalizer(ctx)
                commands = [call.args[1] for call in run.call_args_list]
                self.assertEqual(commands[:-1], expected)
                self.assertEqual(commands[-1][0], "/usr/bin/omarchy-apply-system")


class PrepareRegionsTest(unittest.TestCase):
    def run_prepare(self, regions: Path, root: Path) -> tuple[Path, Path, str]:
        payload = root / "payload"
        payload.mkdir()
        online = root / "online.conf"
        online.write_text("[core]\nInclude = /etc/pacman.d/mirrorlist\n")
        stubs = root / "bin"
        stubs.mkdir()
        log = root / "calls.log"
        for name in ("pacman", "pacman-key"):
            stub = stubs / name
            stub.write_text(f'#!/bin/bash\necho "{name} $*" >> "{log}"\n')
            stub.chmod(0o755)
        subprocess.run(
            ["bash", str(ROOT / "builder/prepare-regions.sh"), str(regions), str(payload), str(online)],
            env={**os.environ, "PATH": f"{stubs}:{os.environ['PATH']}"},
            check=True, capture_output=True, text=True,
        )
        return payload, online, log.read_text() if log.exists() else ""

    def test_ships_every_profile_and_bootstraps_its_keyring(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            regions = write_profiles(root)
            payload, online, calls = self.run_prepare(regions, root)
            self.assertEqual((payload / "regions/cn/timezones").read_text(), (regions / "cn/timezones").read_text())
            self.assertIn("[archlinuxcn]", online.read_text())
            self.assertTrue(online.read_text().startswith("[core]\n"))
            self.assertEqual(calls.splitlines(), [
                f"pacman --config {online} --noconfirm -Sy --needed archlinuxcn-keyring",
                "pacman-key --populate archlinuxcn",
            ])

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
            payload, online, calls = self.run_prepare(self.settings_package(root, with_regions=True), root)
            self.assertEqual((payload / "regions/cn/packages").read_text(), "# keyring first\narchlinuxcn-keyring\nextra-tool\n")
            self.assertIn("[archlinuxcn]", online.read_text())
            self.assertIn("pacman-key --populate archlinuxcn", calls)

    def test_settings_package_without_profiles_builds_a_global_iso(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            payload, online, calls = self.run_prepare(self.settings_package(root, with_regions=False), root)
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
            payload, online, calls = self.run_prepare(root / "missing", root)
            self.assertFalse((payload / "regions").exists())
            self.assertNotIn("archlinuxcn", online.read_text())
            self.assertEqual(calls, "")


if __name__ == "__main__":
    unittest.main()
