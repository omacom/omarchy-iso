"""Unit tests for orchestrator free-space planning, execution, LUKS deferral,
udev settling, and scoped partition rollback."""

from __future__ import annotations

import errno
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import free_space as fs  # noqa: E402
from orchestrator import luks_calibration as luks  # noqa: E402

MIB = 1024 * 1024
GIB = 1024 * MIB


def make_ctx(tmp: Path, plan: dict | None, *, password: str = "s3cret",
             esp_mount: str = "/boot", is_protected: bool = True):
    omarchy_install = {
        "mode": "protected" if is_protected else "full_disk",
        "target_mount": str(tmp / "mnt"),
        "boot": {"esp_mount": esp_mount, "enable_fallback": True},
        "storage": {
            "esp_device": None,
            "root_device": None,
            "root_mapper": None,
            "luks_uuid": None,
            "kernel": "linux-omarchy",
        },
    }
    if plan is not None:
        omarchy_install["free_space_plan"] = plan
    creds = {"users": [{"username": "omarchy"}]}
    if password:
        creds["encryption_password"] = password
    target = tmp / "mnt"
    target.mkdir(parents=True, exist_ok=True)
    return types.SimpleNamespace(
        target=target,
        state_dir=tmp / "state",
        is_protected=is_protected,
        omarchy_install=omarchy_install,
        user_configuration={"disk_config": {"config_type": "pre_mounted_config", "mountpoint": str(target)}},
        user_credentials=creds,
        state={},
    )


SFDISK_DUAL_BOOT = """label: gpt
label-id: 11111111-2222-3333-4444-555555555555
device: /dev/nvme0n1
unit: sectors
first-lba: 34
last-lba: 2000409230
sector-size: 512

/dev/nvme0n1p1 : start=        2048, size=     4194304, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EXIST_ESP"
/dev/nvme0n1p2 : start=     4196352, size=   419430400, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name="EXISTING_DATA"
"""


class FreeSpaceValidationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.fake_disk = self.tmp / "nvme0n1"
        self.fake_disk.write_bytes(b"")
        self.disk_size = 1000 * GIB
        self.plan = {
            "disk": str(self.fake_disk),
            "needs_mklabel": False,
            "efi_start_b": 210 * GIB,
            "efi_end_b": 212 * GIB,
            "root_start_b": 212 * GIB,
            "root_end_b": 999 * GIB,
            "encrypt": True,
        }
        self.sfdisk_out = SFDISK_DUAL_BOOT.replace("/dev/nvme0n1", str(self.fake_disk))
        self.enterContext(mock.patch.object(fs, "_is_block_device", return_value=True))
        self.enterContext(mock.patch.object(fs, "_block_device_size", return_value=self.disk_size))
        self.enterContext(mock.patch.object(fs, "_boot_medium_disk", return_value=None))
        self.enterContext(mock.patch.object(
            fs.subprocess, "run",
            return_value=subprocess.CompletedProcess(["sfdisk"], 0, stdout=self.sfdisk_out, stderr=""),
        ))

    def test_valid_dual_boot_plan_passes(self):
        ctx = make_ctx(self.tmp, self.plan)
        resolved = fs.validate_free_space_plan(ctx)
        self.assertEqual(resolved, self.fake_disk.resolve())

    def test_rejects_overlapping_byte_range(self):
        # p2 ends at (4196352 + 419430400) * 512 = 216,901,505,024 (~202.005 GiB)
        bad = dict(self.plan, efi_start_b=200 * GIB, efi_end_b=203 * GIB)
        ctx = make_ctx(self.tmp, bad)
        with self.assertRaisesRegex(RuntimeError, "overlaps existing partition 2"):
            fs.validate_free_space_plan(ctx)

    def test_allows_exact_adjacent_boundary_after_existing_partition(self):
        p2_end = (4196352 + 419430400) * 512
        adj = dict(self.plan, efi_start_b=p2_end, efi_end_b=p2_end + 2 * GIB, root_start_b=p2_end + 2 * GIB)
        ctx = make_ctx(self.tmp, adj)
        fs.validate_free_space_plan(ctx)

    def test_rejects_one_byte_overlap_at_boundary(self):
        p2_end = (4196352 + 419430400) * 512
        bad = dict(self.plan, efi_start_b=p2_end - 1, efi_end_b=p2_end + 2 * GIB, root_start_b=p2_end + 2 * GIB)
        ctx = make_ctx(self.tmp, bad)
        with self.assertRaisesRegex(RuntimeError, "overlaps existing partition 2"):
            fs.validate_free_space_plan(ctx)

    def test_rejects_boot_medium_disk(self):
        ctx = make_ctx(self.tmp, self.plan)
        with mock.patch.object(fs, "_boot_medium_disk", return_value=self.fake_disk.resolve()):
            with self.assertRaisesRegex(RuntimeError, "boot medium disk"):
                fs.validate_free_space_plan(ctx)

    def test_rejects_non_block_device_and_missing_disk(self):
        ctx = make_ctx(self.tmp, self.plan)
        with mock.patch.object(fs, "_is_block_device", return_value=False):
            with self.assertRaisesRegex(RuntimeError, "not a block device"):
                fs.validate_free_space_plan(ctx)
        missing = dict(self.plan, disk=str(self.tmp / "nope"))
        with self.assertRaisesRegex(RuntimeError, "does not exist"):
            fs.validate_free_space_plan(make_ctx(self.tmp, missing))

    def test_rejects_invalid_ranges_and_non_int_types(self):
        for overrides in (
            {"efi_start_b": 0},
            {"efi_end_b": 209 * GIB},
            {"root_start_b": 211 * GIB},
            {"root_end_b": self.disk_size + 1},
            {"efi_start_b": True},
            {"encrypt": "yes"},
            {"needs_mklabel": 0},
        ):
            bad = dict(self.plan, **overrides)
            with self.subTest(overrides=overrides), self.assertRaises(RuntimeError):
                fs.validate_free_space_plan(make_ctx(self.tmp, bad))

    def test_rejects_mounted_target(self):
        ctx = make_ctx(self.tmp, self.plan)
        with mock.patch.object(fs.os.path, "ismount", return_value=True):
            with self.assertRaisesRegex(RuntimeError, "already mounted"):
                fs.validate_free_space_plan(ctx)

    def test_rejects_mbr_with_more_than_two_partitions(self):
        mbr = (
            f"label: dos\nsector-size: 512\n"
            f"{self.fake_disk}1 : start=2048, size=204800\n"
            f"{self.fake_disk}2 : start=206848, size=204800\n"
            f"{self.fake_disk}3 : start=411648, size=204800\n"
        )
        with mock.patch.object(
            fs.subprocess, "run",
            return_value=subprocess.CompletedProcess(["sfdisk"], 0, stdout=mbr, stderr=""),
        ):
            with self.assertRaisesRegex(RuntimeError, "MBR disk .* already has 3 partitions"):
                fs.validate_free_space_plan(make_ctx(self.tmp, self.plan))

    def test_rejects_needs_mklabel_when_partitions_exist(self):
        bad = dict(self.plan, needs_mklabel=True)
        with self.assertRaisesRegex(RuntimeError, "mklabel gpt .* already exist"):
            fs.validate_free_space_plan(make_ctx(self.tmp, bad))

    def test_allows_needs_mklabel_on_unpartitioned_disk(self):
        blank = dict(self.plan, needs_mklabel=True)
        with mock.patch.object(
            fs.subprocess, "run",
            return_value=subprocess.CompletedProcess(["sfdisk"], 1, stdout="", stderr="no partition table"),
        ):
            fs.validate_free_space_plan(make_ctx(self.tmp, blank))

    def test_rejects_encrypt_without_password(self):
        ctx = make_ctx(self.tmp, self.plan, password="")
        with self.assertRaisesRegex(RuntimeError, "encryption_password is missing"):
            fs.validate_free_space_plan(ctx)


