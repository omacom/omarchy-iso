"""Hardware layers: the installer picks the first one whose check passes in
the target, and a platform's own layer comes first."""

import subprocess
import sys
import tempfile
import threading
from contextlib import ExitStack
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


class HardwareLayerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        tmp = Path(self.tmp.name)
        self.images = tmp / "arch"
        self.definitions = tmp / "hardware-layers"
        self.images.mkdir()
        self.definitions.mkdir()
        self.ctx = types.SimpleNamespace(target=Path("/mnt"))

    def tearDown(self):
        self.tmp.cleanup()

    def define(self, name, packed=True):
        (self.definitions / f"{name}.layer").write_text(f"layer_arch=x86_64\nlayer_packages=({name})\n")
        if packed:
            (self.images / f"omarchy-layer.{name}.tar.zst").write_bytes(b"")

    def pick(self, passing):
        def run(argv, **kwargs):
            name = kwargs["input"].split("layer_packages=(")[1].split(")")[0]
            return subprocess.CompletedProcess(argv, 0 if name in passing else 1)

        with mock.patch.object(phases_impl.subprocess, "run", side_effect=run) as runner:
            layer = phases_impl._hardware_layer(self.ctx, self.images, self.definitions)
        return layer, runner

    def test_the_check_runs_in_the_target(self):
        self.define("intel-ptl-ipu7")
        layer, runner = self.pick({"intel-ptl-ipu7"})
        self.assertEqual(layer, self.images / "omarchy-layer.intel-ptl-ipu7.tar.zst")
        argv = runner.call_args.args[0]
        self.assertEqual(argv, ["arch-chroot", "/mnt", "bash", "-s"])
        self.assertTrue(runner.call_args.kwargs["input"].rstrip().endswith("layer_matches"))

    def test_the_first_passing_layer_in_name_order_wins(self):
        for name in ("c-layer", "a-layer", "b-layer"):
            self.define(name)
        layer, _ = self.pick({"b-layer", "c-layer"})
        self.assertEqual(layer, self.images / "omarchy-layer.b-layer.tar.zst")

    def test_no_passing_check_means_no_layer(self):
        self.define("intel-ptl-ipu7")
        layer, _ = self.pick(set())
        self.assertIsNone(layer)

    def test_a_layer_the_build_did_not_pack_is_never_checked(self):
        self.define("intel-ptl-ipu7", packed=False)
        layer, runner = self.pick({"intel-ptl-ipu7"})
        self.assertIsNone(layer)
        runner.assert_not_called()

    def test_the_check_is_told_the_selected_kernels(self):
        self.define("intel-ptl-ipu7")
        self.ctx.user_configuration = {"kernels": ["linux-omarchy", "linux-lts"]}
        _, runner = self.pick({"intel-ptl-ipu7"})
        self.assertEqual(runner.call_args.kwargs["env"]["OMARCHY_INSTALL_KERNELS"], "linux-omarchy linux-lts")

    def test_the_shipped_definitions_are_where_the_installer_looks(self):
        shipped = ROOT / "configs/airootfs" / phases_impl.HARDWARE_LAYERS_DIR.relative_to("/")
        self.assertTrue(sorted(shipped.glob("*.layer")), shipped)


class LayerScriptletsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.target = Path(self.tmp.name)
        self.ctx = types.SimpleNamespace(target=self.target, username="emir")
        self.listing = self.target / phases_impl.LAYER_SCRIPTLETS

    def tearDown(self):
        self.tmp.cleanup()

    def test_no_layer_runs_nothing(self):
        with mock.patch.object(phases_impl.subprocess, "run") as run:
            phases_impl._run_layer_scriptlets(self.ctx)
        run.assert_not_called()

    def test_each_post_install_runs_in_order_for_the_user(self):
        self.listing.parent.mkdir(parents=True)
        self.listing.write_text("tool 3-1\nintel-ipu7-camera 1.0.6-4\n")
        done = subprocess.CompletedProcess([], 0, "", "")
        with mock.patch.object(phases_impl.subprocess, "run", return_value=done) as run, \
                mock.patch.object(phases_impl, "info"):
            phases_impl._run_layer_scriptlets(self.ctx)
        calls = [c.args[0] for c in run.call_args_list]
        self.assertEqual([c[-2] for c in calls], [
            "/var/lib/pacman/local/tool-3-1/install",
            "/var/lib/pacman/local/intel-ipu7-camera-1.0.6-4/install",
        ])
        self.assertEqual([c[-1] for c in calls], ["3-1", "1.0.6-4"])
        self.assertEqual(calls[0][:3], ["arch-chroot", str(self.target), "/bin/sh"])
        self.assertIn("post_install", calls[0][4])
        self.assertEqual(run.call_args.kwargs["env"]["OMARCHY_INSTALL_USER"], "emir")
        # Like pacman's, the scriptlets' output reaches the install log.
        self.assertNotIn("capture_output", run.call_args.kwargs)
        self.assertIsNone(run.call_args.kwargs.get("stdout"))
        self.assertFalse(self.listing.exists())

    def test_a_failed_scriptlet_does_not_stop_the_install(self):
        self.listing.parent.mkdir(parents=True)
        self.listing.write_text("broken 1-1\nfine 1-1\n")
        results = [subprocess.CompletedProcess([], 1), subprocess.CompletedProcess([], 0)]
        with mock.patch.object(phases_impl.subprocess, "run", side_effect=results) as run, \
                mock.patch.object(phases_impl, "info") as info:
            phases_impl._run_layer_scriptlets(self.ctx)
        self.assertEqual(run.call_count, 2)
        self.assertIn("broken post_install failed (exit 1)", info.call_args_list[0].args[0])

    def test_they_run_once_the_user_exists(self):
        source = Path(phases_impl.__file__).read_text()
        body = source[source.index("def arch_install_system("):]
        users = body.index("_create_users_with_reflink_skel(ctx, installer")
        scriptlets = body.index("_run_layer_scriptlets(ctx)")
        applications = body.index("arch.install_applications(")
        self.assertLess(users, scriptlets)
        self.assertLess(scriptlets, applications)


