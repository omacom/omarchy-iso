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

    def test_full_disk_and_editor_entry_points_reject_source(self):
        for entry in ("confirm_disk_overwrite", "open_partition_tool"):
            result = self.run_shell(functions("is_install_media_disk", entry) + f'''
disk=/dev/sda
install_media_disk=/dev/sda
say() {{ :; }}
abort() {{ exit 9; }}
gum() {{ echo UNEXPECTED; exit 10; }}
cfdisk() {{ echo UNEXPECTED; exit 10; }}
{entry}
''')
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("UNEXPECTED", result.stdout)

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
                "get_root_disk", "is_install_media_disk", "can_install_beside_media", "disk_form"
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
parted() { echo '2:1048576B:2097151B:1048576B::ROOT:;'; }
cat() {
  case "$1" in */start) echo "$START" ;; */size) echo "$SIZE" ;; esac
}
verify_partition_device /dev/sda "$NUMBER" "/dev/sda$NUMBER"
''', LIB=str(LIB), START=start, SIZE=size, NUMBER=number)
            self.assertEqual(result.returncode, expected, result.stderr)


if __name__ == "__main__":
    unittest.main()
