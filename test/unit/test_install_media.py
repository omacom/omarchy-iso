"""Exercise the real configurator functions with synthetic block topology."""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CONFIGURATOR = (ROOT / "configs/airootfs/root/configurator").read_text()
LIB = ROOT / "configs/airootfs/usr/share/omarchy-iso/disk-partitioning.sh"


def functions(*names):
    return "\n".join(
        re.search(rf"^{name}\(\) [{{(].*?^[}})](?=\n\n|\Z)", CONFIGURATOR, re.M | re.S).group()
        for name in names
    )


class InstallMediaTests(unittest.TestCase):
    def run_shell(self, script, **env):
        with tempfile.TemporaryDirectory() as efi:
            # WSL and BIOS test hosts have no EFI firmware directory.
            script = script.replace("/sys/firmware/efi", efi)
            return subprocess.run(
                ["bash", "-c", script], text=True, capture_output=True,
                env={**os.environ, **env},
            )

    def test_only_direct_gpt_partitions_are_eligible(self):
        for kind, parent, table, deferred, expected in [
            ("part", "nvme0n1", "gpt", "false", 0),
            ("part", "nvme0n1", "dos", "false", 1),
            ("disk", "", "gpt", "false", 1),
            ("loop", "", "gpt", "false", 1),
            ("crypt", "nvme0n1", "gpt", "false", 1),
            ("part", "sdb", "gpt", "false", 1),
            ("part", "nvme0n1", "gpt", "true", 1),
        ]:
            with self.subTest(kind=kind, parent=parent, table=table, deferred=deferred):
                result = self.run_shell(functions("can_install_beside_media") + r'''
install_media_partition=/dev/nvme0n1p3
install_media_disk=/dev/nvme0n1
defer_provisioning=$DEFERRED
lsblk() {
  case "$2" in
    TYPE) echo "$KIND" ;;
    PKNAME) echo "$PARENT" ;;
    PTTYPE) echo "$TABLE" ;;
  esac
}
can_install_beside_media
''', KIND=kind, PARENT=parent, TABLE=table, DEFERRED=deferred)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_source_disk_never_offers_full_disk_install(self):
        for selected, expected in [("/dev/sda", False), ("/dev/sdb", True)]:
            result = self.run_shell(functions("is_install_media_disk", "install_mode_form") + r'''
disk=$SELECTED
install_media_disk=/dev/sda
full_disk_only=false
step() { :; }
gum() { printf '%s\n' "$@"; }
abort() { exit 9; }
install_mode_form
printf '%s\n' "$install_mode"
''', SELECTED=selected)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual("Full disk install" in result.stdout, expected)
            self.assertIn("Free space install", result.stdout)

    def test_full_disk_entry_point_rejects_source(self):
        result = self.run_shell(functions("is_install_media_disk", "confirm_disk_overwrite") + r'''
disk=/dev/sda
install_media_disk=/dev/sda
abort() { exit 9; }
gum() { echo UNEXPECTED; exit 10; }
confirm_disk_overwrite
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("UNEXPECTED", result.stdout)

    def test_source_disk_uses_restricted_editor(self):
        result = self.run_shell(functions("open_partition_tool") + r'''
disk=/dev/sda
is_install_media_disk() { return 0; }
open_install_media_partition_tool() { echo RESTRICTED; }
cfdisk() { echo UNEXPECTED; exit 10; }
open_partition_tool
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "RESTRICTED")

    def test_custom_source_and_unlabeled_efi_are_protected_but_data_can_be_deleted(self):
        result = self.run_shell(r'''
source "$LIB"
deleted=false
parted() {
  if [[ $1 == --script ]]; then
    [[ $3 == rm && $4 == 3 ]] || return 1
    deleted=true
    return 0
  fi
  printf '%s\n' 'BYT;' '/dev/sda:100000000B:scsi:512:512:gpt:disk:;'
  printf '%s\n' '1:1048576B:535822335B:534773760B:fat32:EFI:boot, esp;'
  printf '%s\n' '2:535822336B:10000000000B:9464177664B:ntfs:ISO:msftdata;'
  if ! $deleted; then
    printf '%s\n' '3:10000000001B:20000000000B:10000000000B:ntfs:OLD:msftdata;'
  fi
}
lsblk() {
  case "$*" in
    '-dnro PARTN /dev/sda2') echo 2 ;;
    '-nr -o MOUNTPOINTS /dev/sda3') : ;;
  esac
}
sfdisk() {
  case "$3" in
    1) echo c12a7328-f81f-11d2-ba4b-00a0c93ec93b ;;
    2|3) echo ebd0a0a2-b9e5-4433-87c0-68b6b72699c7 ;;
  esac
}
partprobe() { :; }
sync() { :; }
protect_install_media_partitions /dev/sda /dev/sda2 || exit 10
is_existing_partition /dev/sda 1 || exit 11
is_existing_partition /dev/sda 2 || exit 12
is_existing_partition /dev/sda 3 && exit 13
expected='3:10000000001B:20000000000B:10000000000B:ntfs:OLD:msftdata;'
delete_unprotected_partition /dev/sda 2 '2:535822336B:10000000000B:9464177664B:ntfs:ISO:msftdata;' && exit 14
delete_unprotected_partition /dev/sda 3 "$expected" || exit 15
verify_existing_partitions /dev/sda || exit 16
''', LIB=str(LIB))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_restricted_editor_lists_only_unmounted_unprotected_partitions(self):
        result = self.run_shell(functions("open_install_media_partition_tool") + r'''
disk=/dev/sda
verify_install_media() { return 0; }
step() { :; }
say() { :; }
abort() { exit 9; }
parted() {
  printf '%s\n' 'BYT;' '/dev/sda:100000000B:scsi:512:512:gpt:disk:;'
  printf '%s\n' '1:1048576B:535822335B:534773760B:fat32:EFI:boot, esp;'
  printf '%s\n' '2:535822336B:10000000000B:9464177664B:ntfs:ISO:msftdata;'
  printf '%s\n' '3:10000000001B:20000000000B:10000000000B:ntfs:OLD:msftdata;'
  printf '%s\n' '4:20000000001B:30000000000B:10000000000B:ntfs:MOUNTED:msftdata;'
}
is_existing_partition() { [[ $2 == 1 || $2 == 2 ]]; }
partition_path() { echo "$1$2"; }
lsblk() { [[ $* == *'/dev/sda4' ]] && echo '/mounted'; return 0; }
gum() { printf '%s\n' "$@" >&2; echo Back; }
delete_unprotected_partition() { echo UNEXPECTED; }
open_install_media_partition_tool
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Partition 3", result.stderr)
        self.assertNotIn("Partition 1", result.stderr)
        self.assertNotIn("Partition 2", result.stderr)
        self.assertNotIn("Partition 4", result.stderr)
        self.assertNotIn("UNEXPECTED", result.stdout)

    def test_partition_type_read_failure_blocks_same_disk_editor(self):
        result = self.run_shell(r'''
source "$LIB"
parted() {
  printf '%s\n' 'BYT;' '/dev/sda:100000000B:scsi:512:512:gpt:disk:;'
  printf '%s\n' '2:535822336B:10000000000B:9464177664B:ntfs:ISO:msftdata;'
}
lsblk() {
  case "$*" in
    '-dnro PARTN /dev/sda2') echo 2 ;;
  esac
}
sfdisk() { return 1; }
protect_install_media_partitions /dev/sda /dev/sda2 && exit 10
exit 0
''', LIB=str(LIB))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_full_source_disk_does_not_take_overwrite_shortcut(self):
        result = self.run_shell(functions("is_install_media_disk", "select_installation") + r'''
