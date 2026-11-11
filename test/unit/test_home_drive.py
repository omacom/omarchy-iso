"""Unit tests for the orchestrator's home drive handling.

The configurator chooses where home lives; the orchestrator trusts nothing
about that choice. Before it writes anything it scans the drive again through
the same shared helper the configurator used (omarchy's home-drive.sh) and
refuses a choice that no longer matches: a different filesystem, an owner that
now collides with the image's accounts, or a disk that is not erasable. The
helper is replaced here by recorded scan output.
"""

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "configs/airootfs/usr/share/omarchy-iso"))

from orchestrator import home_drive  # noqa: E402

ADOPT = {"mode": "adopt", "device": "/dev/vdb1", "uuid": "u1", "fstype": "xfs", "subvol": "",
         "luks_uuid": "", "uid": 1000, "gid": 1000, "dir": ""}
# A home found as the folder home/kim inside another system's root
# filesystem (an Ubuntu or Debian install's ext4 root partition).
IN_SYSTEM = dict(ADOPT, device="/dev/vdb2", uuid="u2", fstype="ext4", dir="home")


def row(*fields):
    return "\t".join(str(f) for f in fields)


ADOPTABLE = row("adoptable", "home", "/dev/vdb1", "xfs", "u1", "", "", 1000, 1000, 4096, "/dev/vdb", 0, "", "")
ERASABLE = row("erasable", "disk", "/dev/vdc", "", "", "", "", "", "", "", "/dev/vdc", 0, "", "")
# The helper's fifteenth field, dir: where the user's folder sits inside the
# filesystem (or subvolume) when it is another system's root.
IN_SYSTEM_ROW = row("adoptable", "home", "/dev/vdb2", "ext4", "u2", "", "", 1000, 1000, 4096, "/dev/vdb", 0, "", "",
                    "home")


class ParseHomeTest(unittest.TestCase):
    def test_no_home_means_home_on_the_install_disk(self):
        self.assertIsNone(home_drive.parse_home(None, defer_provisioning=False))

    def test_rejects_home_with_defer_provisioning(self):
        with self.assertRaisesRegex(RuntimeError, "first boot"):
            home_drive.parse_home(ADOPT, defer_provisioning=True)

    def test_rejects_unknown_mode(self):
        with self.assertRaisesRegex(RuntimeError, "mode"):
            home_drive.parse_home({"mode": "move"}, defer_provisioning=False)

    def test_rejects_adopt_without_ids(self):
        broken = dict(ADOPT)
        del broken["uid"]
        with self.assertRaisesRegex(RuntimeError, "uid"):
            home_drive.parse_home(broken, defer_provisioning=False)

    def test_null_subvol_and_luks_uuid_mean_none(self):
        # A hand-written autoinstall config spells "none" as null.
        home = dict(ADOPT, subvol=None, luks_uuid=None)
        self.assertEqual(home_drive.parse_home(home, defer_provisioning=False), ADOPT)

    def test_a_home_without_dir_is_the_filesystem_itself(self):
        # Configs written before homes inside another system existed.
        home = dict(ADOPT)
        del home["dir"]
        self.assertEqual(home_drive.parse_home(home, defer_provisioning=False), ADOPT)
        self.assertEqual(home_drive.parse_home(dict(ADOPT, dir=None), defer_provisioning=False), ADOPT)

    def test_accepts_a_home_inside_another_system(self):
        self.assertEqual(home_drive.parse_home(dict(IN_SYSTEM), defer_provisioning=False), IN_SYSTEM)

    def test_rejects_a_dir_that_is_not_text(self):
        with self.assertRaisesRegex(RuntimeError, "dir"):
            home_drive.parse_home(dict(ADOPT, dir=["home"]), defer_provisioning=False)

    def test_accepts_adopt_and_fresh(self):
        self.assertEqual(home_drive.parse_home(ADOPT, defer_provisioning=False), ADOPT)
        fresh = {"mode": "fresh", "disk": "/dev/vdc"}
        self.assertEqual(home_drive.parse_home(fresh, defer_provisioning=False), fresh)