class ApplyLayerTest(unittest.TestCase):
    ctx = types.SimpleNamespace(target=Path("/mnt"))

    def test_a_platform_layer_comes_first(self):
        platform_layer = Path("/run/archiso/bootmnt/arch/aarch64/omarchy-layer.aarch64-n1x.tar.zst")
        with mock.patch.object(phases_impl, "_platform_layer", return_value=platform_layer), \
                mock.patch.object(phases_impl, "_hardware_layer") as hardware, \
                mock.patch.object(Path, "stat", return_value=types.SimpleNamespace(st_size=0)), \
                mock.patch.object(phases_impl, "info"), \
                mock.patch.object(phases_impl.subprocess, "run") as run:
            phases_impl._apply_platform_layer(self.ctx)
        hardware.assert_not_called()
        self.assertIn(str(platform_layer), run.call_args.args[0])

    def test_a_hardware_layer_follows_when_the_platform_has_none(self):
        hardware_layer = Path("/run/archiso/bootmnt/arch/x86_64/omarchy-layer.intel-ptl-ipu7.tar.zst")
        with mock.patch.object(phases_impl, "_platform_layer", return_value=None), \
                mock.patch.object(phases_impl, "_hardware_layer", return_value=hardware_layer), \
                mock.patch.object(Path, "stat", return_value=types.SimpleNamespace(st_size=0)), \
                mock.patch.object(phases_impl, "info"), \
                mock.patch.object(phases_impl.subprocess, "run") as run:
            phases_impl._apply_platform_layer(self.ctx)
        argv = run.call_args.args[0]
        self.assertEqual(argv[:3], ["tar", "--zstd", "-xpf"])
        self.assertIn(str(hardware_layer), argv)

    def test_neither_extracts_nothing(self):
        with mock.patch.object(phases_impl, "_platform_layer", return_value=None), \
                mock.patch.object(phases_impl, "_hardware_layer", return_value=None), \
                mock.patch.object(phases_impl.subprocess, "run") as run:
            phases_impl._apply_platform_layer(self.ctx)
        run.assert_not_called()




