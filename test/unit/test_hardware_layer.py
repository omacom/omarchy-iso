"""Hardware layers: the installer picks the first one whose check passes in
the target, and a platform's own layer comes first."""

import subprocess
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


if __name__ == "__main__":
    unittest.main()
