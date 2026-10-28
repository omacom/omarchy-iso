#!/usr/bin/env python3
"""Exercise the actual initramfs hook against synthetic sysfs, never this host."""
import os
import re
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

HOOK = Path(__file__).resolve().parents[2] / 'builder/qualcomm/early-startup'


class EarlyStartup(unittest.TestCase):
    def run_case(self, profile='adsp', state='running', mode='ok', enabled='1',
                 blacklist='qcom_q6v5_pas', root_compatible='qcom,x1e80100', before_mount='',
                 timeout='3', disabled=False, kernel_blacklist='',
                 firmware_names=('qcom/vendor/adsp.mbn', 'qcom/vendor/adsp_dtb.mbn'),
                 firmware_files=None, driver_loaded=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def write(name, text):
                p = root/name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(text)
            write('proc/device-tree/compatible', root_compatible+'\0')
            write('proc/sys/kernel/osrelease', 'test-kernel\n')
            write('clock', '0\n')
            write('events', '')
            write('kmsg', '')
            (root/'bin').mkdir()
            for command in ('cat','grep','readlink','tr'):
                if mode=='missing-'+command:
                    continue
                tools=os.environ.get('QCOM_TEST_TOOLS')
                target=str(Path(tools)/command) if tools else shutil.which(command)
                (root/'bin'/command).symlink_to(target)
            if profile:
                compat = 'qcom,x1e80100-adsp-pas' if profile == 'adsp' else 'qcom,glymur-soccp-pas'
                write('dt/processor/compatible', compat+'\0')
                if firmware_names is not None:
                    write('dt/processor/firmware-name', '\0'.join(firmware_names)+'\0')
                if disabled:
                    write('dt/processor/status', 'disabled\0')
                dev = root/'sys/bus/platform/devices/6800000.remoteproc'
                dev.mkdir(parents=True)
                (dev/'of_node').symlink_to(root/'dt/processor')
                remote = root/'sys/class/remoteproc/remoteproc7'
                remote.mkdir(parents=True)
                (remote/'device').symlink_to(dev)
                write('sys/class/remoteproc/remoteproc7/state', state+'\n')
            if firmware_files is None:
                firmware_files = firmware_names or ()
            for firmware in firmware_files:
                write('usr/lib/firmware/'+firmware, 'firmware')
            if driver_loaded:
                (root/'sys/module/qcom_q6v5_pas').mkdir(parents=True)
            # Relocate all filesystem access in the production hook. There is
            # no production environment override for reading a different sysfs.
            paths = ('/proc/device-tree/', '/proc/sys/kernel/', '/usr/lib/firmware', '/sys/', '/dev/kmsg')
            code = re.sub('|'.join(map(re.escape, paths)),
                          lambda m: str(root)+('/kmsg' if m[0]=='/dev/kmsg' else m[0]), HOOK.read_text())
            (root/'hook').write_text(code)
            harness = r'''
getarg() {
 case "$1" in
 omarchy.qcom_early) printf '%s' "$ENABLED";;
 omarchy.qcom_timeout) printf '%s' "$TIMEOUT";;
 modprobe.blacklist) printf '%s' "$BLACKLIST";;
 module_blacklist) printf '%s' "$KERNEL_BLACKLIST";;
 *) printf '%s' "${2:-}";;
 esac
}
modprobe() {
 printf 'module %s\n' "$1" >>"$ROOT/events"
 [ "$MODE:$1" != fail:qcom_q6v5_pas ] && [ "$MODE" != "fail-module:$1" ]
}
udevadm() {
 printf 'udev %s\n' "$*" >>"$ROOT/events"
 if [ "$MODE:$1" = deferred:trigger ]; then
   printf 'running\n' >"$ROOT/sys/class/remoteproc/remoteproc7/state"
 fi
 if [ "$MODE:$1" = crash-during-settle:settle ]; then
   printf 'crashed\n' >"$ROOT/sys/class/remoteproc/remoteproc7/state"
 fi
 [ "$MODE:$1" != settle-fail:settle ] && [ "$MODE:$1" != trigger-fail:trigger ]
}
sleep() {
 n=$(cat "$ROOT/clock"); n=$((n + 1)); printf '%s\n' "$n" >"$ROOT/clock"
 if [ "$MODE" = delay ] && [ "$n" -eq 2 ]; then
   printf 'running\n' >"$ROOT/sys/class/remoteproc/remoteproc7/state"
 fi
}
original_mount() { printf 'mounted %s\n' "$*" >>"$ROOT/events"; }
. "$ROOT/hook"
qcom_startup_now() { cat "$ROOT/clock"; }
mount_handler=original_mount
run_earlyhook || :
# mkinitcpio sources the hook again for the normal phase.
. "$ROOT/hook"
run_hook || :
'''
            harness += before_mount + '\n"$mount_handler" /sysroot\n'
            env = os.environ | {'ROOT': tmp, 'MODE': mode, 'ENABLED': enabled, 'PATH':str(root/'bin'),
                                'BLACKLIST': blacklist, 'KERNEL_BLACKLIST': kernel_blacklist,
                                'TIMEOUT': timeout}
            shell = os.environ.get('QCOM_TEST_SHELL', '/bin/sh')
            command = [shell]
            if Path(shell).name == 'busybox':
                command.append('ash')
            result = subprocess.run(command+['-c', harness], env=env, capture_output=True, text=True)
            return result, (root/'events').read_text()

    def test_waits_for_asynchronous_firmware(self):
        result, events = self.run_case(state='offline', mode='delay')
        self.assertEqual(result.returncode, 0, result.stderr+result.stdout)
        self.assertIn('firmware started: adsp=running', result.stdout)
        self.assertTrue(events.endswith('mounted /sysroot\n'), events)
        self.assertLess(events.index('module qrtr'), events.index('module qcom_q6v5_pas'))
        self.assertLess(events.index('module qrtr_smd'), events.index('module qcom_q6v5_pas'))
        self.assertLess(events.index('module ucsi_glink'), events.index('settle'))

    def test_failed_module_cannot_fall_through_to_mount(self):
        for module in ('qrtr', 'qrtr_smd', 'qcom_pd_mapper', 'qcom_q6v5_pas',
                       'pmic_glink', 'pmic_glink_altmode', 'ucsi_glink'):
            with self.subTest(module=module):
                result, events = self.run_case(mode='fail-module:'+module)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('mounted', events)
                self.assertNotIn('settle', events)

    def test_modprobe_success_is_not_firmware_completion(self):
        result, events = self.run_case(state='offline')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('timed out', result.stdout)
        self.assertNotIn('mounted', events)

    def test_deferred_supplier_is_triggered_before_wait(self):
        result, events = self.run_case(state='offline', mode='deferred')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('mounted', events)

    def test_failed_supplier_trigger_blocks_mount(self):
        result, events = self.run_case(mode='trigger-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('mounted', events)

    def test_soccp_attachment_is_accepted(self):
        result, events = self.run_case(profile='soccp', state='attached')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('mounted', events)

    def test_soccp_started_fallback_is_accepted(self):
        result, _ = self.run_case(profile='soccp', state='running')
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_x1_requires_started_firmware(self):
        result, events = self.run_case(state='attached')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('mounted', events)

    def test_crash_after_start_blocks_mount(self):
        result, events = self.run_case(before_mount='printf "crashed\\n" >"$ROOT/sys/class/remoteproc/remoteproc7/state"')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('mounted', events)

    def test_busy_udev_blocks_mount(self):
        result, events = self.run_case(mode='settle-fail')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('mounted', events)

    def test_firmware_can_fail_while_udev_settles(self):
        result, events = self.run_case(mode='crash-during-settle')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('mounted', events)

    def test_kernel_blacklist_conflict_blocks_mount(self):
        for blacklist in ('qcom_q6v5_pas', 'foo,qcom-q6v5-pas,bar'):
            with self.subTest(blacklist=blacklist):
                result, events = self.run_case(kernel_blacklist=blacklist)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('mounted', events)

    def test_unknown_qualcomm_keeps_legacy_path(self):
        result, events = self.run_case(profile=None)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(events, 'mounted /sysroot\n')
        self.assertIn('keeping legacy startup', result.stdout)

    def test_missing_early_utility_cannot_silently_skip_gate(self):
        for command in ('grep', 'tr'):
            result, events = self.run_case(mode='missing-'+command)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('missing early-boot utility', result.stdout)
            self.assertNotIn('mounted', events)

    def test_invalid_firmware_name_is_an_error_not_a_fallback(self):
        result, events = self.run_case(firmware_names=('../outside',), firmware_files=())
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('mounted', events)
        self.assertNotIn('keeping legacy', result.stdout)

    def test_disabled_owner_keeps_legacy_path(self):
        result, events = self.run_case(disabled=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(events, 'mounted /sysroot\n')

    def test_missing_required_firmware_never_starts_drivers(self):
        for files in ((), ('qcom/vendor/adsp.mbn',), ('qcom/vendor/adsp_dtb.mbn',)):
            with self.subTest(files=files):
                result, events = self.run_case(state='offline', firmware_files=files)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertEqual(events, 'mounted /sysroot\n')
                self.assertIn('keeping legacy startup: missing', result.stdout)
                self.assertNotIn('timed out', result.stdout)

    def test_compressed_and_updates_firmware_select_early_path(self):
        for prefix in ('', 'updates/', 'updates/test-kernel/', 'test-kernel/'):
            for suffix in ('', '.xz', '.zst'):
                with self.subTest(prefix=prefix, suffix=suffix):
                    result, events = self.run_case(firmware_files=(
                        prefix+'qcom/vendor/adsp.mbn'+suffix,
                        prefix+'qcom/vendor/adsp_dtb.mbn'+suffix))
                    self.assertEqual(result.returncode, 0, result.stdout)
                    self.assertIn('module qcom_q6v5_pas', events)
                    self.assertNotIn('keeping legacy', result.stdout)

    def test_missing_or_empty_firmware_names_keep_legacy_path(self):
        for names in (None, ()):
            result, events = self.run_case(firmware_names=names)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertEqual(events, 'mounted /sysroot\n')
            self.assertIn('keeping legacy startup', result.stdout)

    def test_legacy_requires_blacklist_and_unloaded_driver(self):
        for options in ({'blacklist': ''}, {'driver_loaded': True}):
            result, events = self.run_case(firmware_files=(), **options)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('mounted', events)
            self.assertNotIn('module ', events)

    def test_soccp_does_not_require_fallback_firmware(self):
        result, events = self.run_case(profile='soccp', state='attached', firmware_files=())
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn('module qcom_q6v5_pas', events)
        self.assertNotIn('keeping legacy', result.stdout)

    def test_non_qualcomm_is_untouched(self):
        result, events = self.run_case(profile=None, root_compatible='nvidia,gb10')
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(events, 'mounted /sysroot\n')

    def test_normal_entry_is_untouched(self):
        result, events = self.run_case(state='offline', enabled='')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(events, 'mounted /sysroot\n')

    def test_timeout_is_bounded(self):
        for timeout in ('0', '121', 'abc'):
            with self.subTest(timeout=timeout):
                result, events = self.run_case(timeout=timeout)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('mounted', events)


if __name__ == '__main__':
    unittest.main()