class ValidateHomeTest(unittest.TestCase):
    def validate(self, home, scan):
        with mock.patch.object(home_drive, "scan", return_value=scan) as scanned:
            home_drive.validate_home(home, Path("/mnt"), "kim", "pw", None)
        return scanned

    def test_valid_adopt_passes(self):
        scanned = self.validate(ADOPT, ADOPTABLE + "\n" + ERASABLE)
        args = scanned.call_args
        self.assertEqual(args.args[0], "kim")
        self.assertEqual(args.args[1], "pw")

    def test_scan_checks_against_the_targets_accounts(self):
        scanned = self.validate(ADOPT, ADOPTABLE)
        self.assertEqual(scanned.call_args.kwargs["target"], Path("/mnt"))

    def test_adopt_requires_matching_scan_row(self):
        other = ADOPTABLE.replace("\tu1\t", "\tu9\t")
        with self.assertRaisesRegex(RuntimeError, "changed since it was chosen"):
            self.validate(ADOPT, other)

    def test_adopt_refused_now_is_rejected(self):
        refused = ADOPTABLE.replace("adoptable", "refused", 1) + "uid-taken"
        with self.assertRaisesRegex(RuntimeError, "uid-taken"):
            self.validate(ADOPT, refused)

    def test_adopt_with_another_filesystem_type_is_rejected(self):
        # The fstab line is written with this type: a wrong one would not mount.
        with self.assertRaisesRegex(RuntimeError, "changed since it was chosen"):
            self.validate(dict(ADOPT, fstype="ext4"), ADOPTABLE)

    def test_adopt_with_other_ids_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "changed since it was chosen"):
            self.validate(dict(ADOPT, uid=1001), ADOPTABLE)

    def test_a_home_inside_another_system_passes(self):
        self.validate(IN_SYSTEM, IN_SYSTEM_ROW + "\n" + ADOPTABLE)

    def test_a_home_inside_another_system_is_not_the_filesystem_itself(self):
        # Same drive and ids, another folder: mounting the filesystem itself
        # as /home would put the whole other system there.
        with self.assertRaisesRegex(RuntimeError, "changed since it was chosen"):
            self.validate(dict(IN_SYSTEM, dir=""), IN_SYSTEM_ROW)
        with self.assertRaisesRegex(RuntimeError, "changed since it was chosen"):
            self.validate(dict(ADOPT, dir="home"), ADOPTABLE)

    def test_a_home_inside_a_btrfs_root_subvolume_matches_subvol_and_dir(self):
        at = row("adoptable", "home", "/dev/vdb2", "btrfs", "u2", "", "@", 1000, 1000, 4096, "/dev/vdb", 0, "", "",
                 "home")
        self.validate(dict(IN_SYSTEM, fstype="btrfs", subvol="@"), at)
        with self.assertRaisesRegex(RuntimeError, "changed since it was chosen"):
            self.validate(dict(IN_SYSTEM, fstype="btrfs", subvol="@home"), at)

    def test_fresh_requires_an_erasable_disk(self):
        self.validate({"mode": "fresh", "disk": "/dev/vdc"}, ERASABLE)
        # The install disk, the boot medium and removable disks never scan as
        # erasable, so a fresh home on any of them is refused here.
        with self.assertRaisesRegex(RuntimeError, "cannot be erased"):
            self.validate({"mode": "fresh", "disk": "/dev/vda"}, ERASABLE)

    def test_a_drive_no_passphrase_opens_says_so(self):
        locked = row("locked", "home", "/dev/vdb1", "crypto_LUKS", "", "l1", "", "", "", "", "/dev/vdb", 0, "",
                     "wrong-passphrase")
        with self.assertRaisesRegex(RuntimeError, "no passphrase given opens"):
            self.validate(dict(ADOPT, luks_uuid="l1"), locked)

    def test_the_home_passphrase_and_the_password_are_both_tried(self):
        with mock.patch.object(home_drive, "scan", return_value=ADOPTABLE) as scanned:
            home_drive.validate_home(dict(ADOPT, luks_uuid=""), Path("/mnt"), "kim", "pw", "home-pw")
        self.assertEqual(scanned.call_args.args[1], "home-pw\npw")


class CheckBeforeEraseTest(unittest.TestCase):
    """The checks that need no written image run before anything is erased:
    a home refused only after the install disk was wiped leaves the machine
    with no system at all."""

    def test_checks_against_the_static_rules_leaving_out_the_install_disks(self):
        ctx = home_ctx(dict(ADOPT), {"home_encryption_password": "hp"})
        ctx.user_configuration = {"disk_config": {"device_modifications": [{"device": "/dev/vda", "wipe": True}]}}
        with mock.patch.object(home_drive, "validate_home") as validated:
            home_drive.check_before_erase(ctx)
        validated.assert_called_once_with(ADOPT, None, "kim", "", "hp", excluded=["/dev/vda"])

    def test_a_home_inside_another_system_is_checked_by_its_folder(self):
        ctx = home_ctx(dict(IN_SYSTEM, dir=""))
        ctx.user_configuration = {}
        with mock.patch.object(home_drive, "scan", return_value=IN_SYSTEM_ROW):
            with self.assertRaisesRegex(RuntimeError, "changed since it was chosen"):
                home_drive.check_before_erase(ctx)
            home_drive.check_before_erase(home_ctx(dict(IN_SYSTEM)))

    def test_nothing_to_check_for_home_on_the_install_disk(self):
        with mock.patch.object(home_drive, "validate_home") as validated:
            home_drive.check_before_erase(home_ctx(None))
        validated.assert_not_called()


