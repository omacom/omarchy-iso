"""Every encrypted cmdline reaches Limine with rd.luks.name=.

The pre-built UKI unlocks the root with the systemd hooks, which read
rd.luks.name= and ignore cryptdevice=. Added on the archinstall-derived path
only, they would leave an encrypted install into free space (the pre-mounted
path) with a Limine entry that can never unlock: no cryptsetup job, no
passphrase prompt, "A start job is running for /dev/mapper/omarchy_root"
without limit. No integration scenario installs into free space (the
configurator partitions interactively), so the guarantee is tested here: the
single writer every cmdline passes through adds the parameters and refuses an
encrypted cmdline without them, and the function that adds them does so
without a device to look at, once, and only for encrypted cmdlines.
"""

import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

# The helper sits next to this file; unittest discovery does not always put
# this directory on the path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from archinstall_fakes import PACKAGE_ROOT, orchestrator_module  # noqa: E402

sys.path.insert(0, str(PACKAGE_ROOT))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import phases_impl  # noqa: E402

UUID = "00000000-1111-2222-3333-444444444444"  # no such device on any host
ENCRYPTED = (f"cryptdevice=UUID={UUID}:omarchy_root:allow-discards,no-read-workqueue "
             "root=/dev/mapper/omarchy_root rw")


def run(cmd):
    """archinstall's run: the command's output, or CalledProcessError."""
    return subprocess.run(cmd, capture_output=True, check=True)


class EncryptedCmdlineTest(unittest.TestCase):
    def setUp(self):
        self.luks_tuning = self.enterContext(
            orchestrator_module("luks_tuning", {"archinstall.lib.command": {"run": run}}))

    def test_a_uuid_spec_needs_no_device(self):
        cmdline = self.luks_tuning.with_cmdline_options(ENCRYPTED)
        self.assertIn(f"rd.luks.name={UUID}=omarchy_root", cmdline)
        self.assertIn(f"rd.luks.options={UUID}=", cmdline)

    def test_the_parameters_are_added_once(self):
        once = self.luks_tuning.with_cmdline_options(ENCRYPTED)
        self.assertEqual(self.luks_tuning.with_cmdline_options(once), once)

    def test_idempotent_call_does_not_reinvoke_blkid(self):
        partuuid_cmdline = "cryptdevice=PARTUUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:root root=/dev/mapper/root rw"
        with mock.patch.object(self.luks_tuning, "_luks_uuid_of", return_value=UUID) as lookup:
            once = self.luks_tuning.with_cmdline_options(partuuid_cmdline)
            twice = self.luks_tuning.with_cmdline_options(once)
        self.assertEqual(twice, once)
        lookup.assert_called_once_with("PARTUUID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

    def test_an_unencrypted_cmdline_is_left_alone(self):
        plain = "root=UUID=abc rw quiet"
        self.assertEqual(self.luks_tuning.with_cmdline_options(plain), plain)

    def write_defaults(self, cmdline):
        """What _write_limine_defaults leaves in /etc/kernel/cmdline."""
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (tmp / "default.conf").write_text('ESP_PATH="/boot"\nKERNEL_CMDLINE[default]+="@@CMDLINE@@"\n')
        (tmp / "limine.conf").write_text("timeout: 3\n")
        ctx = types.SimpleNamespace(target=tmp / "target")
        firmware = types.SimpleNamespace(has_uefi=lambda: True)
        with mock.patch.object(phases_impl, "_limine_template", lambda _ctx, name: tmp / name), \
             mock.patch.object(phases_impl, "arch", firmware), \
             mock.patch.object(phases_impl, "info", lambda *_: None):
            phases_impl._write_limine_defaults(ctx, cmdline, esp_mount="/boot")
        return (ctx.target / "etc" / "kernel" / "cmdline").read_text()

    def test_the_writer_adds_the_parameters(self):
        self.assertIn(f"rd.luks.name={UUID}=omarchy_root", self.write_defaults(ENCRYPTED))

    def test_the_writer_refuses_an_encrypted_cmdline_without_them(self):
        with mock.patch.object(self.luks_tuning, "with_cmdline_options", lambda cmdline: cmdline):
            with self.assertRaises(RuntimeError) as refused:
                self.write_defaults(ENCRYPTED)
        self.assertIn("no rd.luks.name=", str(refused.exception))

    def test_console_no_ansi_query_not_duplicated_when_dropin_sets_it(self):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        (tmp / "default.conf").write_text('ESP_PATH="/boot"\nKERNEL_CMDLINE[default]+="@@CMDLINE@@"\n')
        (tmp / "limine.conf").write_text("timeout: 3\n")
        target = tmp / "target"
        dropin = target / "etc" / "limine-entry-tool.d" / "omarchy-defaults.conf"
        dropin.parent.mkdir(parents=True)
        dropin.write_text(f'KERNEL_CMDLINE[default]+=" {phases_impl.CONSOLE_NO_ANSI_QUERY}"\n')
        ctx = types.SimpleNamespace(target=target)
        firmware = types.SimpleNamespace(has_uefi=lambda: True)
        with mock.patch.object(phases_impl, "_limine_template", lambda _ctx, name: tmp / name), \
             mock.patch.object(phases_impl, "arch", firmware), \
             mock.patch.object(phases_impl, "info", lambda *_: None):
            phases_impl._write_limine_defaults(ctx, ENCRYPTED, esp_mount="/boot")
        self.assertNotIn(phases_impl.CONSOLE_NO_ANSI_QUERY, (target / "etc" / "default" / "limine").read_text())
        self.assertIn(phases_impl.CONSOLE_NO_ANSI_QUERY, (target / "etc" / "kernel" / "cmdline").read_text())


if __name__ == "__main__":
    unittest.main()
