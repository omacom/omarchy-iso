"""Unit tests for rootfs-image restore via multithreaded unsquashfs."""

import io
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules["orchestrator.archinstall_adapter"] = types.ModuleType("orchestrator.archinstall_adapter")

from orchestrator import phases_impl  # noqa: E402


class FakeProc:
    def __init__(self, lines, returncode=0):
        self.stdout = io.StringIO("".join(f"{line}\n" for line in lines))
        self._returncode = returncode

    def wait(self):
        return self._returncode


class RestoreRootfsImageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.target = root / "mnt"
        self.target.mkdir()
        self.image = root / "omarchy-rootfs.sfs"
        self.image.write_bytes(b"squashfs-image\n")
        self.progress_path = root / "restore-progress"

        self.progress = []
        self.popen_cmds = []

        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

        image_patch = mock.patch.object(phases_impl, "ROOTFS_IMAGE_PATH", self.image)
        image_patch.start()
        self.addCleanup(image_patch.stop)

        progress_path_patch = mock.patch.object(
            phases_impl, "RESTORE_PROGRESS_PATH", self.progress_path
        )
        progress_path_patch.start()
        self.addCleanup(progress_path_patch.stop)

        write_patch = mock.patch.object(
            phases_impl, "_write_restore_progress", side_effect=self.progress.append
        )
        write_patch.start()
        self.addCleanup(write_patch.stop)

        pct_patch = mock.patch.object(
            phases_impl, "_unsquashfs_supports_percentage", return_value=True
        )
        pct_patch.start()
        self.addCleanup(pct_patch.stop)

        cpu_patch = mock.patch.object(phases_impl, "_unsquashfs_processors", return_value=8)
        cpu_patch.start()
        self.addCleanup(cpu_patch.stop)

        popen_patch = mock.patch.object(
            phases_impl.subprocess, "Popen", side_effect=self.fake_popen
        )
        popen_patch.start()
        self.addCleanup(popen_patch.stop)

    def ctx(self):
        return types.SimpleNamespace(target=self.target, state={})

    def fake_popen(self, cmd, **kwargs):
        self.popen_cmds.append(cmd)
        return FakeProc(["0", "50", "100"])

    def test_unsquashfs_command_shape(self):
        phases_impl._restore_rootfs_image(self.ctx())
        self.assertEqual(len(self.popen_cmds), 1)
        self.assertEqual(self.popen_cmds[0], [
            "unsquashfs", "-f", "-p", "8", "-d", str(self.target),
            "-percentage", str(self.image),
        ])

    def test_nonzero_exit_raises(self):
        def failing_popen(cmd, **kwargs):
            self.popen_cmds.append(cmd)
            return FakeProc(["0"], returncode=1)

        with mock.patch.object(phases_impl.subprocess, "Popen", side_effect=failing_popen):
            with self.assertRaisesRegex(RuntimeError, "unsquashfs failed"):
                phases_impl._restore_rootfs_image(self.ctx())

    def test_progress_is_passed_through_and_monotonic(self):
        phases_impl._restore_rootfs_image(self.ctx())
        values = [int(v) for v in self.progress]
        self.assertEqual(values, [0, 0, 50, 100, 100])
        self.assertEqual(values, sorted(values))

    def test_falls_back_to_no_progress_without_percentage_support(self):
        run_cmds = []

        def fake_run(cmd, **kwargs):
            run_cmds.append(cmd)
            return types.SimpleNamespace(returncode=0)

        with (
            mock.patch.object(
                phases_impl, "_unsquashfs_supports_percentage", return_value=False
            ),
            mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run),
        ):
            phases_impl._restore_rootfs_image(self.ctx())
        self.assertEqual(self.popen_cmds, [])
        self.assertEqual(run_cmds, [[
            "unsquashfs", "-f", "-p", "8", "-d", str(self.target),
            "-no-progress", str(self.image),
        ]])
        # No streamed percentages, but the terminal states still land.
        self.assertEqual([int(v) for v in self.progress], [0, 100])


class FakeKeyringProc:
    def __init__(self, returncode, output="keyring output"):
        self.returncode = returncode
        self._output = output

    def communicate(self):
        return self._output, None