class ScanTest(unittest.TestCase):
    def test_before_the_image_the_install_disks_are_named_and_no_accounts_are_read(self):
        # Nothing is mounted at the target yet, so the install disks come from
        # the config (by their canonical names, as lsblk prints them), and the
        # target's account files are not the image's: only the static rules.
        calls = []

        def fake_run(cmd, **kwargs):
            calls.append((cmd, kwargs))
            return mock.Mock(returncode=0, stdout="", stderr="")

        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "vda").touch()
            (Path(tmp) / "by-id").symlink_to(Path(tmp) / "vda")
            with mock.patch.object(home_drive, "_disks_under", return_value=["/dev/sda"]) as under, \
                    mock.patch.object(home_drive.subprocess, "run", side_effect=fake_run), \
                    mock.patch.object(home_drive, "helper_path", return_value=Path("/h.sh")), \
                    mock.patch.dict(home_drive.os.environ, {"HOME_DRIVE_PASSWD": "/etc/passwd"}):
                home_drive.scan("kim", "pw", target=None, excluded=[str(Path(tmp) / "by-id"), None])
            cmd, kwargs = calls[-1]
            self.assertEqual(cmd[-3:], ["kim", str(Path(tmp) / "vda"), "/dev/sda"])
        under.assert_called_once_with(Path("/run/archiso/bootmnt"))
        self.assertEqual(kwargs["env"]["HOME_DRIVE_PASSWD"], "")
        self.assertEqual(kwargs["env"]["HOME_DRIVE_GROUP"], "")

    def test_scan_excludes_the_disks_under_the_target_and_the_boot_medium(self):
        calls = []

        def fake_run(cmd, **kwargs):
            calls.append((cmd, kwargs))
            return mock.Mock(returncode=0, stdout=ADOPTABLE + "\n")

        with mock.patch.object(home_drive, "_disks_under", side_effect=[["/dev/vda"], ["/dev/sda"]]), \
                mock.patch.object(home_drive.subprocess, "run", side_effect=fake_run), \
                mock.patch.object(home_drive, "helper_path", return_value=Path("/h.sh")):
            out = home_drive.scan("kim", "pw", target=Path("/mnt"))
        cmd, kwargs = calls[-1]
        self.assertEqual(cmd[-3:], ["kim", "/dev/vda", "/dev/sda"])
        self.assertNotIn("pw", cmd, "the password never goes on the command line")
        self.assertEqual(kwargs["env"]["HOME_DRIVE_SECRET"], "pw")
        self.assertEqual(kwargs["env"]["HOME_DRIVE_PASSWD"], "/mnt/etc/passwd")
        self.assertEqual(kwargs["env"]["HOME_DRIVE_GROUP"], "/mnt/etc/group")
        self.assertEqual(out, ADOPTABLE + "\n")

    def test_scan_leftovers_are_cleaned_up_before_scanning(self):
        # A scan killed midway (the configurator's spinner interrupted, or an
        # earlier attempt) leaves a drive mounted or an omarchy-home-scan
        # mapping open, and the next scan would find that drive locked.
        calls = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            return mock.Mock(returncode=0, stdout="", stderr="")

        with mock.patch.object(home_drive, "_disks_under", return_value=[]), \
                mock.patch.object(home_drive.subprocess, "run", side_effect=fake_run), \
                mock.patch.object(home_drive, "helper_path", return_value=Path("/h.sh")):
            home_drive.scan("kim", "pw", target=Path("/mnt"))
        scripts = [cmd[2] for cmd in calls if cmd[:2] == ["bash", "-c"]]
        self.assertEqual(len(scripts), 2)
        self.assertIn("home_drive_scan_cleanup", scripts[0])
        self.assertIn("home_drive_scan ", scripts[1])
        self.assertEqual(calls[0][3], "/h.sh")



import types  # noqa: E402


class Recorder:
    """subprocess.run stand-in: records argv and answers the few queries."""

    def __init__(self, answers=None, fail=()):
        self.calls = []
        self.answers = answers or {}
        self.fail = fail

    def __call__(self, cmd, **kwargs):
        self.calls.append((list(cmd), kwargs))
        if any(" ".join(cmd).startswith(prefix) for prefix in self.fail):
            return mock.Mock(returncode=1, stdout="", stderr="failed")
        for prefix, out in self.answers.items():
            if " ".join(cmd).startswith(prefix):
                return mock.Mock(returncode=0, stdout=out, stderr="")
        # A mapping nobody opened: cryptsetup status says so.
        if list(cmd[:2]) == ["cryptsetup", "status"]:
            return mock.Mock(returncode=4, stdout="", stderr="")
        return mock.Mock(returncode=0, stdout="", stderr="")

    def argv(self):
        return [c for c, _ in self.calls]


def home_ctx(home, creds=None, encrypt=False):
    # encrypt is whether the install is encrypted (phases_impl works that out
    # from the disk config); ctx.encrypt is only the optional flag file, so
    # it is left unset here to keep the two from being confused.
    users = [{"username": "kim"}]
    return types.SimpleNamespace(
        target=Path("/mnt"), omarchy_install={"home": home}, encrypt=False, install_encrypted=encrypt,
        user_credentials=dict({"users": users}, **(creds or {})),
        state_dir=Path("/run/omarchy-install"),
    )


