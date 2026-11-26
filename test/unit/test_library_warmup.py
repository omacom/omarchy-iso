"""The installer reads the written image's libraries in the background, so
the first pacman transaction's ldconfig finds them cached."""

import subprocess
import sys
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


class LibraryWarmupTest(unittest.TestCase):
    def ctx(self):
        return types.SimpleNamespace(target=Path("/mnt"), state={})

    def test_the_scan_only_reads(self):
        ctx = self.ctx()
        with mock.patch.object(phases_impl.subprocess, "Popen") as popen:
            phases_impl._start_library_warmup(ctx)
        argv = popen.call_args.args[0]
        self.assertEqual(argv[:3], ["ldconfig", "-r", "/mnt"])
        # No cache, no links, no auxiliary cache: nothing for a later ldconfig to race.
        self.assertEqual(set(argv[3:]), {"-N", "-X", "-i"})
        self.assertIs(ctx.state["library_warmup_proc"], popen.return_value)

    def test_a_scan_that_cannot_start_does_not_stop_the_install(self):
        ctx = self.ctx()
        with mock.patch.object(phases_impl.subprocess, "Popen", side_effect=FileNotFoundError("ldconfig")), \
                mock.patch.object(phases_impl, "info") as info:
            phases_impl._start_library_warmup(ctx)
        self.assertNotIn("library_warmup_proc", ctx.state)
        self.assertIn("did not start", info.call_args.args[0])

    def test_an_interrupted_join_leaves_the_scan_for_the_exit_path(self):
        ctx = self.ctx()
        proc = mock.Mock()
        proc.wait.side_effect = [KeyboardInterrupt, 0]
        proc.poll.return_value = None
        ctx.state["library_warmup_proc"] = proc
        with self.assertRaises(KeyboardInterrupt):
            phases_impl._join_library_warmup(ctx)
        self.assertIs(ctx.state["library_warmup_proc"], proc)
        phases_impl.stop_library_warmup(ctx)
        proc.kill.assert_called_once()
        self.assertNotIn("library_warmup_proc", ctx.state)

    def test_the_join_waits_and_a_failed_scan_does_not_stop_the_install(self):
        ctx = self.ctx()
        proc = mock.Mock()
        proc.wait.return_value = 1
        ctx.state["library_warmup_proc"] = proc
        with mock.patch.object(phases_impl, "info") as info:
            phases_impl._join_library_warmup(ctx)
        proc.wait.assert_called_once()
        self.assertNotIn("library_warmup_proc", ctx.state)
        self.assertIn("exited 1", info.call_args.args[0])

    def test_the_exit_path_ends_a_running_scan(self):
        ctx = self.ctx()
        proc = mock.Mock()
        proc.poll.return_value = None
        ctx.state["library_warmup_proc"] = proc
        phases_impl.stop_library_warmup(ctx)
        proc.kill.assert_called_once()
        proc.wait.assert_called_once()
        self.assertNotIn("library_warmup_proc", ctx.state)

    def test_nothing_started_means_nothing_to_join_or_stop(self):
        ctx = self.ctx()
        phases_impl._join_library_warmup(ctx)
        phases_impl.stop_library_warmup(ctx)

    def test_it_starts_after_the_image_and_layer_and_before_any_package(self):
        source = Path(phases_impl.__file__).read_text()
        body = source[source.index("def arch_install_system("):]
        image = body.index("_install_root_image(ctx)")
        layer = body.index("_apply_platform_layer(ctx)")
        warmup = body.index("_start_library_warmup(ctx)")
        delta = body.index("arch.install_base_delta(")
        self.assertLess(image, layer)
        self.assertLess(layer, warmup)
        self.assertLess(warmup, delta)

    def test_it_ends_before_the_snapshot_and_on_the_exit_path(self):
        source = Path(phases_impl.__file__).read_text()
        snapshot = source[source.index("def create_factory_snapshot("):]
        self.assertLess(snapshot.index("_join_library_warmup(ctx)"), snapshot.index("_findmnt_value(ctx.target"))
        main = (ORCHESTRATOR / "main.py").read_text()
        cleanup = main[main.index("finally:"):]
        self.assertLess(cleanup.index("stop_library_warmup(ctx)"), cleanup.index("cleanup_bind_mounts(ctx)"))


if __name__ == "__main__":
    unittest.main()
