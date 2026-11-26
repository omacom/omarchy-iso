"""The installer reads /etc/skel's inodes in the background while the layer
is extracted, so the copy into the new home does not wait for each one."""

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


class SkelWarmupTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.target = Path(self.tmp.name)
        (self.target / "etc" / "skel").mkdir(parents=True)

    def ctx(self):
        return types.SimpleNamespace(target=self.target, state={})

    def test_the_walk_only_stats(self):
        ctx = self.ctx()
        with mock.patch.object(phases_impl.subprocess, "Popen") as popen:
            phases_impl._start_skel_warmup(ctx)
        self.assertEqual(popen.call_args.args[0], ["du", "-s", str(self.target / "etc" / "skel")])
        self.assertIs(ctx.state["skel_warmup_proc"], popen.return_value)

    def test_a_target_without_skel_starts_nothing(self):
        ctx = self.ctx()
        (self.target / "etc" / "skel").rmdir()
        with mock.patch.object(phases_impl.subprocess, "Popen") as popen:
            phases_impl._start_skel_warmup(ctx)
        popen.assert_not_called()
        self.assertEqual(ctx.state, {})

    def test_a_walk_that_cannot_start_does_not_stop_the_install(self):
        ctx = self.ctx()
        with mock.patch.object(phases_impl.subprocess, "Popen", side_effect=FileNotFoundError("du")), \
                mock.patch.object(phases_impl, "info") as info:
            phases_impl._start_skel_warmup(ctx)
        self.assertNotIn("skel_warmup_proc", ctx.state)
        self.assertIn("did not start", info.call_args.args[0])

    def test_both_readers_are_joined_and_a_failed_one_is_only_noted(self):
        ctx = self.ctx()
        skel, library = mock.Mock(), mock.Mock()
        skel.wait.return_value = 1
        library.wait.return_value = 0
        ctx.state.update(skel_warmup_proc=skel, library_warmup_proc=library)
        with mock.patch.object(phases_impl, "info") as info:
            phases_impl._join_library_warmup(ctx)
        skel.wait.assert_called_once()
        library.wait.assert_called_once()
        self.assertEqual(ctx.state, {})
        self.assertIn("skel warm-up exited 1", info.call_args.args[0])

    def test_the_exit_path_ends_both_readers(self):
        ctx = self.ctx()
        skel, library = mock.Mock(), mock.Mock()
        skel.poll.return_value = None
        library.poll.return_value = 0
        ctx.state.update(skel_warmup_proc=skel, library_warmup_proc=library)
        phases_impl.stop_library_warmup(ctx)
        skel.kill.assert_called_once()
        library.kill.assert_not_called()
        skel.wait.assert_called_once()
        library.wait.assert_called_once()
        self.assertEqual(ctx.state, {})

    def test_it_starts_when_the_image_is_in_place_and_before_the_users(self):
        source = Path(phases_impl.__file__).read_text()
        body = source[source.index("def arch_install_system("):]
        image = body.index("_install_root_image(ctx)")
        walk = body.index("_start_skel_warmup(ctx)")
        # Only an install that creates a user has a home to copy skel into.
        self.assertIn("if config.auth_config and config.auth_config.users:\n            _start_skel_warmup(ctx)", body)
        layer = body.index("_apply_platform_layer(ctx)")
        users = body.index("_create_users_with_reflink_skel(ctx,")
        self.assertLess(image, walk)
        self.assertLess(walk, layer)
        self.assertLess(walk, users)


if __name__ == "__main__":
    unittest.main()
