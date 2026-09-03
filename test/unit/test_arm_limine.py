#!/usr/bin/python
#
# The installer runs on the live ISO and must pick the Limine EFI binary and
# kernel for the machine it is running on rather than assuming x86_64.

import os
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
# phases_impl imports the archinstall adapter, which needs archinstall itself;
# none of the helpers under test touch it.
sys.modules.setdefault(
    "orchestrator.archinstall_adapter", types.ModuleType("orchestrator.archinstall_adapter")
)

from orchestrator import context, phases_impl  # noqa: E402

CONFIGURATOR = ROOT / "configs/airootfs/root/configurator"


def run_configurator_snippet(machine: str, snippet: str) -> subprocess.CompletedProcess:
    """Run a fragment of the configurator with uname reporting `machine`."""
    with tempfile.TemporaryDirectory() as directory:
        fake_uname = Path(directory) / "uname"
        fake_uname.write_text(f"#!/bin/bash\necho {machine}\n")
        fake_uname.chmod(0o755)
        env = dict(os.environ, PATH=f"{directory}:{os.environ['PATH']}")
        return subprocess.run(
            ["bash", "-c", snippet], capture_output=True, text=True, env=env
        )


def configurator_block(start: str, end: str) -> str:
    text = CONFIGURATOR.read_text()
    begin = text.index(start)
    return text[begin : text.index(end, begin) + len(end)]


class LimineEfiNamesTest(unittest.TestCase):
    def test_aarch64_uses_aa64_efi_binary(self):
        for machine in ("aarch64", "arm64"):
            with self.subTest(machine=machine):
                self.assertEqual(
                    phases_impl._limine_efi_names(machine),
                    ("BOOTAA64.EFI", "limine_aa64.efi", "BOOTAA64.EFI"),
                )

    def test_x86_64_keeps_x64_efi_binary(self):
        self.assertEqual(
            phases_impl._limine_efi_names("x86_64"),
            ("BOOTX64.EFI", "limine_x64.efi", "BOOTX64.EFI"),
        )

    def test_unknown_machine_is_refused(self):
        with self.assertRaises(RuntimeError):
            phases_impl._limine_efi_names("riscv64")

    def test_running_machine_is_the_default(self):
        fake = os.uname_result(("Linux", "host", "6.0", "#1", "aarch64"))
        with patch.object(phases_impl.os, "uname", return_value=fake):
            self.assertEqual(phases_impl._limine_efi_names()[1], "limine_aa64.efi")

    def test_default_omarchy_install_leaves_efi_binary_to_the_machine(self):
        # The configurator writes efi_binary explicitly; the fallback intent for
        # a JSON without it must not pin x86_64 either.
        default = context._default_omarchy_install({})
        self.assertNotIn("efi_binary", default["boot"])
        self.assertEqual(default["boot"]["esp_path"], "/EFI/limine")


class ConfiguratorArchitectureTest(unittest.TestCase):
    def test_limine_binary_follows_uname(self):
        block = configurator_block('case "$(uname -m)" in', "esac")
        snippet = block + '\nprintf "%s" "$LIMINE_EFI_BINARY"'
        self.assertEqual(run_configurator_snippet("aarch64", snippet).stdout, "limine_aa64.efi")
        self.assertEqual(run_configurator_snippet("x86_64", snippet).stdout, "limine_x64.efi")
        unsupported = run_configurator_snippet("riscv64", snippet)
        self.assertNotEqual(unsupported.returncode, 0)
        self.assertIn("unsupported Limine EFI architecture", unsupported.stderr)

    def test_configurator_json_names_the_selected_binary(self):
        text = CONFIGURATOR.read_text()
        self.assertNotIn('"efi_binary": "limine_x64.efi"', text)
        self.assertEqual(text.count('"efi_binary": "$LIMINE_EFI_BINARY"'), 2)

    def test_detect_kernel_picks_the_alarm_kernel_on_aarch64(self):
        block = configurator_block("detect_kernel() {", "\n}\n")
        snippet = "lspci() { return 1; }\n" + block + "\ndetect_kernel"
        self.assertEqual(run_configurator_snippet("aarch64", snippet).stdout.strip(), "linux-aarch64")
        self.assertEqual(run_configurator_snippet("x86_64", snippet).stdout.strip(), "linux")

    def test_logo_animation_is_optional(self):
        # ttfx is not packaged on Arch Linux ARM; both scripts must cope.
        self.assertIn("if command -v ttfx >/dev/null; then", CONFIGURATOR.read_text())
        dashboard = ROOT / "configs/airootfs/usr/local/bin/omarchy-install-dashboard"
        self.assertIn("&& command -v ttfx >/dev/null; then", dashboard.read_text())


if __name__ == "__main__":
    unittest.main()
