import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "builder/build-iso.sh"
TARGET_CONF = ROOT / "configs/aarch64/pacman-target.conf"
TARGET_MIRRORLIST = ROOT / "configs/aarch64/mirrorlist-target"
ONLINE_CONFIGS = [
    ROOT / f"configs/aarch64/pacman-online-{channel}.conf"
    for channel in ("stable", "rc", "edge")
]

sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)

from orchestrator import phases_impl  # noqa: E402


class Aarch64PacmanTests(unittest.TestCase):
    def test_target_uses_alarm_without_multilib(self):
        config = TARGET_CONF.read_text()
        self.assertIn("[core]", config)
        self.assertIn("[extra]", config)
        self.assertIn("[alarm]", config)
        self.assertNotIn("[multilib]", config)
        self.assertIn("Server = @@OMARCHY_PKGS_MIRROR@@", config)

    def test_omarchy_overlay_precedes_alarm_repositories(self):
        for path in [TARGET_CONF, *ONLINE_CONFIGS]:
            with self.subTest(path=path.name):
                sections = [
                    line
                    for line in path.read_text().splitlines()
                    if line.startswith("[") and line.endswith("]")
                ]
                self.assertLess(sections.index("[omarchy]"), sections.index("[core]"))
                self.assertLess(sections.index("[omarchy]"), sections.index("[extra]"))
                self.assertLess(sections.index("[omarchy]"), sections.index("[alarm]"))

    def test_builder_prepends_overlay_for_makepkg_dependency_resolution(self):
        builder = BUILDER.read_text()
        self.assertIn("cat /etc/pacman.conf", builder)
        self.assertIn(">/tmp/pacman.conf.with-omarchy", builder)
        self.assertNotIn(">> /etc/pacman.conf", builder)

    def test_builder_reads_architecture_specific_configs_from_aarch64_directory(self):
        builder = BUILDER.read_text()
        self.assertIn(
            'pacman_online_conf="/configs/aarch64/pacman-online-${OMARCHY_MIRROR}.conf"',
            builder,
        )
        self.assertIn("/configs/aarch64/pacman-target.conf", builder)
        self.assertIn("/configs/aarch64/mirrorlist-target", builder)

    def test_target_uses_global_https_mirror_set(self):
        servers = [
            line
            for line in TARGET_MIRRORLIST.read_text().splitlines()
            if line.startswith("Server = ")
        ]
        self.assertEqual(
            servers,
            [
                "Server = https://cdnmirror.com/archlinuxarm/$arch/$repo",
                "Server = https://mirrors.dotsrc.org/archlinuxarm/$arch/$repo",
                "Server = https://de3.mirror.archlinuxarm.org/$arch/$repo",
                "Server = https://ca.us.mirror.archlinuxarm.org/$arch/$repo",
                "Server = https://fl.us.mirror.archlinuxarm.org/$arch/$repo",
            ],
        )
        self.assertTrue(all(server.startswith("Server = https://") for server in servers))
        self.assertFalse(any("//mirror.archlinuxarm.org/" in server for server in servers))

    def test_build_configs_use_global_https_set_for_every_alarm_repo(self):
        expected = [
            "https://cdnmirror.com/archlinuxarm/$arch/$repo",
            "https://mirrors.dotsrc.org/archlinuxarm/$arch/$repo",
            "https://de3.mirror.archlinuxarm.org/$arch/$repo",
            "https://ca.us.mirror.archlinuxarm.org/$arch/$repo",
            "https://fl.us.mirror.archlinuxarm.org/$arch/$repo",
        ]
        for path in ONLINE_CONFIGS:
            with self.subTest(path=path.name):
                sections = {}
                section = None
                for line in path.read_text().splitlines():
                    if line.startswith("["):
                        section = line.strip("[]")
                    elif line.startswith("Server = "):
                        sections.setdefault(section, []).append(line.removeprefix("Server = "))
                for repository in ("core", "extra", "alarm"):
                    self.assertEqual(sections[repository], expected)

    def test_offline_config_is_reasserted_between_finalizers(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "target"
            (target / "etc").mkdir(parents=True)
            live_conf = root / "pacman-offline.conf"
            target_marker = root / "pacman-target.conf"
            live_conf.write_text("[offline]\n")
            target_marker.touch()
            (target / "etc/pacman.conf").write_text("[multilib]\n")
            ctx = types.SimpleNamespace(target=target)

            with (
                mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"),
                mock.patch.object(phases_impl, "LIVE_PACMAN_CONF", live_conf),
                mock.patch.object(
                    phases_impl, "AARCH64_TARGET_PACMAN_CONF", target_marker
                ),
            ):
                phases_impl._restore_aarch64_offline_pacman(ctx)

            self.assertEqual((target / "etc/pacman.conf").read_text(), "[offline]\n")

    def test_final_target_receives_network_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "target"
            target_conf = root / "pacman-target.conf"
            target_mirrorlist = root / "mirrorlist-target"
            target_conf.write_text("[alarm]\nServer = snapdragon\n")
            target_mirrorlist.write_text("Server = geoip\nServer = florida\n")
            ctx = types.SimpleNamespace(target=target)

            with (
                mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"),
                mock.patch.object(
                    phases_impl, "AARCH64_TARGET_PACMAN_CONF", target_conf
                ),
                mock.patch.object(
                    phases_impl, "AARCH64_TARGET_MIRRORLIST", target_mirrorlist
                ),
            ):
                phases_impl.configure_package_repositories(ctx)

            self.assertEqual(
                (target / "etc/pacman.conf").read_text(), target_conf.read_text()
            )
            self.assertEqual(
                (target / "etc/pacman.d/mirrorlist").read_text(),
                target_mirrorlist.read_text(),
            )

    def test_non_aarch64_target_is_unchanged(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "target"
            ctx = types.SimpleNamespace(target=target)
            with mock.patch.object(
                phases_impl.platform, "machine", return_value="x86_64"
            ):
                phases_impl.configure_package_repositories(ctx)
            self.assertFalse(target.exists())

    def test_aarch64_bootstrap_installs_and_populates_alarm_keyring(self):
        target = Path("/mnt")
        installer = mock.Mock(target=target)

        with (
            mock.patch.object(phases_impl.platform, "machine", return_value="aarch64"),
            mock.patch.object(phases_impl.subprocess, "run") as run,
        ):
            packages = phases_impl._early_bootstrap_packages()
            phases_impl._install_early_packages(installer)

        self.assertIn("archlinuxarm-keyring", packages)
        self.assertIn(
            "archlinuxarm-keyring", installer.add_additional_packages.call_args_list[0].args[0]
        )
        run.assert_any_call(
            ["arch-chroot", "/mnt", "pacman-key", "--init"], check=True
        )
        run.assert_any_call(
            [
                "arch-chroot",
                "/mnt",
                "pacman-key",
                "--populate",
                "archlinux",
                "archlinuxarm",
                "omarchy",
            ],
            check=True,
        )

    def test_x86_bootstrap_does_not_install_alarm_keyring(self):
        with mock.patch.object(phases_impl.platform, "machine", return_value="x86_64"):
            self.assertNotIn(
                "archlinuxarm-keyring", phases_impl._early_bootstrap_packages()
            )


if __name__ == "__main__":
    unittest.main()
