"""Unit tests for rootfs-image restore via multithreaded unsquashfs."""

import io
import signal
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


class AssertRootfsImageSupportedConfigTest(unittest.TestCase):
    def config(self, **overrides):
        base = dict(
            app_config=None, mirror_config=None, disk_config=None, kernels=None
        )
        base.update(overrides)
        return types.SimpleNamespace(**base)

    def assert_rejected(self, pattern, **overrides):
        with self.assertRaisesRegex(RuntimeError, pattern):
            phases_impl._assert_rootfs_image_supported_config(
                self.config(**overrides)
            )

    def test_default_config_is_supported(self):
        phases_impl._assert_rootfs_image_supported_config(self.config())

    def test_non_pipewire_audio_is_rejected(self):
        self.assert_rejected(
            "bakes PipeWire",
            app_config=types.SimpleNamespace(
                audio_config=types.SimpleNamespace(audio="pulseaudio"),
                bluetooth_config=None,
            ),
        )

    def test_bluetooth_is_rejected(self):
        self.assert_rejected(
            "bluetooth_config",
            app_config=types.SimpleNamespace(
                audio_config=None,
                bluetooth_config=types.SimpleNamespace(enabled=True),
            ),
        )

    def test_optional_repositories_are_rejected(self):
        self.assert_rejected(
            "optional_repositories",
            mirror_config=types.SimpleNamespace(
                optional_repositories=["multilib"]
            ),
        )

    def test_lvm_is_rejected(self):
        self.assert_rejected(
            "lvm_config",
            disk_config=types.SimpleNamespace(lvm_config=object()),
        )

    def test_lvm_free_disk_config_is_supported(self):
        phases_impl._assert_rootfs_image_supported_config(
            self.config(disk_config=types.SimpleNamespace(lvm_config=None))
        )

    def disk_config_with_fs(self, *fs_values):
        return types.SimpleNamespace(
            lvm_config=None,
            device_modifications=[types.SimpleNamespace(partitions=[
                types.SimpleNamespace(
                    fs_type=(
                        types.SimpleNamespace(value=value)
                        if value is not None else None
                    )
                )
                for value in fs_values
            ])],
        )

    def test_filesystems_without_baked_tools_are_rejected(self):
        for fs in ("xfs", "f2fs"):
            self.assert_rejected(
                "filesystem tools",
                disk_config=self.disk_config_with_fs("fat32", fs),
            )

    def test_baked_filesystems_pass(self):
        phases_impl._assert_rootfs_image_supported_config(self.config(
            disk_config=self.disk_config_with_fs("fat32", "btrfs", "ext4")
        ))

    def test_partitions_without_an_fs_type_pass(self):
        phases_impl._assert_rootfs_image_supported_config(self.config(
            disk_config=self.disk_config_with_fs(None)
        ))

    def test_unsupported_kernel_is_rejected(self):
        self.assert_rejected("linux-zen", kernels=["linux", "linux-zen"])

    def test_supported_kernels_pass(self):
        for kernels in (None, ["linux"], ["linux-t2"], ["linux", "linux-t2"]):
            phases_impl._assert_rootfs_image_supported_config(
                self.config(kernels=kernels)
            )


class InstallAccessibilityToolsTest(unittest.TestCase):
    def run_helper(self, *, in_use):
        ctx = types.SimpleNamespace(state={})
        installer = mock.Mock()
        with mock.patch.object(phases_impl, "info"), mock.patch.object(
            phases_impl.arch, "accessibility_tools_in_use",
            lambda: in_use, create=True,
        ):
            phases_impl._install_accessibility_tools(ctx, installer)
        return ctx, installer

    def test_installs_the_screen_reader_stack_when_live_session_uses_one(self):
        ctx, installer = self.run_helper(in_use=True)
        installer.add_additional_packages.assert_called_once_with(
            ["brltty", "espeakup", "alsa-utils"]
        )
        self.assertTrue(ctx.state["target_db_synced"])

    def test_noop_without_accessibility_tools(self):
        ctx, installer = self.run_helper(in_use=False)
        installer.add_additional_packages.assert_not_called()
        self.assertEqual(ctx.state, {})


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
        ctx = types.SimpleNamespace(target=Path("/mnt/target"), state={})
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