class PrepareHomeTest(unittest.TestCase):
    def prepare(self, ctx, answers=None):
        run = Recorder(answers)
        with mock.patch.object(home_drive, "validate_home") as validated, \
                mock.patch.object(home_drive.subprocess, "run", side_effect=run), \
                mock.patch.object(home_drive.Path, "mkdir"):
            home_drive.prepare_home(ctx, encrypted=ctx.install_encrypted)
        return run, validated

    def test_nothing_to_do_for_home_on_the_install_disk(self):
        run, validated = self.prepare(home_ctx(None))
        self.assertEqual(run.calls, [])
        validated.assert_not_called()

    def test_adopt_checks_the_drive_before_touching_it(self):
        run, validated = self.prepare(home_ctx(dict(ADOPT)))
        validated.assert_called_once_with(ADOPT, Path("/mnt"), "kim", "", None)
        self.assertIn(["mount", "/dev/vdb1", "/mnt/home"], run.argv())

    def test_adopt_luks_opens_then_mounts(self):
        home = dict(ADOPT, luks_uuid="l1", subvol="@home", fstype="btrfs")
        run, _ = self.prepare(home_ctx(home, {"home_encryption_password": "hp"}),
                              answers={"blkid -o value -s TYPE /dev/vdb1": "crypto_LUKS\n"})
        argv = run.argv()
        # The validated device, never UUID=: a cloned drive carries the same
        # LUKS UUID, and opening by it could open the clone.
        opened = argv.index(["cryptsetup", "open", "--key-file=-", "/dev/vdb1", "home"])
        self.assertEqual(run.calls[opened][1]["input"], "hp")
        mounted = argv.index(["mount", "-o", "subvol=@home", "/dev/mapper/home", "/mnt/home"])
        self.assertLess(opened, mounted)

    def test_adopt_btrfs_top_level_mounts_the_top_level(self):
        run, _ = self.prepare(home_ctx(dict(ADOPT, fstype="btrfs")))
        self.assertIn(["mount", "-o", "subvolid=5", "/dev/vdb1", "/mnt/home"], run.argv())

    def test_a_home_inside_another_system_mounts_only_its_folder(self):
        run, _ = self.prepare(home_ctx(dict(IN_SYSTEM)))
        self.assertIn(["mount", "-o", "X-mount.subdir=home", "/dev/vdb2", "/mnt/home"], run.argv())

    def test_a_home_inside_a_btrfs_root_subvolume_mounts_that_subvolumes_folder(self):
        run, _ = self.prepare(home_ctx(dict(IN_SYSTEM, fstype="btrfs", subvol="@")))
        self.assertIn(["mount", "-o", "subvol=@,X-mount.subdir=home", "/dev/vdb2", "/mnt/home"], run.argv())

    def test_a_home_inside_a_btrfs_top_level_mounts_the_top_levels_folder(self):
        run, _ = self.prepare(home_ctx(dict(IN_SYSTEM, fstype="btrfs")))
        self.assertIn(["mount", "-o", "subvolid=5,X-mount.subdir=home", "/dev/vdb2", "/mnt/home"], run.argv())

    def test_an_encrypted_home_inside_another_system_mounts_the_opened_folder(self):
        home = dict(IN_SYSTEM, luks_uuid="l2")
        run, _ = self.prepare(home_ctx(home, {"home_encryption_password": "hp"}),
                              answers={"blkid -o value -s TYPE /dev/vdb2": "crypto_LUKS\n"})
        self.assertIn(["mount", "-o", "X-mount.subdir=home", "/dev/mapper/home", "/mnt/home"], run.argv())

    def test_adopt_reuses_a_home_already_open(self):
        # A failed install left the home's LUKS open; opening it again fails.
        home = dict(ADOPT, luks_uuid="l1")
        run, _ = self.prepare(home_ctx(home, {"home_encryption_password": "hp"}),
                              answers={"cryptsetup status home": "  device:  /dev/vdb1\n",
                                       "blkid -o value -s UUID /dev/vdb1": "l1\n",
                                       "blkid -o value -s TYPE /dev/vdb1": "crypto_LUKS\n"})
        argv = run.argv()
        self.assertFalse(any(c[:2] == ["cryptsetup", "open"] for c in argv))
        self.assertIn(["mount", "/dev/mapper/home", "/mnt/home"], argv)

    def test_fresh_partitions_encrypts_formats_and_mounts(self):
        ctx = home_ctx({"mode": "fresh", "disk": "/dev/vdc"}, {"encryption_password": "pw"}, encrypt=True)
        run, _ = self.prepare(ctx, answers={
            "lsblk -nrpo NAME,TYPE /dev/vdc": "/dev/vdc disk\n/dev/vdc1 part\n",
            "blkid -o value -s UUID /dev/vdc1": "l-new\n",
            "blkid -o value -s UUID /dev/mapper/home": "f-new\n",
        })
        argv = run.argv()
        expected = [
            # Every old partition's signatures first, so nothing on them is
            # assembled again when the new table is read.
            ["wipefs", "--all", "--force", "/dev/vdc1"],
            ["wipefs", "--all", "--force", "/dev/vdc"],
            ["parted", "-s", "/dev/vdc", "mklabel", "gpt", "mkpart", "home", "1MiB", "100%"],
            ["cryptsetup", "luksFormat", "--type", "luks2", "--batch-mode", "--key-file=-", "/dev/vdc1"],
            ["cryptsetup", "open", "--key-file=-", "/dev/vdc1", "home"],
            ["mkfs.btrfs", "-f", "-L", "OMARCHY_HOME", "/dev/mapper/home"],
            ["btrfs", "subvolume", "create", "/run/omarchy-install/home-top/@home"],
            ["mount", "-o", "noatime,compress=zstd,subvol=@home", "/dev/mapper/home", "/mnt/home"],
        ]
        positions = [argv.index(cmd) for cmd in expected]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(run.calls[argv.index(expected[3])][1]["input"], "pw")
        self.assertEqual(ctx.omarchy_install["home"],
                         {"mode": "fresh", "disk": "/dev/vdc", "uuid": "f-new", "fstype": "btrfs",
                          "subvol": "@home", "luks_uuid": "l-new", "dir": ""})

    def test_fresh_unencrypted_formats_the_partition(self):
        ctx = home_ctx({"mode": "fresh", "disk": "/dev/vdc"})
        run, _ = self.prepare(ctx, answers={"lsblk -nrpo NAME,TYPE /dev/vdc": "/dev/vdc disk\n/dev/vdc1 part\n"})
        argv = run.argv()
        self.assertIn(["mkfs.btrfs", "-f", "-L", "OMARCHY_HOME", "/dev/vdc1"], argv)
        self.assertFalse(any(c[:2] == ["cryptsetup", "luksFormat"] for c in argv))


