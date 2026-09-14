"""Unit tests for the removable-media boot route on free-space installs.

A free-space (protected) install puts Omarchy on a dedicated ESP that the
configurator creates, wipes and formats in free space. Nothing else on the
disk uses that partition's EFI/BOOT/BOOTX64.EFI, so Omarchy claims it and
keeps a boot route that survives firmware refusing or discarding the
"Limine" NVRAM entry.

Covers the install intent that turns the fallback on, the
ENABLE_LIMINE_FALLBACK line it produces in /etc/default/limine,
validate_boot's handling of each combination of the two routes, and
_register_limine_efi_entry surviving firmware that refuses the NVRAM write
so that the removable route is still deployed.
"""

import json
import subprocess
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

from orchestrator import phases_impl  # noqa: E402
from orchestrator.context import InstallContext, _default_omarchy_install  # noqa: E402


def make_ctx(tmp: Path, omarchy_install: dict) -> InstallContext:
    return InstallContext(
        config_path=tmp / "user_configuration.json",
        creds_path=tmp / "user_credentials.json",
        full_name="Test User",
        email="test@example.com",
        encrypt=False,
        authorized_keys_path=None,
        tailscale_authkey_path=None,
        user_configuration={"disk_config": {"config_type": "pre_mounted_config"}},
        user_credentials={"users": [{"username": "test"}]},
        arch_config_path=tmp / "arch_configuration.json",
        omarchy_install=omarchy_install,
        target=tmp / "target",
        omarchy_path=tmp / "omarchy",
    )


PROTECTED_INSTALL = {
    "mode": "protected",
    "target_mount": "/mnt",
    "boot": {
        "esp_mount": "/boot",
        "esp_path": "/EFI/limine",
        "efi_binary": "limine_x64.efi",
    },
    "storage": {
        "esp_device": "/dev/nvme0n1p6",
        "root_device": "/dev/nvme0n1p7",
        "root_mapper": "/dev/nvme0n1p7",
        "luks_uuid": None,
        "kernel": "linux",
    },
}


class BootIntentTest(unittest.TestCase):
    """The fallback is on for a free-space install, not only a full-disk one."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def test_protected_install_enables_the_fallback_by_default(self):
        ctx = make_ctx(self.dir, json.loads(json.dumps(PROTECTED_INSTALL)))
        self.assertTrue(ctx.is_protected)
        self.assertTrue(phases_impl._boot_intent(ctx)["enable_fallback"])

    def test_full_disk_install_still_enables_the_fallback(self):
        ctx = make_ctx(self.dir, {"mode": "full_disk", "boot": {}, "storage": {}})
        self.assertFalse(ctx.is_protected)
        self.assertTrue(phases_impl._boot_intent(ctx)["enable_fallback"])

    def test_explicit_false_is_still_honoured(self):
        install = json.loads(json.dumps(PROTECTED_INSTALL))
        install["boot"]["enable_fallback"] = False
        ctx = make_ctx(self.dir, install)
        self.assertFalse(phases_impl._boot_intent(ctx)["enable_fallback"])

    def test_pre_mounted_config_without_omarchy_install_enables_the_fallback(self):
        default = _default_omarchy_install({"disk_config": {"config_type": "pre_mounted_config"}})
        self.assertEqual(default["mode"], "protected")
        self.assertTrue(default["boot"]["enable_fallback"])


class LimineDefaultsTest(unittest.TestCase):
    """The intent has to reach /etc/default/limine, which limine-install reads."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

        templates = self.dir / "omarchy" / "default" / "limine"
        templates.mkdir(parents=True)
        (templates / "default.conf").write_text(
            'ESP_PATH="/boot"\n\nKERNEL_CMDLINE[default]+="@@CMDLINE@@"\n'
        )
        (templates / "limine.conf").write_text("# limine.conf\n")

        (self.dir / "target" / "boot").mkdir(parents=True)

    def write_defaults(self, install):
        ctx = make_ctx(self.dir, install)
        with mock.patch.object(phases_impl, "_blkid_uuid", return_value="dead-beef"), \
             mock.patch.object(phases_impl.arch, "has_uefi", return_value=True, create=True):
            phases_impl._write_pre_mounted_limine_defaults(ctx)
        return (ctx.target / "etc" / "default" / "limine").read_text()

    def test_protected_install_writes_enable_limine_fallback_yes(self):
        text = self.write_defaults(json.loads(json.dumps(PROTECTED_INSTALL)))
        self.assertIn("ENABLE_LIMINE_FALLBACK=yes", text)
        self.assertNotIn("ENABLE_LIMINE_FALLBACK=no", text)

    def test_explicit_false_writes_no(self):
        install = json.loads(json.dumps(PROTECTED_INSTALL))
        install["boot"]["enable_fallback"] = False
        self.assertIn("ENABLE_LIMINE_FALLBACK=no", self.write_defaults(install))


