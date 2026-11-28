"""The install must not wait on a network it may not have.

mise reshim resolves the version list of every tool declared in
/etc/mise/conf.d/omarchy-tools.toml, all of them version = "latest". Offline,
each lookup waits out mise's HTTP timeout first: 40.10 s of a 65 s install.
MISE_OFFLINE=1 blocks every HTTP request, and the tools are lazy, so reshim
still only needs the declarations.
"""

import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import phases_impl  # noqa: E402


class MiseOfflineTest(unittest.TestCase):
    def test_user_finalizer_runs_mise_offline(self):
        ctx = mock.Mock(username="user", full_name="User", email="user@example.com",
                        defer_provisioning=False, state={})
        ctx.target = Path(tempfile.mkdtemp())
        ctx.log_path = ctx.target / "install.log"

        with mock.patch.object(phases_impl, "_prepare_target_setup"), \
                mock.patch.object(phases_impl, "_ensure_finalizer_log_started",
                                  return_value=("0", "0")), \
                mock.patch.object(phases_impl.subprocess, "run"), \
                mock.patch.object(phases_impl, "_run_timing_scripts") as timing:
            phases_impl.run_chroot_finalizer(ctx)

        # The finalizer's arch-chroot goes through the step-timing runner.
        command = timing.call_args.args[0]
        self.assertIn("arch-chroot", command)
        self.assertIn("MISE_OFFLINE=1", command)
        self.assertIn("MISE_LOG_LEVEL=error", command)

    def test_offline_target_pacman_conf_sets_cachedir_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp) / "live-pacman.conf"
            dst = Path(tmp) / "target" / "etc" / "pacman.conf"
            src.write_text(
                "[options]\nArchitecture = auto\n\n[offline]\nSigLevel = Never\n"
                "Server = file:///var/cache/omarchy/mirror/offline/\n"
            )
            phases_impl._write_offline_target_pacman_conf(src, dst)
            rendered = dst.read_text()
            self.assertIn(
                "[options]\nCacheDir = /var/cache/omarchy/mirror/offline/\nArchitecture = auto\n",
                rendered,
            )
            # Re-running against a config that already has CacheDir does not duplicate it.
            phases_impl._write_offline_target_pacman_conf(dst, dst)
            self.assertEqual(
                dst.read_text().count("CacheDir = /var/cache/omarchy/mirror/offline/"),
                1,
            )

    def test_configure_login_skips_chroots_when_sddm_enabled_and_uid_known(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            (target / "etc").mkdir(parents=True)
            (target / "etc" / "passwd").write_text("sddm:x:970:970:SDDM:/var/lib/sddm:/sbin/nologin\n")
            (target / "etc" / "group").write_text("sddm:x:970:\n")
            unit = target / "usr" / "lib" / "systemd" / "system" / "sddm.service"
            unit.parent.mkdir(parents=True)
            unit.write_text("[Unit]\nDescription=SDDM\n")
            dm = target / "etc" / "systemd" / "system" / "display-manager.service"
            dm.parent.mkdir(parents=True)
            dm.symlink_to("/usr/lib/systemd/system/sddm.service")

            ctx = mock.Mock(target=target, username="dhh", encrypt=True, defer_provisioning=False)
            with mock.patch.object(phases_impl.os, "chown") as chown_mock, \
                    mock.patch.object(phases_impl.subprocess, "run") as run_mock:
                phases_impl.configure_login(ctx)

            self.assertEqual(chown_mock.call_count, 2)
            for call in chown_mock.call_args_list:
                self.assertEqual(call.args[1:], (970, 970))
                self.assertEqual(call.kwargs, {"follow_symlinks": False})
            run_mock.assert_not_called()
            self.assertIn("User=dhh", (target / "etc/sddm.conf.d/autologin.conf").read_text())
            self.assertIn("User=dhh", (target / "var/lib/sddm/state.conf").read_text())

    def test_configure_login_uses_offline_systemctl_when_sddm_not_enabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            ctx = mock.Mock(target=target, username="dhh", encrypt=False, defer_provisioning=True)
            with mock.patch.object(phases_impl.subprocess, "run") as run_mock:
                phases_impl.configure_login(ctx)

            self.assertFalse((target / "var/lib/sddm/state.conf").exists())
            self.assertFalse((target / "etc/sddm.conf.d/autologin.conf").exists())
            run_mock.assert_called_once_with(
                ["systemctl", f"--root={target}", "enable", "sddm.service"],
                check=False,
                capture_output=True,
            )


    def test_sync_offline_target_db_replaces_stale_image_db(self):
        with tempfile.TemporaryDirectory() as tmp:
            mirror = Path(tmp) / "mirror"
            target = Path(tmp) / "target"
            mirror.mkdir()
            sync_dir = target / "var" / "lib" / "pacman" / "sync"
            sync_dir.mkdir(parents=True)

            (mirror / "offline.db.tar.gz").write_bytes(b"recompressed-db-bytes")
            (mirror / "offline.db").symlink_to("offline.db.tar.gz")
            (sync_dir / "offline.db").write_bytes(b"stale-pre-recompress-db")

            phases_impl._sync_offline_target_db(mirror, target)
            dst = sync_dir / "offline.db"
            self.assertFalse(dst.is_symlink())
            self.assertEqual(dst.read_bytes(), b"recompressed-db-bytes")

    def test_prepare_target_setup_syncs_db_and_bind_mounts_mirror_readonly(self):
        with tempfile.TemporaryDirectory() as tmp:
            mirror = Path(tmp) / "mirror"
            mirror.mkdir()
            (mirror / "offline.db.tar.gz").write_bytes(b"fresh-db")
            (mirror / "offline.db").symlink_to("offline.db.tar.gz")
            live_conf = Path(tmp) / "pacman.conf"
            live_conf.write_text("[options]\n[offline]\nServer = file:///var/cache/omarchy/mirror/offline/\n")
            target = Path(tmp) / "target"
            ctx = mock.Mock(target=target, state={})

            with mock.patch.object(phases_impl, "OFFLINE_MIRROR_DIR", str(mirror)),                     mock.patch.object(phases_impl, "NODE_PACKAGES_DIR", Path(tmp) / "no-node"),                     mock.patch.object(phases_impl, "_write_offline_target_pacman_conf"),                     mock.patch.object(phases_impl, "_copy_firmware_stage_into_target"),                     mock.patch.object(phases_impl.subprocess, "run") as run_mock:
                phases_impl._prepare_target_setup(ctx)

            self.assertEqual((target / "var/lib/pacman/sync/offline.db").read_bytes(), b"fresh-db")
            cmds = [call.args[0] for call in run_mock.call_args_list]
            target_mirror = str(target / str(mirror).lstrip("/"))
            self.assertIn(["mount", "--bind", str(mirror), target_mirror], cmds)
            self.assertIn(["mount", "-o", "remount,ro,bind", target_mirror], cmds)


if __name__ == "__main__":
    unittest.main()
