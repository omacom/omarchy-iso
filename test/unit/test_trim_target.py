"""Unit tests for the first-boot trim: phases_impl.stage_first_boot_trim stages
a self-removing first-boot fstrim unit on the target, never fails a completed
install, and main() calls it only after run() succeeds."""

import stat
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import main, phases_impl  # noqa: E402
from orchestrator.phases import PhaseError  # noqa: E402


class StageFirstBootTrimTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.target = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def stage(self):
        lines = []
        with mock.patch.object(phases_impl, "info", lines.append):
            phases_impl.stage_first_boot_trim(types.SimpleNamespace(target=self.target))
        return lines

    def test_stages_self_removing_background_trim_unit(self):
        lines = self.stage()

        unit = self.target / "etc/systemd/system" / phases_impl.FIRST_BOOT_TRIM_SERVICE
        link = (
            self.target
            / "etc/systemd/system/multi-user.target.wants"
            / phases_impl.FIRST_BOOT_TRIM_SERVICE
        )

        self.assertTrue(unit.is_file())
        self.assertEqual(stat.S_IMODE(unit.stat().st_mode), 0o644)
        self.assertTrue(link.is_symlink())
        self.assertEqual(
            str(link.readlink()),
            f"/etc/systemd/system/{phases_impl.FIRST_BOOT_TRIM_SERVICE}",
        )

        text = unit.read_text()
        self.assertIn("After=local-fs.target", text)
        self.assertIn("Type=simple", text)
        self.assertIn("Nice=19", text)
        self.assertIn("IOSchedulingClass=idle", text)
        self.assertIn(f"/usr/bin/timeout --kill-after=5 {phases_impl.TRIM_BUDGET} /usr/bin/fstrim --verbose / || true", text)
        self.assertIn(
            f"/usr/bin/rm -f /etc/systemd/system/multi-user.target.wants/{phases_impl.FIRST_BOOT_TRIM_SERVICE}"
            f" /etc/systemd/system/{phases_impl.FIRST_BOOT_TRIM_SERVICE}",
            text,
        )
        self.assertIn("WantedBy=multi-user.target", text)
        self.assertIn("staged one-time first-boot fstrim", lines[-1])

    def test_restaging_replaces_existing_symlink(self):
        wants = self.target / "etc/systemd/system/multi-user.target.wants"
        wants.mkdir(parents=True)
        (wants / phases_impl.FIRST_BOOT_TRIM_SERVICE).symlink_to("/stale/target")

        self.stage()

        link = wants / phases_impl.FIRST_BOOT_TRIM_SERVICE
        self.assertEqual(
            str(link.readlink()),
            f"/etc/systemd/system/{phases_impl.FIRST_BOOT_TRIM_SERVICE}",
        )

    def test_os_error_is_logged_and_does_not_raise(self):
        lines = []
        with mock.patch.object(phases_impl, "info", lines.append), \
                mock.patch.object(Path, "write_text", side_effect=OSError("read-only filesystem")):
            phases_impl.stage_first_boot_trim(types.SimpleNamespace(target=self.target))
        self.assertIn("WARNING: could not stage first-boot trim", lines[-1])
        self.assertIn("read-only filesystem", lines[-1])


class MainStagesTrimAfterRunTest(unittest.TestCase):
    """run() writes finished_at and creates @factory before returning. Staging
    the first-boot trim must come after run(), and only on success."""

    def main(self, run_error=None):
        events = []

        def fake_run(ctx, phases):
            events.append("run")
            if run_error:
                raise run_error

        ctx = types.SimpleNamespace(username="omarchy", target=Path("/mnt"))
        helpers = dict.fromkeys(
            ["boost_cpu_governor", "cleanup_bind_mounts", "cleanup_protected_state",
             "cleanup_target_hook_masks", "restore_cpu_governors", "stop_library_warmup",
             "stop_luks_keyslot_enroll", "stop_target_keyring_init"], mock.DEFAULT)
        with mock.patch.object(main.InstallContext, "from_env", return_value=ctx), \
                mock.patch.object(main, "run", fake_run), \
                mock.patch.object(main, "build_phases", return_value=[]), \
                mock.patch.object(phases_impl, "stage_first_boot_trim", lambda c: events.append("stage_trim")), \
                mock.patch.multiple(phases_impl, **helpers), \
                mock.patch.object(main, "info"), mock.patch.object(main, "error"):
            status = main.main()
        return status, events

    def test_a_finished_install_stages_first_boot_trim_after_run_returns(self):
        self.assertEqual(self.main(), (0, ["run", "stage_trim"]))

    def test_a_failed_install_does_not_stage_first_boot_trim(self):
        self.assertEqual(self.main(PhaseError("boom")), (1, ["run"]))


if __name__ == "__main__":
    unittest.main()
