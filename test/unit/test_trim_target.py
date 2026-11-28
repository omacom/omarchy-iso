"""Unit tests for the first-boot trim: phases_impl.stage_first_boot_trim enables
Arch's built-in fstrim.timer with an overdue stamp file, never fails a completed
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
        timer = self.target / "usr/lib/systemd/system/fstrim.timer"
        timer.parent.mkdir(parents=True)
        timer.write_text("[Timer]\nOnCalendar=weekly\nPersistent=true\n")

    def tearDown(self):
        self.tmp.cleanup()

    def stage(self):
        lines = []
        with mock.patch.object(phases_impl, "info", lines.append):
            phases_impl.stage_first_boot_trim(types.SimpleNamespace(target=self.target))
        return lines

    def test_enables_fstrim_timer_and_backdates_stamp(self):
        lines = self.stage()

        link = self.target / "etc/systemd/system/timers.target.wants/fstrim.timer"
        stamp = self.target / "var/lib/systemd/timers/stamp-fstrim.timer"

        self.assertTrue(link.is_symlink())
        self.assertEqual(str(link.readlink()), "/usr/lib/systemd/system/fstrim.timer")
        self.assertTrue(stamp.is_file())
        self.assertFalse(stamp.is_symlink())
        self.assertEqual(stat.S_IMODE(stamp.stat().st_mode), 0o644)
        self.assertEqual(int(stamp.stat().st_mtime), phases_impl.FSTRIM_OVERDUE_STAMP_EPOCH)
        self.assertIn("enabled fstrim.timer", lines[-1])

    def test_restaging_replaces_existing_symlinks_without_writing_through_stamp(self):
        wants = self.target / "etc/systemd/system/timers.target.wants"
        wants.mkdir(parents=True)
        (wants / "fstrim.timer").symlink_to("/stale/target")

        timers_dir = self.target / "var/lib/systemd/timers"
        timers_dir.mkdir(parents=True)
        sentinel = self.target / "sentinel"
        sentinel.write_text("untouched")
        (timers_dir / "stamp-fstrim.timer").symlink_to(sentinel)

        self.stage()

        self.assertEqual(
            str((wants / "fstrim.timer").readlink()),
            "/usr/lib/systemd/system/fstrim.timer",
        )
        self.assertFalse((timers_dir / "stamp-fstrim.timer").is_symlink())
        self.assertEqual(sentinel.read_text(), "untouched")

    def test_missing_fstrim_timer_logs_warning_and_skips(self):
        (self.target / "usr/lib/systemd/system/fstrim.timer").unlink()
        lines = self.stage()
        self.assertFalse((self.target / "etc/systemd/system/timers.target.wants/fstrim.timer").exists())
        self.assertFalse((self.target / "var/lib/systemd/timers/stamp-fstrim.timer").exists())
        self.assertIn("WARNING: fstrim.timer not found", lines[-1])

    def test_os_error_is_logged_and_does_not_raise(self):
        lines = []
        with mock.patch.object(phases_impl, "info", lines.append), \
                mock.patch.object(Path, "symlink_to", side_effect=OSError("read-only filesystem")):
            phases_impl.stage_first_boot_trim(types.SimpleNamespace(target=self.target))
        self.assertIn("WARNING: could not enable fstrim.timer", lines[-1])
        self.assertIn("read-only filesystem", lines[-1])


class MainStagesTrimAfterRunTest(unittest.TestCase):
    """run() writes finished_at before returning. Staging the first-boot trim
    must come after run(), and only on success."""

    def main(self, run_error=None):
        events = []

        def fake_run(ctx, phases):
            events.append("run")
            if run_error:
                raise run_error

        ctx = types.SimpleNamespace(username="omarchy", target=Path("/mnt"))
        helpers = dict.fromkeys(
            ["boost_cpu_governor", "cleanup_bind_mounts", "cleanup_protected_state",
             "cleanup_target_hook_masks", "restore_cpu_governors", "stop_efi_boot_register",
             "stop_library_warmup", "stop_luks_keyslot_enroll", "stop_target_keyring_init"], mock.DEFAULT)
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
