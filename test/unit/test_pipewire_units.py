"""The per-user PipeWire units are wired without a chroot, leaving what
archinstall's own three arch-chroot commands leave, and those commands still
run for a target this does not reproduce exactly."""

import os
import stat
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
ORCHESTRATOR = ROOT / "configs/airootfs/usr/share/omarchy-iso/orchestrator"
sys.path.insert(0, str(ORCHESTRATOR.parent))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import phases_impl  # noqa: E402

SERVICE = "pipewire-pulse.service"
SOCKET = "pipewire-pulse.socket"


class PipewireUnitsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name) / "mnt"
        (self.target / "etc").mkdir(parents=True)
        (self.target / "etc" / "passwd").write_text(
            "root:x:0:0::/root:/usr/bin/bash\nada:x:1003:1007::/home/ada:/usr/bin/bash\n")
        (self.target / "etc" / "group").write_text("root:x:0:\nusers:x:1007:\nada:x:1004:\n")
        self.home = self.target / "home" / "ada"
        self.home.mkdir(parents=True)
        self.session = types.SimpleNamespace(target=self.target)
        self.wants = self.home / ".config/systemd/user/default.target.wants"
        self.ada = [types.SimpleNamespace(username="ada")]

    def enable(self, users=None):
        with mock.patch.object(phases_impl.subprocess, "run") as run, \
                mock.patch.object(phases_impl.os, "lchown") as lchown:
            done = phases_impl._enable_pipewire_without_chroot(self.session, self.ada if users is None else users)
        return done, run, lchown

    def test_the_units_are_linked_for_the_user(self):
        done, _run, lchown = self.enable()
        self.assertTrue(done)
        for unit in (SERVICE, SOCKET):
            self.assertEqual(os.readlink(self.wants / unit), f"/usr/lib/systemd/user/{unit}")
        # The user and the user's own group, as a link the user makes has.
        self.assertEqual([call.args[1:] for call in lchown.call_args_list], [(1003, 1007), (1003, 1007)])
        self.assertEqual(sorted(p.name for p in self.wants.iterdir()), [SERVICE, SOCKET])

    def test_the_home_goes_to_the_user_and_the_group_of_the_same_name_without_following_links(self):
        _done, run, _ = self.enable()
        run.assert_called_once_with(["chown", "-hR", "1003:1004", str(self.home)], check=True)

    def test_a_link_already_there_is_replaced_in_one_step(self):
        self.wants.mkdir(parents=True)
        (self.wants / SERVICE).symlink_to(f"/usr/lib/systemd/user/{SERVICE}")
        (self.wants / SOCKET).write_text("a file ln -sf would replace")
        with mock.patch.object(phases_impl.os, "replace", wraps=os.replace) as replace:
            done, _, _ = self.enable()
        self.assertTrue(done)
        self.assertEqual(replace.call_count, 2)
        self.assertTrue((self.wants / SOCKET).is_symlink())

    def test_a_setgid_directory_keeps_its_group_on_the_links(self):
        self.wants.mkdir(parents=True)
        os.chmod(self.wants, stat.S_IMODE(self.wants.stat().st_mode) | stat.S_ISGID)
        _done, _run, lchown = self.enable()
        self.assertEqual([call.args[1:] for call in lchown.call_args_list], [(1003, -1), (1003, -1)])

    def assert_left_to_archinstall(self):
        done, run, lchown = self.enable()
        self.assertFalse(done)
        run.assert_not_called()
        lchown.assert_not_called()

    def test_a_symbolic_link_on_the_way_is_left_to_archinstall(self):
        elsewhere = Path(self.tmp.name) / "elsewhere"
        elsewhere.mkdir()
        (self.home / ".config").symlink_to(elsewhere)
        self.assert_left_to_archinstall()
        self.assertEqual(list(elsewhere.iterdir()), [])

    def test_a_home_that_is_a_link_is_left_to_archinstall(self):
        self.home.rmdir()
        self.home.symlink_to(Path(self.tmp.name))
        self.assert_left_to_archinstall()

    def test_a_slash_home_that_is_a_link_is_left_to_archinstall(self):
        homes = Path(self.tmp.name) / "homes"
        (self.target / "home").rename(homes)
        (self.target / "home").symlink_to(homes)
        self.assert_left_to_archinstall()
        self.assertFalse((homes / "ada" / ".config").exists())

    def test_a_directory_the_user_could_not_write_to_is_left_to_archinstall(self):
        self.wants.mkdir(parents=True)
        os.chmod(self.wants, 0o555)
        self.addCleanup(os.chmod, self.wants, 0o755)
        self.assert_left_to_archinstall()

    def test_a_directory_the_user_could_not_enter_is_left_to_archinstall(self):
        self.wants.mkdir(parents=True)
        systemd = self.home / ".config" / "systemd"
        os.chmod(systemd, 0o600)
        self.addCleanup(os.chmod, systemd, 0o755)
        if os.geteuid() == 0:
            self.assert_left_to_archinstall()
        else:
            # Unprivileged, the walk cannot even look inside: also left alone.
            done, run, _ = self.enable()
            self.assertFalse(done)
            run.assert_not_called()

    def test_a_file_where_a_link_would_be_staged_is_not_touched(self):
        self.wants.mkdir(parents=True)
        (self.wants / f".{SERVICE}.omarchy-new").write_text("someone else's")
        self.assert_left_to_archinstall()
        self.assertEqual((self.wants / f".{SERVICE}.omarchy-new").read_text(), "someone else's")

    def test_a_directory_or_foreign_link_where_a_unit_goes_is_left_to_archinstall(self):
        self.wants.mkdir(parents=True)
        (self.wants / SERVICE).mkdir()
        self.assert_left_to_archinstall()
        (self.wants / SERVICE).rmdir()
        (self.wants / SERVICE).symlink_to("/somewhere/else")
        self.assert_left_to_archinstall()

    def test_a_user_or_group_the_target_does_not_have_is_left_to_archinstall(self):
        done, run, _ = self.enable([types.SimpleNamespace(username="grace")])
        self.assertFalse(done)
        (self.target / "etc" / "group").write_text("root:x:0:\nusers:x:1007:\n")
        self.assert_left_to_archinstall()

    def test_nothing_is_changed_for_any_user_when_one_is_left_to_archinstall(self):
        done, run, _ = self.enable(self.ada + [types.SimpleNamespace(username="grace")])
        self.assertFalse(done)
        run.assert_not_called()
        self.assertFalse(self.wants.exists())

    def fake_archinstall(self):
        calls = []

        class AudioApp:
            def _enable_pipewire(self, install_session, users=None):
                calls.append(users)
        module = types.ModuleType("archinstall.applications.audio")
        module.AudioApp = AudioApp
        modules = {"archinstall": types.ModuleType("archinstall"),
                   "archinstall.applications": types.ModuleType("archinstall.applications"),
                   "archinstall.applications.audio": module}
        return AudioApp, calls, modules

    def test_archinstalls_method_is_swapped_for_the_block_and_put_back(self):
        AudioApp, calls, modules = self.fake_archinstall()
        original = AudioApp._enable_pipewire
        with mock.patch.dict(sys.modules, modules), \
                mock.patch.object(phases_impl, "_enable_pipewire_without_chroot", return_value=True) as ours:
            with phases_impl._pipewire_units_without_chroot():
                AudioApp()._enable_pipewire(self.session, self.ada)
                AudioApp()._enable_pipewire(self.session, None)
            self.assertIs(AudioApp._enable_pipewire, original)
        ours.assert_called_once_with(self.session, self.ada)
        self.assertEqual(calls, [])

    def test_archinstalls_own_commands_run_for_a_target_left_to_it(self):
        AudioApp, calls, modules = self.fake_archinstall()
        with mock.patch.dict(sys.modules, modules), \
                mock.patch.object(phases_impl, "_enable_pipewire_without_chroot", return_value=False):
            with phases_impl._pipewire_units_without_chroot():
                AudioApp()._enable_pipewire(self.session, self.ada)
        self.assertEqual(calls, [self.ada])

    def test_an_archinstall_without_the_method_keeps_its_own_way(self):
        with mock.patch.dict(sys.modules, {"archinstall.applications.audio": None,
                                           "archinstall.lib.applications.audio": None}):
            with phases_impl._pipewire_units_without_chroot():
                pass

    def test_the_application_step_runs_inside_the_swap(self):
        source = Path(phases_impl.__file__).read_text()
        self.assertIn('_time_step("STEP.install_applications"), _pipewire_units_without_chroot():', source)


if __name__ == "__main__":
    unittest.main()