class HomeFstabEntriesTest(unittest.TestCase):
    def test_entries_come_from_the_shared_helper(self):
        home = dict(ADOPT, luks_uuid="l1")
        ctx = home_ctx(home, {"home_encryption_password": "hp"})
        run = Recorder()
        with mock.patch.object(home_drive.subprocess, "run", side_effect=run), \
                mock.patch.object(home_drive, "helper_path", return_value=Path("/h.sh")):
            home_drive.home_fstab_entries(ctx, root_encrypted=True)
        cmd, kwargs = run.calls[0]
        self.assertEqual(cmd[:2], ["bash", "-c"])
        self.assertIn("home_drive_mount_entries", cmd[2])
        self.assertEqual(cmd[3:], ["/h.sh", "/mnt", "u1", "xfs", "", "l1", "true", ""])
        self.assertEqual(kwargs["env"]["HOME_DRIVE_SECRET"], "hp")

    def entries(self, home, creds=None):
        run = Recorder()
        with mock.patch.object(home_drive.subprocess, "run", side_effect=run), \
                mock.patch.object(home_drive, "helper_path", return_value=Path("/h.sh")):
            home_drive.home_fstab_entries(home_ctx(home, creds), root_encrypted=False)
        return run.calls[0]

    def test_a_home_inside_another_system_names_its_folder_before_the_secret(self):
        # home_drive_mount_entries root uuid fstype subvol luks_uuid
        # root_encrypted dir password: the secret stays last, from the
        # environment and never on the command line.
        cmd, kwargs = self.entries(dict(IN_SYSTEM, fstype="btrfs", subvol="@", luks_uuid="l2"),
                                   {"home_encryption_password": "hp"})
        self.assertEqual(cmd[3:], ["/h.sh", "/mnt", "u2", "btrfs", "@", "l2", "false", "home"])
        self.assertTrue(cmd[2].rstrip().endswith('"$@" "$HOME_DRIVE_SECRET"'))
        self.assertNotIn("hp", cmd)
        self.assertEqual(kwargs["env"]["HOME_DRIVE_SECRET"], "hp")

    def test_a_fresh_homes_entries_name_no_folder(self):
        cmd, _ = self.entries({"mode": "fresh", "disk": "/dev/vdc", "uuid": "f", "fstype": "btrfs",
                               "subvol": "@home", "luks_uuid": "", "dir": ""})
        self.assertEqual(cmd[3:], ["/h.sh", "/mnt", "f", "btrfs", "@home", "", "false", ""])

    def test_a_failure_never_shows_the_passphrase(self):
        ctx = home_ctx(dict(ADOPT, luks_uuid="l1"), {"home_encryption_password": "hp-secret"})

        def failing(cmd, **kwargs):
            return mock.Mock(returncode=1, stdout="", stderr="boom")

        with mock.patch.object(home_drive.subprocess, "run", side_effect=failing), \
                mock.patch.object(home_drive, "helper_path", return_value=Path("/h.sh")):
            with self.assertRaises(RuntimeError) as raised:
                home_drive.home_fstab_entries(ctx, root_encrypted=True)
        self.assertNotIn("hp-secret", str(raised.exception))


from contextlib import ExitStack  # noqa: E402

import archinstall_fakes  # noqa: E402