class KeyringSigtermWindowTest(unittest.TestCase):
    """A dashboard stop SIGTERMs the orchestrator's process group, which the
    detached (start_new_session) keyring init survives. While the init runs,
    SIGTERM must raise so the except-BaseException path kills and joins it,
    and the previous disposition must come back afterwards."""

    def run_install(self, *, configure_side_effect):
        seen = {}

        def configure(ctx, installer, config, mirror_handler):
            seen["handler"] = signal.getsignal(signal.SIGTERM)
            if configure_side_effect is not None:
                raise configure_side_effect

        def start_keyring(ctx):
            ctx.state["target_keyring_proc"] = FakeKeyringProc(returncode=0)
            ctx.state["target_keyring_proc"].pid = 1234

        patches = [
            mock.patch.object(phases_impl, "info"),
            mock.patch.object(phases_impl.subprocess, "run"),
            mock.patch.object(phases_impl.os, "killpg"),
            mock.patch.object(
                phases_impl, "_assert_rootfs_image_supported_config"
            ),
            mock.patch.object(phases_impl, "_restore_rootfs_image"),
            mock.patch.object(
                phases_impl, "_rootfs_image_configure", side_effect=configure
            ),
            mock.patch.object(
                phases_impl, "_start_target_keyring_init",
                side_effect=start_keyring,
            ),
            mock.patch.object(
                phases_impl.arch, "is_pre_mount",
                lambda config: False, create=True,
            ),
            mock.patch.object(
                phases_impl.arch, "is_encrypted",
                lambda config: False, create=True,
            ),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        ctx = types.SimpleNamespace(target=Path("/mnt/target"), state={})
        phases_impl._install_via_rootfs_image(ctx, installer=mock.Mock(),
                                             config=object(),
                                             mirror_handler=object())
        return ctx, seen

    def test_sigterm_raises_inside_the_keyring_window(self):
        before = signal.getsignal(signal.SIGTERM)
        _, seen = self.run_install(configure_side_effect=None)
        self.assertIs(seen["handler"], phases_impl._raise_on_sigterm)
        with self.assertRaises(SystemExit):
            seen["handler"](signal.SIGTERM, None)
        self.assertIs(signal.getsignal(signal.SIGTERM), before)

    def test_exception_path_kills_and_joins_the_init(self):
        boom = RuntimeError("configure failed")
        with self.assertRaises(RuntimeError) as raised:
            self.run_install(configure_side_effect=boom)
        self.assertIs(raised.exception, boom)
        phases_impl.os.killpg.assert_called_once_with(
            1234, phases_impl.signal.SIGKILL
        )


class StartTargetKeyringInitTest(unittest.TestCase):
    def test_shell_leads_its_own_process_group(self):
        ctx = types.SimpleNamespace(target=Path("/mnt/target"), state={})
        with mock.patch.object(phases_impl, "info"), \
                mock.patch.object(phases_impl.subprocess, "Popen") as popen:
            phases_impl._start_target_keyring_init(ctx)
        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertIs(ctx.state["target_keyring_proc"], popen.return_value)


class KillTargetKeyringInitTest(unittest.TestCase):
    def ctx(self):
        return types.SimpleNamespace(
            state={"target_keyring_proc": types.SimpleNamespace(pid=1234)}
        )

    def test_kills_the_whole_process_group(self):
        with mock.patch.object(phases_impl.os, "killpg") as killpg:
            phases_impl._kill_target_keyring_init(self.ctx())
        killpg.assert_called_once_with(1234, phases_impl.signal.SIGKILL)

    def test_tolerates_an_already_dead_group(self):
        with mock.patch.object(
            phases_impl.os, "killpg", side_effect=ProcessLookupError
        ):
            phases_impl._kill_target_keyring_init(self.ctx())

    def test_noop_without_a_pending_init(self):
        with mock.patch.object(phases_impl.os, "killpg") as killpg:
            phases_impl._kill_target_keyring_init(types.SimpleNamespace(state={}))
        killpg.assert_not_called()


class AwaitTargetKeyringInitTest(unittest.TestCase):
    """pacstrap -K runs its own pacman-key --init on the target's gnupg dir,
    so every pacstrap-semantics site must join the background init first."""

    def test_joins_the_pending_init_exactly_once(self):
        ctx = types.SimpleNamespace(
            target=Path("/mnt/target"),
            state={"target_keyring_proc": FakeKeyringProc(returncode=0)},
        )
        with mock.patch.object(phases_impl, "info"), mock.patch.object(
            phases_impl, "_finish_target_keyring_init"
        ) as finish:
            phases_impl._await_target_keyring_init(ctx)
            phases_impl._await_target_keyring_init(ctx)
        finish.assert_called_once()
        self.assertNotIn("target_keyring_proc", ctx.state)

    def test_noop_without_a_pending_init(self):
        with mock.patch.object(
            phases_impl, "_finish_target_keyring_init"
        ) as finish:
            phases_impl._await_target_keyring_init(
                types.SimpleNamespace(state={})
            )
        finish.assert_not_called()

    def test_accessibility_install_joins_before_pacstrap(self):
        ctx = types.SimpleNamespace(
            target=Path("/mnt/target"),
            state={"target_keyring_proc": FakeKeyringProc(returncode=0)},
        )
        installer = mock.Mock()
        with mock.patch.object(phases_impl, "info"), \
                mock.patch.object(phases_impl.subprocess, "run"), \
                mock.patch.object(
                    phases_impl.arch, "accessibility_tools_in_use",
                    lambda: True, create=True,
                ):
            phases_impl._install_accessibility_tools(ctx, installer)
        self.assertNotIn("target_keyring_proc", ctx.state)
        installer.add_additional_packages.assert_called_once()


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