class PartitionParsingAndCreationTests(unittest.TestCase):
    def test_partition_path_naming(self):
        self.assertEqual(fs.partition_path("/dev/nvme0n1", 3), "/dev/nvme0n1p3")
        self.assertEqual(fs.partition_path("/dev/mmcblk0", 4), "/dev/mmcblk0p4")
        self.assertEqual(fs.partition_path("/dev/loop0", 1), "/dev/loop0p1")
        self.assertEqual(fs.partition_path("/dev/vda", 2), "/dev/vda2")
        self.assertEqual(fs.partition_path("/dev/sda", 3), "/dev/sda3")

    def test_sfdisk_parser_handles_4kn_and_holey_gpt(self):
        dump = (
            "label: gpt\n"
            "sector-size: 4096\n"
            "/dev/nvme0n1p1 : start= 256, size= 524288, name=\"ESP\"\n"
            "/dev/nvme0n1p4 : start= 2000000, size= 1000000, name=\"DATA\"\n"
        )
        label, rows = fs._parse_sfdisk_dump("/dev/nvme0n1", dump)
        self.assertEqual(label, "gpt")
        self.assertEqual(rows, [
            (1, 256 * 4096, 524288 * 4096),
            (4, 2000000 * 4096, 1000000 * 4096),
        ])

    def test_real_parted_and_sfdisk_holey_gpt_slot_discovery_and_rollback(self):
        if shutil.which("parted") is None or shutil.which("sfdisk") is None:
            self.skipTest("parted/sfdisk unavailable")
        with tempfile.TemporaryDirectory() as tmpdir:
            img = Path(tmpdir) / "disk.img"
            with open(img, "wb") as stream:
                stream.truncate(64 * MIB)
            subprocess.run(["parted", "--script", str(img), "mklabel", "gpt"], check=True)
            subprocess.run(["parted", "--script", str(img), "mkpart", "P1", "fat32", "1MiB", "5MiB"], check=True)
            subprocess.run(["parted", "--script", str(img), "mkpart", "HOLE", "ext4", "5MiB", "25MiB"], check=True)
            subprocess.run(["parted", "--script", str(img), "mkpart", "P3", "ext4", "25MiB", "30MiB"], check=True)
            subprocess.run(["parted", "--script", str(img), "rm", "2"], check=True)

            created: list[int] = []
            # Creating inside the hole assigns slot 2 (not 4!), with exact end-1 alignment.
            n1 = fs._create_partition(str(img), 5 * MIB, 10 * MIB, "fat32", "OMARCHY_EFI", created)
            n2 = fs._create_partition(str(img), 10 * MIB, 25 * MIB, "btrfs", "OMARCHY_ROOT", created)
            self.assertEqual((n1, n2), (2, 4))
            self.assertEqual(created, [2, 4])

            ctx = types.SimpleNamespace(state={"free_space_created_parts": {"disk": str(img), "parts": created}})
            with mock.patch.object(fs, "settle_disk_devices"):
                fs.rollback_free_space_parts(ctx)
            self.assertEqual(created, [])
            _, remaining = fs._read_partition_table(str(img))
            self.assertEqual([r[0] for r in remaining], [1, 3])

    def test_create_partition_uses_primary_on_mbr(self):
        calls = []
        tables = iter([
            ("dos", [(1, MIB, 10 * MIB)]),
            ("dos", [(1, MIB, 10 * MIB), (2, 11 * MIB, 2 * GIB)]),
        ])
        def fake_run(cmd, **kwargs):
            calls.append(list(cmd))
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
        created: list[int] = []
        with mock.patch.object(fs, "_read_partition_table", side_effect=lambda _: next(tables)),                 mock.patch.object(fs.subprocess, "run", side_effect=fake_run):
            num = fs._create_partition("/dev/sda", 11 * MIB, 11 * MIB + 2 * GIB, "fat32", "OMARCHY_EFI", created)
        self.assertEqual(num, 2)
        self.assertEqual(created, [2])
        self.assertEqual(calls[0][:5], ["parted", "--script", "/dev/sda", "mkpart", "primary"])
        self.assertEqual(calls[0][7], f"{11 * MIB + 2 * GIB - 1}B")