class InstallOrderTest(unittest.TestCase):
    """The home drive is mounted after the root image is written (writing it
    unmounts the whole target) and before the user is created on it, and its
    fstab line is written after archinstall's or Omarchy's own fstab."""

    def test_home_is_prepared_between_the_image_and_the_user(self):
        with archinstall_fakes.orchestrator_module("phases_impl") as phases_impl, ExitStack() as stack:
            events = []
            installer = mock.MagicMock()
            installer.create_users.side_effect = lambda users: events.append("users")
            config = types.SimpleNamespace(
                kernels=["linux-omarchy"], locale_config=None, mirror_config=None, swap=None,
                auth_config=types.SimpleNamespace(users=["u"]), app_config=None, timezone=None,
                ntp=False, hostname="test", pacman_config="/etc/pacman.conf",
            )
            ctx = types.SimpleNamespace(
                state={"arch_config_handler": types.SimpleNamespace(config=config), "mirror_handler": None},
                target=Path("/unused"), tailscale_authkey_path=None, defer_provisioning=False,
                omarchy_install={"home": dict(ADOPT)},
                # Encrypted by the disk config alone: the optional flag file
                # (ctx.encrypt) is not how every install says so.
                encrypt=False, user_configuration={"disk_config": {"disk_encryption": {"encryption_type": "luks"}}},
            )
            for name in ("_mount_offline_package_cache", "_mask_mkinitcpio_pacman_hooks", "_configure_limine_boot",
                         "_start_target_keyring_init", "_unmask_mkinitcpio_pacman_hooks",
                         "_unmount_offline_package_cache", "_validate_kernel_headers", "_write_language_marker"):
                stack.enter_context(mock.patch.object(phases_impl, name, create=True))
            stack.enter_context(mock.patch.object(phases_impl, "_install_root_image",
                                                  side_effect=lambda ctx: events.append("image")))
            stack.enter_context(mock.patch.object(phases_impl, "_write_pre_mounted_fstab",
                                                  side_effect=lambda ctx: events.append("fstab")))
            prepared = stack.enter_context(mock.patch.object(
                phases_impl.home_drive, "prepare_home",
                side_effect=lambda ctx, encrypted: events.append("home")))
            stack.enter_context(mock.patch.object(phases_impl.home_drive, "register_adopted_user",
                                                  side_effect=lambda ctx: events.append("register")))
            stack.enter_context(mock.patch.object(phases_impl.home_drive, "merge_home",
                                                  side_effect=lambda ctx: events.append("merge")))
            entries = stack.enter_context(mock.patch.object(
                phases_impl.home_drive, "home_fstab_entries",
                side_effect=lambda ctx, root_encrypted: events.append("entries")))
            stack.enter_context(mock.patch.object(phases_impl, "configure_keyboard", return_value=True))
            for name, value in (("is_pre_mount", True), ("root_user", None), ("target_missing_packages", [])):
                stack.enter_context(mock.patch.object(phases_impl.arch, name, return_value=value, create=True))
            for name in ("sanity_check", "install_base_delta"):
                stack.enter_context(mock.patch.object(phases_impl.arch, name, create=True))
            stack.enter_context(mock.patch.object(phases_impl, "_platform_delta_packages", return_value=[], create=True))
            opened = stack.enter_context(mock.patch.object(phases_impl.arch, "open_installer", create=True))
            opened.return_value.__enter__.return_value = installer

            phases_impl.arch_install_system(ctx)

        self.assertEqual(events, ["image", "home", "register", "users", "merge", "fstab", "entries"])
        self.assertTrue(prepared.call_args.kwargs["encrypted"])
        self.assertTrue(entries.call_args.kwargs["root_encrypted"])


