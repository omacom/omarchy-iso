"""BitLocker policy tests. No commands here access host disks or encryption."""

import os
import subprocess
import unittest

from .test_install_media import functions


class BitLockerTests(unittest.TestCase):
    def run_shell(self, script, **env):
        return subprocess.run(
            ["bash", "-c", script], text=True, capture_output=True, timeout=10,
            env={**os.environ, **env},
        )

    def test_requires_clear_key_and_successful_readonly_open_and_close(self):
        for protection, dump_status, open_status, close_status, expected in [
            ("clear key", "0", "0", "0", 0),
            ("TPM", "0", "0", "0", 1),
            ("TPM and PIN", "0", "0", "0", 1),
            ("passphrase", "0", "0", "0", 1),
            ("clear key", "1", "0", "0", 1),
            ("clear key", "0", "1", "0", 1),
            ("clear key", "0", "0", "1", 1),
        ]:
            with self.subTest(protection=protection, dump=dump_status,
                              opened=open_status, closed=close_status):
                result = self.run_shell(functions("bitlocker_is_suspended") + r'''
cryptsetup() {
  case "$1" in
    bitlkDump)
      printf '\tProtection: \tVMK protected with %s\n' "$PROTECTION"
      # TPM can remain configured alongside the clear key.
      printf '\tProtection: \tVMK protected with TPM\n'
      return "$DUMP_STATUS" ;;
    open)
      [[ "$*" == 'open --type bitlk --readonly --batch-mode --key-file /dev/null /dev/fake omarchy-bitlocker-check-'* ]] || return 99
      return "$OPEN_STATUS" ;;
    close) return "$CLOSE_STATUS" ;;
    *) return 99 ;;
  esac
}
bitlocker_is_suspended /dev/fake
''', PROTECTION=protection, DUMP_STATUS=dump_status,
                    OPEN_STATUS=open_status, CLOSE_STATUS=close_status)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_checks_all_volumes_and_fails_on_discovery_or_read_errors(self):
        for signature1, signature2, suspended, listing, expected in [
            ("plain", "plain", "", "ok", 0),
            ("bitlk", "plain", "/dev/fake1", "ok", 0),
            ("bitlk", "bitlk", "/dev/fake1 /dev/fake2", "ok", 0),
            ("bitlk", "bitlk", "/dev/fake1", "ok", 1),
            ("bitlk", "plain", "", "ok", 1),
            ("error", "plain", "", "ok", 1),
            ("short", "plain", "", "ok", 1),
            ("plain", "plain", "", "error", 1),
            ("plain", "plain", "", "empty", 1),
        ]:
            with self.subTest(first=signature1, second=signature2,
                              suspended=suspended, listing=listing):
                result = self.run_shell(functions("check_bitlocker") + r'''
disk=/dev/fake
say() { :; }
lsblk() {
  [[ $LISTING == error ]] && return 1
  [[ $LISTING == empty ]] && return 0
  printf '/dev/fake disk\n/dev/fake1 part\n/dev/fake2 part\n'
}
od() {
  local signature=$SIG1
  [[ ${@: -1} == /dev/fake2 ]] && signature=$SIG2
  case "$signature" in
    bitlk) echo ' 2d 46 56 45 2d 46 53 2d' ;;
    plain) echo ' 4e 54 46 53 20 20 20 20' ;;
    error) return 1 ;;
    short) echo ' 00' ;;
  esac
}
bitlocker_is_suspended() { [[ " $SUSPENDED " == *" $1 "* ]]; }
check_bitlocker
''', SIG1=signature1, SIG2=signature2, SUSPENDED=suspended, LISTING=listing)
                self.assertEqual(result.returncode, expected, result.stderr)

    def test_planning_protects_bitlocker_disk_before_asking_to_continue(self):
        result = self.run_shell(functions("run_partition_decide") + r'''
disk=/dev/fake
protected_disk=""
is_install_media_disk() { return 1; }
step() { :; }
say() { :; }
abort() { echo ABORT; exit 9; }
check_bitlocker() { bitlocker_found=true; }
protect_existing_partitions() { protected_disk=$1; echo PROTECTED; }
gum() { [[ $protected_disk == /dev/fake ]] && echo CONFIRMED; return 1; }
run_partition_decide
''')
        self.assertEqual(result.stdout.splitlines(), ["PROTECTED", "CONFIRMED"])
        self.assertEqual(result.returncode, 1)  # User declined, no writes.

    def test_rejects_non_gpt_bitlocker_disk(self):
        result = self.run_shell(functions("run_partition_decide") + r'''
disk=/dev/fake
protected_disk=""
is_install_media_disk() { return 1; }
step() { :; }
say() { :; }
abort() { exit 9; }
check_bitlocker() { bitlocker_found=true; }
protect_existing_partitions() { return 1; }
gum() { echo UNEXPECTED; }
run_partition_decide
''')
        self.assertEqual(result.returncode, 9)
        self.assertNotIn("UNEXPECTED", result.stdout)

    def test_rechecks_state_and_preservation_before_any_write(self):
        for verified, protected, table_ok in [("1", "/dev/fake", "0"),
                                               ("0", "", "0"),
                                               ("0", "/dev/fake", "1")]:
            with self.subTest(verified=verified, protected=protected, table=table_ok):
                result = self.run_shell(functions("run_partition_execute") + r'''
disk=/dev/fake
protected_disk=$PROTECTED
needs_mklabel=false
step() { :; }
abort() { exit 9; }
verify_install_media() { return 0; }
verify_existing_partitions() { return "$TABLE_STATUS"; }
check_bitlocker() { bitlocker_found=true; return "$VERIFIED"; }
disk_step() { echo WRITE; exit 10; }
create_partition() { echo WRITE; exit 10; }
run_partition_execute
''', VERIFIED=verified, PROTECTED=protected, TABLE_STATUS=table_ok)
                self.assertEqual(result.returncode, 9, result.stderr)
                self.assertNotIn("WRITE", result.stdout)

    def test_partition_editor_is_blocked_on_protected_non_media_disk(self):
        result = self.run_shell(functions("open_partition_tool") + r'''
disk=/dev/fake
protected_disk=/dev/fake
is_install_media_disk() { return 1; }
say() { :; }
cfdisk() { echo WRITE; }
open_partition_tool
''')
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("WRITE", result.stdout)


if __name__ == "__main__":
    unittest.main()