class BootRouteValidationTest(unittest.TestCase):
    """Either route boots the machine; losing both is what must stop the install."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.esp = Path(self.tmp.name) / "esp"
        self.esp.mkdir(parents=True)

    def write_fallback(self, contents=b"MZ"):
        path = self.esp / "EFI" / "BOOT" / "BOOTX64.EFI"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
        return path

    def validate(self, entries):
        state = {"entries": entries, "order": list(entries), "raw": ""}
        with mock.patch.object(phases_impl, "_read_efibootmgr", return_value=state), \
             mock.patch.object(phases_impl, "error") as warn:
            phases_impl._validate_uefi_boot_routes(self.esp)
        return warn

    def test_both_routes_present_is_silent(self):
        self.write_fallback()
        warn = self.validate({"0002": "Limine", "0000": "Windows Boot Manager"})
        warn.assert_not_called()

    def test_discarded_boot_entry_warns_and_names_the_firmware_menu(self):
        self.write_fallback()
        warn = self.validate({"0000": "Windows Boot Manager"})
        warn.assert_called_once()
        message = warn.call_args[0][0]
        self.assertIn("discarded", message)
        self.assertIn("BOOTX64.EFI", message)
        self.assertIn("boot priority", message)

    def test_missing_fallback_warns_but_does_not_stop_a_registered_install(self):
        warn = self.validate({"0002": "Limine"})
        warn.assert_called_once()
        self.assertIn("BOOTX64.EFI", warn.call_args[0][0])

    def test_empty_fallback_file_does_not_count_as_a_route(self):
        self.write_fallback(b"")
        warn = self.validate({"0002": "Limine"})
        warn.assert_called_once()

    def test_no_route_at_all_stops_the_install(self):
        state = {"entries": {"0000": "Windows Boot Manager"}, "order": ["0000"], "raw": ""}
        with mock.patch.object(phases_impl, "_read_efibootmgr", return_value=state):
            with self.assertRaises(RuntimeError) as caught:
                phases_impl._validate_uefi_boot_routes(self.esp)
        self.assertIn("no bootable route", str(caught.exception))


class BootEntryRegistrationTest(unittest.TestCase):
    """Firmware that refuses a boot-variable write must not end the install.

    Registration runs in arch_install_system, phases before
    finalize_limine_boot writes EFI/BOOT/BOOTX64.EFI. Raising here leaves the
    machine with neither route, which is issue #127.
    """

    def register(self, results, entries_after=None):
        """Run _register_limine_efi_entry with efibootmgr's exit codes scripted.

        `results` maps the efibootmgr subcommand (--create, --bootorder,
        --delete-bootnum) to the CompletedProcess it should return.
        """
        calls = []

        def fake_run(argv, **kwargs):
            calls.append(argv)
            result = subprocess.CompletedProcess(argv, 0, "", "")
            for flag, scripted in results.items():
                if flag in argv:
                    result = scripted
                    break
            # Honour check= the way subprocess.run does, so a test that asserts
            # "this does not abort the install" fails against a caller that
            # still passes check=True.
            if kwargs.get("check") and result.returncode != 0:
                raise subprocess.CalledProcessError(
                    result.returncode, argv, result.stdout, result.stderr
                )
            return result

        pre = {"entries": {"0000": "Windows Boot Manager"}, "order": ["0000"], "raw": ""}
        post = {
            "entries": entries_after if entries_after is not None else {
                "0000": "Windows Boot Manager", "0002": "Limine",
            },
            "order": ["0000"],
            "raw": "",
        }
        with mock.patch.object(phases_impl.subprocess, "run", side_effect=fake_run), \
             mock.patch.object(phases_impl, "_read_efibootmgr", return_value=post), \
             mock.patch.object(phases_impl, "error") as warn:
            phases_impl._register_limine_efi_entry(
                Path("/dev/nvme0n1"), 6, "\\EFI\\limine\\limine_x64.EFI", pre_state=pre
            )
        return calls, warn

    def messages(self, warn):
        return " ".join(call[0][0] for call in warn.call_args_list)

    def test_refused_create_does_not_raise_and_reports_the_reason(self):
        refused = subprocess.CompletedProcess(
            [], 1, "", "Could not prepare Boot variable: No space left on device"
        )
        calls, warn = self.register({"--create": refused})

        message = self.messages(warn)
        self.assertIn("No space left on device", message)
        self.assertIn("BOOTX64.EFI", message)
        self.assertNotIn("--bootorder", [flag for argv in calls for flag in argv])

    def test_create_that_leaves_no_entry_does_not_raise(self):
        calls, warn = self.register(
            {}, entries_after={"0000": "Windows Boot Manager"}
        )

        self.assertIn("discarded", self.messages(warn))
        self.assertNotIn("--bootorder", [flag for argv in calls for flag in argv])

    def test_successful_registration_sets_bootorder_and_stays_quiet(self):
        calls, warn = self.register({})

        bootorder = [argv for argv in calls if "--bootorder" in argv]
        self.assertEqual(len(bootorder), 1)
        self.assertEqual(bootorder[0][-1], "0002,0000")
        warn.assert_not_called()

    def test_refused_bootorder_keeps_the_entry_and_warns(self):
        refused = subprocess.CompletedProcess([], 1, "", "write error")
        calls, warn = self.register({"--bootorder": refused})

        message = self.messages(warn)
        self.assertIn("BootOrder", message)
        self.assertIn("boot priority", message)


class ConfiguratorTest(unittest.TestCase):
    """The configurator emits the JSON the orchestrator reads, so check it too."""

    def test_free_space_install_config_enables_the_fallback(self):
        configurator = Path(__file__).resolve().parents[2] / "configs/airootfs/root/configurator"
        body = configurator.read_text()
        protected = body[body.index('"mode": "protected"'):]
        boot_block = protected[protected.index('"boot": {'):protected.index("},", protected.index('"boot": {'))]
        self.assertIn('"enable_fallback": true', boot_block)


if __name__ == "__main__":
    unittest.main()