class AdoptedUserTest(unittest.TestCase):
    """archinstall creates users with useradd -m and takes the next free uid;
    an adopted home needs the uid and gid that already own it, and no copied
    skel. Its on_user_create plugin hook lets the adopted user be created here
    while archinstall still sets the password, groups and sudo."""

    def plugin(self, home):
        return home_drive.AdoptedUserPlugin(Path("/mnt"), "kim", home["uid"], home["gid"])

    def create(self, home, username="kim", sudo=True):
        run = Recorder()
        user = types.SimpleNamespace(username=username, sudo=sudo)
        with mock.patch.object(home_drive.subprocess, "run", side_effect=run):
            handled = self.plugin(home).on_user_create(mock.Mock(), user)
        return handled, run.argv()

    def test_adopt_creates_user_with_found_ids(self):
        handled, argv = self.create(ADOPT)
        self.assertTrue(handled)
        self.assertEqual(argv, [
            ["arch-chroot", "/mnt", "groupadd", "-g", "1000", "kim"],
            ["arch-chroot", "/mnt", "useradd", "-M", "-u", "1000", "-g", "1000", "-G", "wheel", "-s", "/bin/bash",
             "--", "kim"],
        ])

    def test_adopt_users_group_100(self):
        _, argv = self.create(dict(ADOPT, gid=100))
        self.assertFalse(any("groupadd" in cmd for cmd in argv))
        self.assertIn("users", argv[0])

    def test_other_users_are_left_to_archinstall(self):
        handled, argv = self.create(ADOPT, username="someone")
        self.assertFalse(handled)
        self.assertEqual(argv, [])

    def test_registered_only_for_an_adopted_home(self):
        plugins = {}
        home_drive.register_adopted_user(home_ctx({"mode": "fresh", "disk": "/dev/vdc"}), plugins)
        self.assertEqual(plugins, {})
        home_drive.register_adopted_user(home_ctx(dict(ADOPT)), plugins)
        self.assertIsInstance(plugins["omarchy-adopted-home"], home_drive.AdoptedUserPlugin)

    def test_adopt_runs_merge_as_the_homes_owner_inside_the_target(self):
        # Inside the target, so every absolute link in the adopted home (a
        # symlinked ~/.config included) resolves there, not on the live ISO.
        # The helper's code goes in on stdin: the target need not carry it.
        run = Recorder()
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "home-drive.sh"
            helper.write_text("home_drive_merge() { :; }\n")
            with mock.patch.object(home_drive.subprocess, "run", side_effect=run), \
                    mock.patch.object(home_drive, "helper_path", return_value=helper):
                home_drive.merge_home(home_ctx(dict(ADOPT)))
        cmd, kwargs = run.calls[0]
        self.assertEqual(cmd, ["arch-chroot", "/mnt", "setpriv", "--reuid=1000", "--regid=1000", "--clear-groups",
                               "bash", "-s", "--", "/etc/skel", "/home/kim"])
        self.assertTrue(kwargs["input"].startswith("home_drive_merge() { :; }\n"))
        self.assertIn('home_drive_merge "$1" "$2"', kwargs["input"])

    def merge(self, returncode):
        def merged(cmd, **kwargs):
            return mock.Mock(returncode=returncode, stdout="", stderr="cp: cannot create '.config/hypr'\n")

        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "home-drive.sh"
            helper.write_text("home_drive_merge() { :; }\n")
            with mock.patch.object(home_drive.subprocess, "run", side_effect=merged), \
                    mock.patch.object(home_drive, "helper_path", return_value=helper), \
                    mock.patch.object(home_drive, "error") as error, \
                    mock.patch.object(home_drive, "info") as info:
                home_drive.merge_home(home_ctx(dict(ADOPT)))
        return error, info

    def test_defaults_that_could_not_be_copied_are_a_warning(self):
        # home_drive_merge's 3: it finished, but some of Omarchy's defaults
        # are not in the home (listed in its adopted-home record). The home
        # is the user's and works without them; the log says so.
        error, info = self.merge(3)
        self.assertIn("could not be copied", error.call_args.args[0])
        self.assertIn("cp: cannot create '.config/hypr'", " ".join(c.args[0] for c in info.call_args_list))

    def test_a_failed_merge_stops_the_install(self):
        with self.assertRaisesRegex(RuntimeError, "arch-chroot"):
            self.merge(1)

    def test_merge_is_only_for_an_adopted_home(self):
        run = Recorder()
        with mock.patch.object(home_drive.subprocess, "run", side_effect=run):
            home_drive.merge_home(home_ctx({"mode": "fresh", "disk": "/dev/vdc"}))
            home_drive.merge_home(home_ctx(None))
        self.assertEqual(run.calls, [])

    def test_user_setup_is_told_the_home_is_adopted(self):
        self.assertEqual(home_drive.setup_env(home_ctx(dict(ADOPT))), ["OMARCHY_ADOPTED_HOME=1"])
        self.assertEqual(home_drive.setup_env(home_ctx({"mode": "fresh", "disk": "/dev/vdc"})), [])
        self.assertEqual(home_drive.setup_env(home_ctx(None)), [])


IN_USE = "/dev/mapper/home is active and is in use.\n"