class SettleDiskDevicesTests(unittest.TestCase):
    def test_fast_settle_exits_without_poking(self):
        fake_proc = mock.MagicMock()
        fake_proc.poll.return_value = 0
        with mock.patch.object(fs.subprocess, "Popen", return_value=fake_proc),                 mock.patch.object(fs.subprocess, "run") as run_mock:
            fs.settle_disk_devices("/dev/null")
        run_mock.assert_not_called()

    def test_stranded_settle_pokes_when_unlocked_and_skips_when_locked(self):
        with tempfile.NamedTemporaryFile() as backing:
            # First backoff window: locked (BlockingIOError -> no poke).
            # Second backoff window: unlocked -> emits trigger -> proc finishes.
            poll_state = {"calls": 0, "done": False}
            def fake_poll():
                poll_state["calls"] += 1
                return 0 if poll_state["done"] else None

            fake_proc = mock.MagicMock()
            fake_proc.poll.side_effect = fake_poll
            triggers = []
            def fake_run(cmd, **kwargs):
                triggers.append(list(cmd))
                poll_state["done"] = True
                return subprocess.CompletedProcess(cmd, 0)

            flock_calls = {"n": 0}
            def fake_flock(fd, op):
                if op & fs.fcntl.LOCK_NB:
                    flock_calls["n"] += 1
                    if flock_calls["n"] == 1:
                        raise BlockingIOError(errno.EAGAIN, "locked")

            with mock.patch.object(fs, "SETTLE_BACKOFF_DELAYS", (0.01, 0.01, 0.01)),                     mock.patch.object(fs, "SETTLE_POLL_TICK", 0.005),                     mock.patch.object(fs.subprocess, "Popen", return_value=fake_proc),                     mock.patch.object(fs.subprocess, "run", side_effect=fake_run),                     mock.patch.object(fs.fcntl, "flock", side_effect=fake_flock):
                fs.settle_disk_devices(backing.name)
            self.assertEqual(len(triggers), 1)
            self.assertIn("--action=change", triggers[0])
            self.assertIn("--subsystem-match=block", triggers[0])
            self.assertTrue(any(arg.startswith("--sysname-match=") for arg in triggers[0]))


class InProcessLuksTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.state = self.tmp / "result.json"
        self.enterContext(mock.patch.object(luks, "VOLUME_KEY_DIR", self.tmp))
        self.enterContext(mock.patch.object(luks, "STATE", self.state))
        self.enterContext(mock.patch.object(luks, "memory_total", return_value=8 * 1024 * 1024))
        self.enterContext(mock.patch.object(luks, "memory_available", return_value=4 * 1024 * 1024))
        self.enterContext(mock.patch.object(luks, "memory_free", return_value=4 * 1024 * 1024))
        self.enterContext(mock.patch.object(luks.os, "cpu_count", return_value=4))

    def test_format_and_open_luks_deferred_returns_entry_and_keeps_vk_until_join(self):
        image = self.tmp / "part4"
        with open(image, "wb") as stream:
            stream.truncate(64 * MIB)
        ran = []
        def fake_run(cmd, **kwargs):
            ran.append((list(cmd), kwargs))
            return subprocess.CompletedProcess(cmd, 0)
        with mock.patch.object(luks, "cached_options", return_value=[
                "--pbkdf-force-iterations", "11", "--pbkdf-memory", "1048576", "--pbkdf-parallel", "4"]),                 mock.patch.object(luks, "stop_calibration") as stop,                 mock.patch.object(luks.subprocess, "run", side_effect=fake_run):
            entry = luks.format_and_open_luks(str(image), "omarchy_root", b"secret-pw")
        stop.assert_called_once_with(wait=0)
        self.assertIsNotNone(entry)
        self.assertEqual(len(ran), 2)
        self.assertIn("--sector-size", ran[0][0])
        self.assertIn("4096", ran[0][0])
        self.assertEqual(ran[0][0][ran[0][0].index("--key-slot") + 1], "1")
        self.assertIn("--persistent", ran[1][0])
        self.assertIn("--allow-discards", ran[1][0])
        self.assertIn("--perf-no_read_workqueue", ran[1][0])
        self.assertNotIn("secret-pw", " ".join(ran[0][0] + ran[1][0]))
        self.assertTrue(entry.volume_key.is_file())
        self.assertTrue(entry.temp_keyfile.is_file())
        entry.abort()
        self.assertFalse(entry.volume_key.exists())
        self.assertFalse(entry.temp_keyfile.exists())

    def test_format_and_open_luks_sync_fallback_pipes_stdin_and_removes_vk(self):
        image = self.tmp / "part4"
        with open(image, "wb") as stream:
            stream.truncate(64 * MIB)
        ran = []
        def fake_run(cmd, **kwargs):
            ran.append((list(cmd), kwargs))
            return subprocess.CompletedProcess(cmd, 0)
        with mock.patch.object(luks, "can_defer_keyslot", return_value=False),                 mock.patch.object(luks, "stop_calibration") as stop,                 mock.patch.object(luks, "pretouch_for_format"),                 mock.patch.object(luks.subprocess, "run", side_effect=fake_run):
            entry = luks.format_and_open_luks(str(image), "omarchy_root", b"sync-pw")
        stop.assert_called_once_with()
        self.assertIsNone(entry)
        self.assertEqual(ran[0][1].get("input"), b"sync-pw")
        self.assertNotIn("sync-pw", " ".join(ran[0][0]))
        self.assertEqual([p for p in self.tmp.iterdir() if p.name.startswith("omarchy-volume-key-")], [])

    def test_format_and_open_luks_cleans_all_keys_on_open_failure(self):
        image = self.tmp / "part4"
        with open(image, "wb") as stream:
            stream.truncate(64 * MIB)
        def fail_on_open(cmd, **kwargs):
            if "open" in cmd:
                raise subprocess.CalledProcessError(1, cmd)
            return subprocess.CompletedProcess(cmd, 0)
        with mock.patch.object(luks, "cached_options", return_value=[
                "--pbkdf-force-iterations", "11", "--pbkdf-memory", "1048576", "--pbkdf-parallel", "4"]),                 mock.patch.object(luks, "stop_calibration"),                 mock.patch.object(luks.subprocess, "run", side_effect=fail_on_open):
            with self.assertRaises(subprocess.CalledProcessError):
                luks.format_and_open_luks(str(image), "omarchy_root", b"secret-pw")
        self.assertEqual([p for p in self.tmp.iterdir() if p.name.startswith("omarchy-volume-key-")], [])

    def test_real_cryptsetup_in_process_deferred_enroll_and_kill_slot1(self):
        if shutil.which("cryptsetup") is None:
            self.skipTest("cryptsetup unavailable")
        image = self.tmp / "luks.img"
        with open(image, "wb") as stream:
            stream.truncate(32 * MIB)
        real_run = subprocess.run
        def run_without_dm_open(cmd, **kwargs):
            if len(cmd) >= 2 and cmd[0] == "cryptsetup" and cmd[1] == "open":
                return subprocess.CompletedProcess(cmd, 0)
            return real_run(cmd, **kwargs)
        with mock.patch.object(luks, "cached_options", return_value=[
                "--pbkdf-force-iterations", "4", "--pbkdf-memory", "65536", "--pbkdf-parallel", "1"]),                 mock.patch.object(luks, "stop_calibration"),                 mock.patch.object(luks.subprocess, "run", side_effect=run_without_dm_open):
            entry = luks.format_and_open_luks(str(image), "omarchy_root", b"real-pass")
        self.assertIsNotNone(entry)
        entry.start()
        entry.join()
        self.assertFalse(entry.volume_key.exists())
        self.assertFalse(entry.temp_keyfile.exists())
        dump = subprocess.run(["cryptsetup", "luksDump", str(image)],
                              check=True, capture_output=True, text=True).stdout
        self.assertIn("0: luks2", dump)
        self.assertIn("PBKDF:      argon2id", dump)
        self.assertIn("sector: 4096 [bytes]", dump)
        self.assertNotIn("1: luks2", dump)
        verify = subprocess.run(
            ["cryptsetup", "open", "--test-passphrase", "--key-slot", "0", str(image)],
            input=b"real-pass", capture_output=True,
        )
        self.assertEqual(verify.returncode, 0, verify.stderr.decode(errors="replace"))