disk=/dev/sda
install_media_disk=/dev/sda
requires_full_disk_install() { echo UNEXPECTED; return 0; }
confirm_disk_overwrite() { echo UNEXPECTED; exit 10; }
install_mode_form() { install_mode="Free space install"; }
run_partition_decide() { return 0; }
select_installation
echo "$install_target"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "free_space")

    def test_media_must_still_be_mounted_at_execution(self):
        for source, status, expected in [("/dev/sda1", 0, 0), ("/dev/sdb1", 0, 1), ("", 1, 1)]:
            result = self.run_shell(functions("is_install_media_disk", "verify_install_media") + r'''
disk=/dev/sda
install_media_disk=/dev/sda
install_media_partition=/dev/sda1
protected_disk=/dev/sda
protected_partition_table=original
findmnt() { echo "$SOURCE"; return "$STATUS"; }
readlink() { echo "$2"; }
can_install_beside_media() { return 0; }
verify_existing_partitions() { return 0; }
verify_install_media
''', SOURCE=source, STATUS=str(status))
            self.assertEqual(result.returncode, expected, result.stderr)

    def test_disk_picker_preserves_usb_and_deferred_exclusions(self):
        for source_type, deferred, allow in [("part", "false", True), ("part", "true", False), ("disk", "false", False)]:
            result = self.run_shell(functions(
                "get_root_disk", "get_install_media_disk", "is_install_media_disk",
                "can_install_beside_media", "disk_form"
            ) + r'''
defer_provisioning=$DEFERRED
findmnt() { echo /dev/sda1; }
readlink() { echo "$2"; }
lsblk() {
  if [[ $1 == -dpno ]]; then printf '/dev/sda disk\n/dev/sdb disk\n'; return; fi
  case "$2:$3" in
    PKNAME:/dev/sda1) echo sda ;;
    TYPE:/dev/sda1) echo "$KIND" ;;
    TYPE:/dev/sda) echo disk ;;
    PTTYPE:/dev/sda) echo gpt ;;
  esac
}
step() { :; }
get_disk_info() { echo "$1"; }
protect_existing_partitions() { :; }
abort() { echo ABORT; exit 9; }
gum() { cat >&2; echo /dev/sdb; }
disk_form
''', DEFERRED=deferred, KIND=source_type)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual("/dev/sda " in result.stderr, allow)
            self.assertIn("/dev/sdb", result.stderr)

    def test_loopback_source_excludes_backing_disk_but_offers_other_disk(self):
        with tempfile.TemporaryDirectory() as directory:
            backing = Path(directory) / "omarchy.iso"
            backing.touch()
            result = self.run_shell(functions(
                "get_root_disk", "get_install_media_disk", "is_install_media_disk",
                "can_install_beside_media", "disk_form"
            ) + r'''
defer_provisioning=false
findmnt() {
  if [[ $* == *'--target'* ]]; then
    if [[ $* == *FSTYPE* ]]; then echo ext4; else echo /dev/sda1; fi
  else
    echo /dev/loop0
  fi
}
losetup() { echo "$BACKING"; }
readlink() { echo "$2"; }
lsblk() {
  if [[ $1 == -dpno ]]; then printf '/dev/sda disk\n/dev/sdb disk\n'; return; fi
  case "$2:$3" in
    TYPE:/dev/loop0) echo loop ;;
    PKNAME:/dev/sda1) echo sda ;;
    TYPE:/dev/sda) echo disk ;;
  esac
}
step() { :; }
get_disk_info() { echo "$1"; }
abort() { echo ABORT; exit 9; }
gum() { cat >&2; echo /dev/sdb; }
disk_form
''', BACKING=str(backing))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("/dev/sda ", result.stderr)
            self.assertIn("/dev/sdb", result.stderr)

    def test_unresolved_loopback_source_stops_disk_selection(self):
        result = self.run_shell(functions("get_root_disk", "get_install_media_disk") + r'''
lsblk() { [[ $* == *TYPE* ]] && echo loop; }
losetup() { return 1; }
get_install_media_disk /dev/loop0
''')
        self.assertNotEqual(result.returncode, 0)

    def test_btrfs_loopback_backing_is_not_assumed_single_disk(self):
        with tempfile.TemporaryDirectory() as directory:
            backing = Path(directory) / "omarchy.iso"
            backing.touch()
            result = self.run_shell(functions("get_root_disk", "get_install_media_disk") + r'''
lsblk() { [[ $* == *TYPE* ]] && echo loop; }
losetup() { echo "$BACKING"; }
findmnt() {
  if [[ $* == *FSTYPE* ]]; then echo btrfs; else echo '/dev/sda1[/@]'; fi
}
get_install_media_disk /dev/loop0
''', BACKING=str(backing))
            self.assertNotEqual(result.returncode, 0)

    def test_direct_btrfs_source_is_not_assumed_single_disk(self):
        result = self.run_shell(functions("get_root_disk", "get_install_media_disk") + r'''
lsblk() {
  case "$2:$3" in
    TYPE:/dev/sda1) echo part ;;
    PKNAME:/dev/sda1) echo sda ;;
    TYPE:/dev/sda) echo disk ;;
  esac
}
findmnt() { echo btrfs; }
readlink() { echo "$2"; }
get_install_media_disk /dev/sda1
''')
        self.assertNotEqual(result.returncode, 0)

    def test_network_source_has_no_local_disk_to_exclude(self):
        result = self.run_shell(functions("get_root_disk", "get_install_media_disk") + r'''
lsblk() { :; }
findmnt() { echo nfs4; }
get_install_media_disk server:/omarchy
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_missing_source_is_allowed_only_in_explicit_dry_run(self):
        for dry, expected in [("true", 0), ("false", 9)]:
            result = self.run_shell(functions("ram_backed_live_root", "disk_form") + r'''
configurator_dry_run=$DRY
findmnt() { return 1; }
readlink() { return 1; }
lsblk() { printf '/dev/sdb disk\n'; }
step() { :; }
get_disk_info() { echo "$1"; }
abort() { exit 9; }
gum() { cat >&2; echo /dev/sdb; }
disk_form
''', DRY=dry)
            self.assertEqual(result.returncode, expected, result.stderr)
            if dry == "false":
                self.assertNotIn("/dev/sdb", result.stderr)

    def test_missing_boot_mount_requires_live_image_on_copytoram_tmpfs(self):
        with tempfile.TemporaryDirectory() as directory:
            copytoram = Path(directory) / "copytoram"
            copytoram.mkdir()
            in_ram = copytoram / "airootfs.sfs"
            outside = Path(directory) / "outside.sfs"
            in_ram.touch()
            outside.touch()
            source = functions("ram_backed_live_root", "disk_form").replace(
                "/run/archiso/copytoram", str(copytoram)
            )
            for backing, expected in [(in_ram, 0), (outside, 9)]:
                with self.subTest(backing=backing):
                    result = self.run_shell(source + r'''
configurator_dry_run=false
findmnt() {
  if [[ $* == *'--mountpoint'* && $* == *'copytoram'* ]]; then echo tmpfs
  elif [[ $* == *'--mountpoint /run/archiso/airootfs'* ]]; then echo /dev/loop5
  elif [[ $* == *'--target'* ]]; then echo tmpfs
  else return 1
  fi
}
losetup() { echo "$BACKING"; }
readlink() { echo "$2"; }
lsblk() {
  if [[ $1 == -dpno ]]; then printf '/dev/sdb disk\n'; return; fi
  [[ $* == *'TYPE /dev/loop5'* ]] && echo loop
}
step() { :; }
get_disk_info() { echo "$1"; }
abort() { exit 9; }
gum() { cat >&2; echo /dev/sdb; }
disk_form
''', BACKING=str(backing))
                    self.assertEqual(result.returncode, expected, result.stderr)
                    if expected == 0:
                        self.assertIn("/dev/sdb", result.stderr)

    def test_kernel_geometry_must_match_before_formatting(self):
        for start, size, number, expected in [
            ("2048", "2048", "2", 0),
            ("4096", "2048", "2", 1),
            ("2048", "4096", "2", 1),
            ("", "2048", "2", 1),
            ("2048", "2048", "1", 1),
            ("2048", "2048", "3", 1),
        ]:
            result = self.run_shell(r'''
source "$LIB"
protected_disk=/dev/sda
protected_partition_table='1:0B:1048575B:1048576B:ext4:INSTALLER:;'
created_parts=(2)
created_part_identities[2]='test-guid:1048576:1048576'
created_partition_identity() { echo 'test-guid:1048576:1048576'; }
parted() { echo '2:1048576B:2097151B:1048576B::ROOT:;'; }
cat() {
  case "$1" in */start) echo "$START" ;; */size) echo "$SIZE" ;; esac
}
verify_partition_device /dev/sda "$NUMBER" "/dev/sda$NUMBER"
''', LIB=str(LIB), START=start, SIZE=size, NUMBER=number)
            self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
