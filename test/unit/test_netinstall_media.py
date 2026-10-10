"""Unit tests for the netinstall medium's plumbing in the orchestrator.

The same harness as the other orchestrator tests: phases_impl imports the
archinstall adapter at module scope, which pulls in a library that only exists
on the live ISO, so the adapter is stubbed out before the import. What is under
test here is the medium decision (which install medium this is, and what that
changes) and the keyring the target is given on netinstall media.
"""

import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules["orchestrator.archinstall_adapter"] = types.ModuleType("orchestrator.archinstall_adapter")

from orchestrator import phases_impl  # noqa: E402


class MediaModeTest(unittest.TestCase):
    """The marker decides, and anything unrecognised stays offline."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.marker = Path(self.tmp.name) / "omarchy_media"

        env = mock.patch.dict("os.environ", {"OMARCHY_MEDIA_FILE": str(self.marker)})
        env.start()
        self.addCleanup(env.stop)

    def write(self, content):
        self.marker.write_text(content, encoding="utf-8")

    def test_missing_marker_is_offline(self):
        self.assertEqual(phases_impl._media_mode(), "offline")
        self.assertFalse(phases_impl._is_netinstall())

    def test_offline_marker(self):
        self.write("offline\n")
        self.assertEqual(phases_impl._media_mode(), "offline")

    def test_netinstall_marker(self):
        self.write("netinstall\n")
        self.assertEqual(phases_impl._media_mode(), "netinstall")
        self.assertTrue(phases_impl._is_netinstall())

    def test_marker_survives_surrounding_whitespace(self):
        self.write("  netinstall  \n")
        self.assertTrue(phases_impl._is_netinstall())

    def test_unknown_marker_falls_back_to_offline(self):
        self.write("something-else\n")
        self.assertEqual(phases_impl._media_mode(), "offline")


class OfflinePackageCacheTest(unittest.TestCase):
    """netinstall has no bundled repo; the mount pair has to be a no-op."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ctx = types.SimpleNamespace(target=Path(self.tmp.name), state={})

        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

        self.runs = []
        run_patch = mock.patch.object(
            phases_impl.subprocess, "run", side_effect=lambda *a, **k: self.runs.append(a)
        )
        run_patch.start()
        self.addCleanup(run_patch.stop)

    def set_media(self, mode):
        marker = Path(self.tmp.name) / "omarchy_media"
        marker.write_text(mode, encoding="utf-8")
        env = mock.patch.dict("os.environ", {"OMARCHY_MEDIA_FILE": str(marker)})
        env.start()
        self.addCleanup(env.stop)

    def test_netinstall_mounts_nothing(self):
        self.set_media("netinstall")

        phases_impl._mount_offline_package_cache(self.ctx)
        phases_impl._unmount_offline_package_cache(self.ctx)

        self.assertEqual(self.runs, [])
        self.assertNotIn("bind_mounts", self.ctx.state)

    def test_offline_without_a_mirror_still_fails(self):
        self.set_media("offline")

        # The check is against an absolute path that a developer machine may
        # well have (an installed system keeps an empty one around), so say
        # explicitly that this one is not there.
        real_is_dir = Path.is_dir

        def is_dir(self):
            if str(self) == "/var/cache/omarchy/mirror/offline":
                return False
            return real_is_dir(self)

        with mock.patch.object(Path, "is_dir", is_dir):
            with self.assertRaises(RuntimeError):
                phases_impl._mount_offline_package_cache(self.ctx)


class PopulateTargetKeyringTest(unittest.TestCase):
    """The target is given the keyrings its own pacman.conf verifies against."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.ctx = types.SimpleNamespace(target=Path(self.tmp.name), state={})

        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

        self.commands = []
        run_patch = mock.patch.object(
            phases_impl.subprocess, "run", side_effect=lambda cmd, *a, **k: self.commands.append(cmd)
        )
        run_patch.start()
        self.addCleanup(run_patch.stop)

    def keyring_files(self, present):
        real_exists = Path.exists

        def exists(self):
            if str(self).startswith("/usr/share/pacman/keyrings/"):
                return any(self.name.startswith(name) for name in present)
            return real_exists(self)

        return mock.patch.object(Path, "exists", exists)

    def populated(self):
        return [cmd[cmd.index("--populate") + 1] for cmd in self.commands]

    def test_both_keyrings_are_populated(self):
        with self.keyring_files({"archlinux.gpg", "omarchy.gpg"}):
            phases_impl._populate_target_keyring(self.ctx)

        self.assertEqual(self.populated(), ["archlinux", "omarchy"])
        for cmd in self.commands:
            self.assertEqual(cmd[0], "pacman-key")
            self.assertEqual(cmd[1], "--gpgdir")
            self.assertEqual(cmd[2], str(self.ctx.target / "etc" / "pacman.d" / "gnupg"))

    def test_absent_keyring_files_are_skipped(self):
        with self.keyring_files({"archlinux.gpg"}):
            phases_impl._populate_target_keyring(self.ctx)

        self.assertEqual(self.populated(), ["archlinux"])


class PrepareTargetSetupTest(unittest.TestCase):
    """netinstall binds /opt/packages only, and populates keys before chroot."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name)
        (self.target / "etc").mkdir(parents=True, exist_ok=True)
        self.ctx = types.SimpleNamespace(target=self.target, state={})

        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

        self.runs = []
        run_patch = mock.patch.object(
            phases_impl.subprocess, "run", side_effect=lambda *a, **k: self.runs.append(a)
        )
        run_patch.start()
        self.addCleanup(run_patch.stop)

        keyring_patch = mock.patch.object(phases_impl, "_populate_target_keyring")
        self.populate = keyring_patch.start()
        self.addCleanup(keyring_patch.stop)

    def set_media(self, mode):
        marker = Path(self.tmp.name) / "omarchy_media"
        marker.write_text(mode, encoding="utf-8")
        env = mock.patch.dict("os.environ", {"OMARCHY_MEDIA_FILE": str(marker)})
        env.start()
        self.addCleanup(env.stop)

    def mounted(self):
        """The destinations of the bind mounts the phase asks for."""
        return [call[0][3] for call in self.runs if call[0][0] == "mount"]

    def test_netinstall_skips_the_mirror_and_populates_keys(self):
        self.set_media("netinstall")

        phases_impl._prepare_target_setup(self.ctx)

        self.assertEqual(self.mounted(), [str(self.target / "opt" / "packages")])
        self.populate.assert_called_once_with(self.ctx)
        self.assertTrue(self.ctx.state["target_setup_prepared"])

    def test_offline_mounts_the_mirror_and_leaves_the_keyring_alone(self):
        self.set_media("offline")

        phases_impl._prepare_target_setup(self.ctx)

        self.assertIn(str(self.target / "var" / "cache" / "omarchy" / "mirror" / "offline"), self.mounted())
        self.populate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