class SafetyTest(unittest.TestCase):
    def prepare(self, ctx, answers):
        run = Recorder(answers)
        with mock.patch.object(home_drive, "validate_home"), \
                mock.patch.object(home_drive.subprocess, "run", side_effect=run), \
                mock.patch.object(home_drive.Path, "mkdir"):
            home_drive.prepare_home(ctx, encrypted=ctx.install_encrypted)
        return run

    def test_another_drives_open_mapping_is_never_mounted(self):
        home = dict(ADOPT, luks_uuid="l1")
        with self.assertRaisesRegex(RuntimeError, "already open"):
            self.prepare(home_ctx(home, {"home_encryption_password": "hp"}),
                         {"cryptsetup status home": IN_USE + "  device:  /dev/vdc1\n",
                          "blkid -o value -s UUID /dev/vdc1": "other\n"})

    def test_a_stale_mapping_nothing_uses_is_closed(self):
        # A failed attempt left another drive's mapping by that name, with
        # nothing on it: it is closed, not mistaken for the home.
        home = dict(ADOPT, luks_uuid="l1")
        run = self.prepare(home_ctx(home, {"home_encryption_password": "hp"}),
                           {"cryptsetup status home": "/dev/mapper/home is active.\n  device:  /dev/vdc1\n",
                            "blkid -o value -s TYPE /dev/vdb1": "crypto_LUKS\n"})
        argv = run.argv()
        closed = argv.index(["cryptsetup", "close", "home"])
        opened = next(i for i, c in enumerate(argv) if c[:2] == ["cryptsetup", "open"])
        self.assertLess(closed, opened)

    def test_a_clones_open_mapping_is_not_taken_for_the_home(self):
        # Same LUKS UUID, another device: a clone of the drive, not the home.
        home = dict(ADOPT, luks_uuid="l1")
        with self.assertRaisesRegex(RuntimeError, "already open for /dev/vdx1"):
            self.prepare(home_ctx(home, {"home_encryption_password": "hp"}),
                         {"cryptsetup status home": IN_USE + "  device:  /dev/vdx1\n",
                          "blkid -o value -s UUID /dev/vdx1": "l1\n",
                          "blkid -o value -s TYPE /dev/vdb1": "crypto_LUKS\n"})

    def test_an_encrypted_home_whose_device_is_not_luks_is_refused(self):
        home = dict(ADOPT, luks_uuid="l1")
        with self.assertRaisesRegex(RuntimeError, "not the encrypted home"):
            self.prepare(home_ctx(home, {"home_encryption_password": "hp"}),
                         {"blkid -o value -s TYPE /dev/vdb1": "xfs\n"})

    def test_a_stale_mapping_is_closed_before_a_fresh_home_opens_its_own(self):
        ctx = home_ctx({"mode": "fresh", "disk": "/dev/vdc"}, {"encryption_password": "pw"}, encrypt=True)
        run = self.prepare(ctx, {"cryptsetup status home": "/dev/mapper/home is active.\n  device:  /dev/vdd1\n",
                                 "lsblk -nrpo NAME,TYPE /dev/vdc": "/dev/vdc disk\n/dev/vdc1 part\n"})
        argv = run.argv()
        self.assertLess(argv.index(["cryptsetup", "close", "home"]),
                        argv.index(["cryptsetup", "open", "--key-file=-", "/dev/vdc1", "home"]))

    def test_a_failed_fresh_home_lets_go_of_what_it_opened(self):
        # Else the next attempt finds home-top mounted and the mapping open.
        ctx = home_ctx({"mode": "fresh", "disk": "/dev/vdc"}, {"encryption_password": "pw"}, encrypt=True)
        run = Recorder({"lsblk -nrpo NAME,TYPE /dev/vdc": "/dev/vdc disk\n/dev/vdc1 part\n"},
                       fail=("btrfs subvolume create",))
        with mock.patch.object(home_drive, "validate_home"), \
                mock.patch.object(home_drive.subprocess, "run", side_effect=run), \
                mock.patch.object(home_drive.Path, "mkdir"):
            with self.assertRaisesRegex(RuntimeError, "btrfs"):
                home_drive.prepare_home(ctx, encrypted=ctx.install_encrypted)
        argv = run.argv()
        self.assertLess(argv.index(["umount", "/run/omarchy-install/home-top"]),
                        argv.index(["cryptsetup", "close", "home"]))

    def test_encrypted_fresh_home_without_a_key_stops_before_erasing(self):
        ctx = home_ctx({"mode": "fresh", "disk": "/dev/vdc"}, encrypt=True)
        ctx.user_configuration = {}
        run = Recorder()
        with mock.patch.object(home_drive, "validate_home"), \
                mock.patch.object(home_drive.subprocess, "run", side_effect=run):
            with self.assertRaisesRegex(RuntimeError, "no passphrase"):
                home_drive.prepare_home(ctx, encrypted=ctx.install_encrypted)
        self.assertFalse(any(c[0] in ("wipefs", "parted") for c in run.argv()))

    def test_encryption_key_from_disk_config_is_used(self):
        ctx = home_ctx({"mode": "fresh", "disk": "/dev/vdc"}, encrypt=True)
        ctx.user_configuration = {"disk_config": {"disk_encryption": {"encryption_password": "dk"}}}
        run = self.prepare(ctx, {"lsblk -nrpo NAME,TYPE /dev/vdc": "/dev/vdc disk\n/dev/vdc1 part\n"})
        formatted = [c for c in run.calls if c[0][:2] == ["cryptsetup", "luksFormat"]]
        self.assertEqual(formatted[0][1]["input"], "dk")

    def test_a_home_on_the_install_disk_is_refused_before_anything_is_erased(self):
        def lsblk(cmd, **kwargs):
            return mock.Mock(returncode=0, stdout="/dev/vdb1 part\n/dev/vda disk\n", stderr="")
        with mock.patch.object(home_drive.subprocess, "run", side_effect=lsblk):
            with self.assertRaisesRegex(RuntimeError, "install disk"):
                home_drive.check_not_on_install_disks(dict(ADOPT), ["/dev/vda"])
            with self.assertRaisesRegex(RuntimeError, "install disk"):
                home_drive.check_not_on_install_disks({"mode": "fresh", "disk": "/dev/vda"}, ["/dev/vda"])
            home_drive.check_not_on_install_disks({"mode": "fresh", "disk": "/dev/vdc"}, ["/dev/vda"])

    def test_a_by_id_path_does_not_slip_past_the_install_disk_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            disk = Path(tmp) / "vda"
            disk.touch()
            (Path(tmp) / "by-id").symlink_to(disk)
            with self.assertRaisesRegex(RuntimeError, "install disk"):
                home_drive.check_not_on_install_disks({"mode": "fresh", "disk": str(Path(tmp) / "by-id")}, [str(disk)])
            with self.assertRaisesRegex(RuntimeError, "install disk"):
                home_drive.check_not_on_install_disks({"mode": "fresh", "disk": str(disk)}, [str(Path(tmp) / "by-id")])


if __name__ == "__main__":
    unittest.main()