class RootfsImageMarkerTest(unittest.TestCase):
    """The install-mode decision is the build-time marker, never the image
    file: an image ISO with a missing image must abort pre-format instead of
    falling back to a pacstrap the pruned mirror cannot feed."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.marker = Path(self.tmp.name) / "rootfs-image-build"
        self.image = Path(self.tmp.name) / "omarchy-rootfs.sfs"
        for attr, value in (
            ("ROOTFS_IMAGE_BUILD_MARKER", self.marker),
            ("ROOTFS_IMAGE_PATH", self.image),
        ):
            patch = mock.patch.object(phases_impl, attr, value)
            patch.start()
            self.addCleanup(patch.stop)

    def test_marker_presence_decides_the_install_mode(self):
        self.assertFalse(phases_impl._is_rootfs_image_install())
        self.marker.write_text("omarchy-rootfs.sfs\n")
        self.assertTrue(phases_impl._is_rootfs_image_install())

    def test_missing_image_refuses_the_install(self):
        with self.assertRaisesRegex(RuntimeError, "refusing to touch the disk"):
            phases_impl._assert_rootfs_image_available()

    def test_present_image_passes(self):
        self.image.write_bytes(b"sfs")
        phases_impl._assert_rootfs_image_available()


class InstallViaRootfsImageKeyFilesTest(unittest.TestCase):
    """generate_key_files must follow the restore: it appends to the target's
    /etc/crypttab, which unsquashfs -f would otherwise overwrite."""

    def run_install(self, *, encrypted, pre_mounted=False):
        calls = []
        installer = mock.Mock()
        installer.generate_key_files.side_effect = (
            lambda: calls.append("generate_key_files")
        )
        patches = [
            mock.patch.object(phases_impl, "info"),
            mock.patch.object(phases_impl.subprocess, "run"),
            mock.patch.object(
                phases_impl, "_assert_rootfs_image_supported_config"
            ),
            mock.patch.object(
                phases_impl, "_restore_rootfs_image",
                side_effect=lambda ctx: calls.append("restore"),
            ),
            mock.patch.object(phases_impl, "_rootfs_image_configure"),
            mock.patch.object(phases_impl, "_start_target_keyring_init"),
            mock.patch.object(phases_impl, "_finish_target_keyring_init"),
            mock.patch.object(
                phases_impl.arch, "is_pre_mount",
                lambda config: pre_mounted, create=True,
            ),
            mock.patch.object(
                phases_impl.arch, "is_encrypted",
                lambda config: encrypted, create=True,
            ),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        ctx = types.SimpleNamespace(target=Path("/mnt/target"))
        phases_impl._install_via_rootfs_image(ctx, installer, object(), object())
        return calls

    def test_encrypted_generates_key_files_after_the_restore(self):
        self.assertEqual(
            self.run_install(encrypted=True), ["restore", "generate_key_files"]
        )

    def test_unencrypted_skips_key_files(self):
        self.assertEqual(self.run_install(encrypted=False), ["restore"])

    def test_pre_mounted_skips_key_files(self):
        self.assertEqual(
            self.run_install(encrypted=True, pre_mounted=True), ["restore"]
        )


class StartTargetKeyringInitTest(unittest.TestCase):
    def test_shell_leads_its_own_process_group(self):
        with mock.patch.object(phases_impl, "info"), \
                mock.patch.object(phases_impl.subprocess, "Popen") as popen:
            phases_impl._start_target_keyring_init(
                types.SimpleNamespace(target=Path("/mnt/target"))
            )
        self.assertTrue(popen.call_args.kwargs["start_new_session"])


class KillTargetKeyringInitTest(unittest.TestCase):
    def test_kills_the_whole_process_group(self):
        with mock.patch.object(phases_impl.os, "killpg") as killpg:
            phases_impl._kill_target_keyring_init(types.SimpleNamespace(pid=1234))
        killpg.assert_called_once_with(1234, phases_impl.signal.SIGKILL)

    def test_tolerates_an_already_dead_group(self):
        with mock.patch.object(
            phases_impl.os, "killpg", side_effect=ProcessLookupError
        ):
            phases_impl._kill_target_keyring_init(types.SimpleNamespace(pid=1234))


class FinishTargetKeyringInitTest(unittest.TestCase):
    def setUp(self):
        self.run_cmds = []

        info_patch = mock.patch.object(phases_impl, "info")
        info_patch.start()
        self.addCleanup(info_patch.stop)

        run_patch = mock.patch.object(
            phases_impl.subprocess, "run", side_effect=self.fake_run
        )
        run_patch.start()
        self.addCleanup(run_patch.stop)

    def fake_run(self, cmd, **kwargs):
        self.run_cmds.append(cmd)
        return types.SimpleNamespace(returncode=0)

    def ctx(self):
        return types.SimpleNamespace(target=Path("/mnt/target"))

    def assert_gpg_daemons_killed(self):
        self.assertEqual(self.run_cmds, [[
            "gpgconf", "--homedir", "/mnt/target/etc/pacman.d/gnupg",
            "--kill", "all",
        ]])

    def test_failure_raises_with_output_and_kills_gpg_daemons(self):
        with self.assertRaisesRegex(RuntimeError, "keyring output"):
            phases_impl._finish_target_keyring_init(
                self.ctx(), FakeKeyringProc(returncode=1), raise_on_error=True
            )
        self.assert_gpg_daemons_killed()

    def test_failure_is_swallowed_on_the_exception_path(self):
        phases_impl._finish_target_keyring_init(
            self.ctx(), FakeKeyringProc(returncode=1), raise_on_error=False
        )
        self.assert_gpg_daemons_killed()

    def test_success_does_not_raise(self):
        phases_impl._finish_target_keyring_init(
            self.ctx(), FakeKeyringProc(returncode=0), raise_on_error=True
        )
        self.assert_gpg_daemons_killed()


if __name__ == "__main__":
    unittest.main()