class PhasesIntegrationTests(unittest.TestCase):
    def _load_phases(self):
        import importlib
        if "orchestrator.phases_impl" in sys.modules:
            return sys.modules["orchestrator.phases_impl"]
        fake_adapter = types.ModuleType("orchestrator.archinstall_adapter")
        sys.modules.setdefault("orchestrator.archinstall_adapter", fake_adapter)
        return importlib.import_module("orchestrator.phases_impl")

    def test_prepare_install_target_verifies_medium_and_validates_plan_before_touching_disk(self):
        phases = self._load_phases()
        with tempfile.TemporaryDirectory() as tmpdir:
            ctx = make_ctx(Path(tmpdir), {"disk": "/dev/nvme0n1", "needs_mklabel": False,
                                          "efi_start_b": 1, "efi_end_b": 2,
                                          "root_start_b": 2, "root_end_b": 3, "encrypt": True})
            order = []
            with mock.patch.object(phases, "verify_install_medium", side_effect=lambda _: order.append("medium")),                     mock.patch.object(phases, "validate_free_space_plan", side_effect=lambda _: order.append("plan")),                     mock.patch.object(phases, "verify_protected_mounts", side_effect=AssertionError("must not run")):
                phases.prepare_install_target(ctx)
            self.assertEqual(order, ["medium", "plan"])

    def test_prepare_install_target_preserves_caller_pre_mounted_config(self):
        phases = self._load_phases()
        with tempfile.TemporaryDirectory() as tmpdir:
            ctx = make_ctx(Path(tmpdir), None)
            order = []
            with mock.patch.object(phases, "verify_protected_mounts", side_effect=lambda _: order.append("mounts")),                     mock.patch.object(phases, "_root_image_target_mounts", return_value=([], "/dev/mapper/omarchy_root")),                     mock.patch.object(phases, "verify_pre_mounted_root_empty", side_effect=lambda *_: order.append("empty")),                     mock.patch.object(phases, "verify_install_medium", side_effect=lambda _: order.append("medium")):
                phases.prepare_install_target(ctx)
            self.assertEqual(order, ["mounts", "empty", "medium"])

    def test_cleanup_protected_state_rolls_back_only_created_parts(self):
        phases = self._load_phases()
        with tempfile.TemporaryDirectory() as tmpdir:
            # Orchestrator-driven free-space failure -> rolls back created parts.
            ctx = make_ctx(Path(tmpdir), {"disk": "/dev/nvme0n1"})
            ctx.state["free_space_created_parts"] = {"disk": "/dev/nvme0n1", "parts": [3, 4]}
            with mock.patch.object(phases.subprocess, "run",
                                   return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="")),                     mock.patch.object(fs.subprocess, "run",
                                      return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="")) as fs_run,                     mock.patch.object(fs, "settle_disk_devices") as settle:
                phases.cleanup_protected_state(ctx)
            rm_calls = [c.args[0] for c in fs_run.call_args_list if c.args[0][:3] == ["parted", "--script", "/dev/nvme0n1"]]
            self.assertEqual(rm_calls, [
                ["parted", "--script", "/dev/nvme0n1", "rm", "4"],
                ["parted", "--script", "/dev/nvme0n1", "rm", "3"],
            ])
            settle.assert_called_once_with("/dev/nvme0n1")
            self.assertEqual(ctx.state["free_space_created_parts"]["parts"], [])

            # Caller-supplied pre_mounted_config -> NEVER calls parted rm.
            caller_ctx = make_ctx(Path(tmpdir), None)
            with mock.patch.object(phases.subprocess, "run",
                                   return_value=subprocess.CompletedProcess([], 0, stdout="", stderr="")),                     mock.patch.object(fs.subprocess, "run") as fs_run2:
                phases.cleanup_protected_state(caller_ctx)
            parted_calls = [c for c in fs_run2.call_args_list if c.args and c.args[0][0] == "parted"]
            self.assertEqual(parted_calls, [])

    def test_execute_free_space_plan_runs_expected_commands_and_populates_storage(self):
        phases = self._load_phases()
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            fake_disk = tmp / "nvme0n1"
            fake_disk.write_bytes(b"")
            plan = {
                "disk": str(fake_disk),
                "needs_mklabel": False,
                "efi_start_b": 210 * GIB,
                "efi_end_b": 212 * GIB,
                "root_start_b": 212 * GIB,
                "root_end_b": 999 * GIB,
                "encrypt": True,
            }
            ctx = make_ctx(tmp, plan, esp_mount="/boot")
            cmds = []
            def fake_run(cmd, **kwargs):
                cmds.append(list(cmd))
                return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

            fake_deferred = mock.MagicMock()
            created_seq = iter([3, 4])
            def fake_create(disk, start_b, end_b, fstype, name, created_parts):
                n = next(created_seq)
                created_parts.append(n)
                return n

            with mock.patch.object(fs, "validate_free_space_plan", return_value=fake_disk.resolve()),                     mock.patch.object(fs, "_create_partition", side_effect=fake_create),                     mock.patch.object(fs, "_is_block_device", return_value=True),                     mock.patch.object(fs, "settle_disk_devices"),                     mock.patch.object(fs, "wait_for_device"),                     mock.patch.object(fs, "format_and_open_luks", return_value=fake_deferred),                     mock.patch.object(fs, "capture", return_value=subprocess.CompletedProcess(
                        [], 0, stdout="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n", stderr="")),                     mock.patch.object(fs.subprocess, "run", side_effect=fake_run),                     mock.patch.object(phases, "verify_protected_mounts") as v_mounts,                     mock.patch.object(phases, "verify_pre_mounted_root_empty") as v_empty:
                fs.execute_free_space_plan(ctx)

            efi_dev = f"{fake_disk.resolve()}p3"
            root_dev = f"{fake_disk.resolve()}p4"
            self.assertEqual(ctx.state["free_space_created_parts"], {"disk": str(fake_disk.resolve()), "parts": [3, 4]})
            self.assertEqual(ctx.state["luks_deferred_keyslots"], [fake_deferred])
            self.assertEqual(ctx.omarchy_install["storage"]["esp_device"], efi_dev)
            self.assertEqual(ctx.omarchy_install["storage"]["root_device"], root_dev)
            self.assertEqual(ctx.omarchy_install["storage"]["root_mapper"], "/dev/mapper/omarchy_root")
            self.assertEqual(ctx.omarchy_install["storage"]["luks_uuid"], "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            self.assertIn(["mkfs.btrfs", "-K", "-f", "-L", "OMARCHY", "/dev/mapper/omarchy_root"], cmds)
            self.assertIn(["mount", "-t", "vfat", efi_dev, str(ctx.target / "boot")], cmds)
            self.assertIn(["wipefs", "-af", efi_dev], cmds)
            self.assertIn(["wipefs", "-af", root_dev], cmds)
            v_mounts.assert_called_once_with(ctx)
            v_empty.assert_called_once_with(ctx, "/dev/mapper/omarchy_root")


if __name__ == "__main__":
    unittest.main()