class LayerWorkerTest(unittest.TestCase):
    """Exercise the background platform-layer worker inside arch_install_system:
    disjoint setup overlaps extraction, package deltas and user creation wait
    until extraction finishes, errors propagate, and interrupts terminate tar."""

    def _run_install(self, target, apply_side_effect, events=None, *, on_setup=None):
        if events is None:
            events = []
        installer = mock.MagicMock()
        installer.target = target
        config = types.SimpleNamespace(
            kernels=["linux-omarchy"],
            locale_config=None,
            mirror_config=None,
            swap=types.SimpleNamespace(enabled=False),
            auth_config=types.SimpleNamespace(users=["emir"]),
            app_config=None,
            timezone="UTC",
            ntp=False,
            hostname="test",
            disk_config=None,
        )
        ctx = types.SimpleNamespace(
            state={"arch_config_handler": types.SimpleNamespace(config=config), "mirror_handler": None},
            target=target,
            state_dir=target / "state",
            tailscale_authkey_path=None,
            defer_provisioning=False,
            omarchy_install={},
            user_configuration={"kernels": ["linux-omarchy"]},
            username="emir",
        )
        layer = target / "omarchy-layer.test.tar.zst"
        layer.write_bytes(b"")

        def kb_step(*args, **kwargs):
            events.append("configure_keyboard")
            if on_setup:
                on_setup()
            return True

        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(phases_impl, "info"))
            stack.enter_context(mock.patch.object(phases_impl, "_install_root_image"))
            stack.enter_context(mock.patch.object(phases_impl, "_start_skel_warmup"))
            stack.enter_context(mock.patch.object(phases_impl, "_start_luks_keyslot_enroll"))
            stack.enter_context(mock.patch.object(phases_impl, "_start_target_keyring_init"))
            stack.enter_context(mock.patch.object(phases_impl, "_platform_layer", return_value=layer))
            stack.enter_context(mock.patch.object(phases_impl, "_apply_platform_layer", side_effect=apply_side_effect))
            stack.enter_context(mock.patch.object(phases_impl, "_start_library_warmup",
                                                  side_effect=lambda c: events.append("library_warmup")))
            stack.enter_context(mock.patch.object(phases_impl, "_mount_offline_package_cache"))
            stack.enter_context(mock.patch.object(phases_impl, "_unmount_offline_package_cache"))
            stack.enter_context(mock.patch.object(phases_impl, "_mask_mkinitcpio_pacman_hooks"))
            stack.enter_context(mock.patch.object(phases_impl, "_unmask_mkinitcpio_pacman_hooks"))
            stack.enter_context(mock.patch.object(phases_impl, "_platform_delta_packages", return_value=[]))
            stack.enter_context(mock.patch.object(phases_impl, "_configure_limine_boot",
                                                  side_effect=lambda *a, **kw: events.append("configure_limine")))
            stack.enter_context(mock.patch.object(phases_impl, "_create_users_with_reflink_skel",
                                                  side_effect=lambda *a, **kw: events.append("create_users")))
            stack.enter_context(mock.patch.object(phases_impl, "_run_layer_scriptlets",
                                                  side_effect=lambda c: events.append("layer_scriptlets")))
            stack.enter_context(mock.patch.object(phases_impl, "_write_language_marker"))
            stack.enter_context(mock.patch.object(phases_impl, "_write_region_marker"))
            stack.enter_context(mock.patch.object(phases_impl, "_set_timezone_direct", return_value=True))
            stack.enter_context(mock.patch.object(phases_impl, "configure_keyboard", side_effect=kb_step))
            stack.enter_context(mock.patch.object(phases_impl.arch, "is_pre_mount", create=True, return_value=True))
            stack.enter_context(mock.patch.object(phases_impl.arch, "is_encrypted", create=True, return_value=False))
            stack.enter_context(mock.patch.object(phases_impl.arch, "sanity_check", create=True))
            stack.enter_context(mock.patch.object(phases_impl.arch, "root_user", create=True, return_value=None))
            stack.enter_context(mock.patch.object(phases_impl.arch, "target_missing_packages", create=True, return_value=[]))
            stack.enter_context(mock.patch.object(phases_impl.arch, "install_base_delta", create=True,
                                                  side_effect=lambda *a, **kw: events.append("install_base_delta")))
            opened = stack.enter_context(mock.patch.object(phases_impl.arch, "open_installer", create=True))
            opened.return_value.__enter__.return_value = installer
            stack.enter_context(mock.patch.object(phases_impl, "_write_pre_mounted_fstab",
                                                  side_effect=lambda c: events.append("genfstab")))
            phases_impl.arch_install_system(ctx)
        return events

    def test_layer_worker_overlaps_setup_and_joins_before_packages_and_users(self):
        started = threading.Event()
        release = threading.Event()
        events = []

        def fake_apply(ctx, layer=None, proc_box=None):
            started.set()
            self.assertTrue(release.wait(timeout=5))
            events.append("layer_finished")

        def during_setup():
            self.assertTrue(started.wait(timeout=5))
            self.assertNotIn("layer_finished", events)
            release.set()

        with tempfile.TemporaryDirectory() as tmp:
            self._run_install(Path(tmp), fake_apply, events, on_setup=during_setup)

        self.assertLess(events.index("configure_keyboard"), events.index("layer_finished"))
        self.assertLess(events.index("layer_finished"), events.index("library_warmup"))
        self.assertLess(events.index("library_warmup"), events.index("install_base_delta"))
        self.assertLess(events.index("install_base_delta"), events.index("create_users"))

    def test_layer_worker_failure_propagates_and_skips_packages_and_users(self):
        events = []

        def boom(ctx, layer=None, proc_box=None):
            raise subprocess.CalledProcessError(2, ["tar"])

        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(subprocess.CalledProcessError):
                self._run_install(Path(tmp), boom, events)
        self.assertNotIn("install_base_delta", events)
        self.assertNotIn("create_users", events)

    def test_layer_worker_interrupt_terminates_extraction_subprocess(self):
        fake_proc = mock.Mock()
        proc_registered = threading.Event()
        release = threading.Event()

        def fake_apply(ctx, layer=None, proc_box=None):
            proc_box.append(fake_proc)
            proc_registered.set()
            release.wait(timeout=5)

        orig_join = threading.Thread.join
        interrupted = {"done": False}

        def interrupt_layer_join(self, timeout=None):
            if self.name == "omarchy-platform-layer" and not interrupted["done"]:
                interrupted["done"] = True
                proc_registered.wait(timeout=5)
                release.set()
                raise KeyboardInterrupt()
            return orig_join(self, timeout=timeout)

        with tempfile.TemporaryDirectory() as tmp,                 mock.patch.object(threading.Thread, "join", interrupt_layer_join):
            with self.assertRaises(KeyboardInterrupt):
                self._run_install(Path(tmp), fake_apply)
        fake_proc.terminate.assert_called_once()
        fake_proc.wait.assert_called_once()


if __name__ == "__main__":
    unittest.main()
