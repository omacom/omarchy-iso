#!/usr/bin/env python3
"""Exercise the actual initramfs hook against synthetic sysfs, never this host."""
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest

HOOK = Path(__file__).resolve().parents[2] / 'builder/qualcomm/early-startup'


class EarlyStartup(unittest.TestCase):
    def run_case(self, profile='adsp', state='running', mode='ok', enabled='1',
                 blacklist='', root_compatible='qcom,x1e80100', before_mount='',
                 timeout='3', disabled=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def write(name, text):
                p = root/name
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(text)
            write('proc/device-tree/compatible', root_compatible+'\0')
            write('clock', '0\n')
            write('events', '')
            write('kmsg', '')
            (root/'bin').mkdir()
            for command in ('cat','grep','readlink'):
                if mode=='missing-grep' and command=='grep':
                    continue
                tools=os.environ.get('QCOM_TEST_TOOLS')
                target=str(Path(tools)/command) if tools else shutil.which(command)
                (root/'bin'/command).symlink_to(target)
            if profile:
                compat = 'qcom,x1e80100-adsp-pas' if profile == 'adsp' else 'qcom,glymur-soccp-pas'
                write('dt/processor/compatible', compat+'\0')
                if disabled:
                    write('dt/processor/status', 'disabled\0')
                dev = root/'sys/bus/platform/devices/6800000.remoteproc'
                dev.mkdir(parents=True)
                (dev/'of_node').symlink_to(root/'dt/processor')
                remote = root/'sys/class/remoteproc/remoteproc7'
                remote.mkdir(parents=True)
                (remote/'device').symlink_to(dev)
                write('sys/class/remoteproc/remoteproc7/state', state+'\n')
            # Relocate all filesystem access in the production hook. There is
            # no production environment override for reading a different sysfs.
            code = HOOK.read_text().replace('/sys/', str(root)+'/sys/')
            code = code.replace('/proc/device-tree/', str(root)+'/proc/device-tree/')
            code = code.replace('/dev/kmsg', str(root)+'/kmsg')
            (root/'hook').write_text(code)
            harness = r'''
getarg() {
 case "$1" in
 omarchy.qcom_early) printf '%s' "$ENABLED";;
 omarchy.qcom_timeout) printf '%s' "$TIMEOUT";;
 modprobe.blacklist) printf '%s' "$BLACKLIST";;
 *) printf '%s' "${2:-}";;
 esac
}
modprobe() {
 printf 'module %s\n' "$1" >>"$ROOT/events"
 [ "$MODE:$1" != fail:qcom_q6v5_pas ]
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
                                'BLACKLIST': blacklist, 'TIMEOUT': timeout}
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
        result, events = self.run_case(mode='fail')
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

    def test_blacklist_conflict_blocks_mount(self):
        for blacklist in ('qcom_q6v5_pas', 'foo,qcom-q6v5-pas,bar'):
            with self.subTest(blacklist=blacklist):
                result, events = self.run_case(blacklist=blacklist)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('mounted', events)

    def test_unknown_qualcomm_does_not_claim_support(self):
        result, events = self.run_case(profile=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('mounted', events)

    def test_missing_early_utility_cannot_silently_skip_gate(self):
        result, events = self.run_case(mode='missing-grep')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing early-boot utility', result.stdout)
        self.assertNotIn('mounted', events)

    def test_disabled_owner_is_not_used(self):
        result, events = self.run_case(disabled=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('mounted', events)

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
