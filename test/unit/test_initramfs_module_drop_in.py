"""The module drop-in only leaves a module out of a kernel that lacks it."""

import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "configs/airootfs/usr/share/omarchy-iso"))
sys.modules.setdefault(
    "orchestrator.archinstall_adapter",
    types.ModuleType("orchestrator.archinstall_adapter"),
)
from orchestrator import phases_impl  # noqa: E402

T2 = "7.2.11-arch1-Watanare-T2-1-t2"
OMARCHY = "7.2.15-1-omarchy"
# Which modules each kernel ships, as modinfo would answer.
SHIPPED = {
    T2: {"t2bce_vhci", "usbhid", "hid_apple"},
    OMARCHY: {"usbhid", "hid_apple"},
}


class InitramfsModuleDropInTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.target = Path(tmp.name)
        for release, pkgbase in ((T2, "linux-t2"), (OMARCHY, "linux-omarchy")):
            directory = self.target / "usr/lib/modules" / release
            directory.mkdir(parents=True)
            (directory / "pkgbase").write_text(pkgbase + "\n")
        self.conf_dir = self.target / "etc/mkinitcpio.conf.d"
        self.conf_dir.mkdir(parents=True)
        (self.conf_dir / "apple-t2.conf").write_text(
            "MODULES+=(t2bce_vhci usbhid hid_apple)\n"
        )
        self.ctx = types.SimpleNamespace(target=self.target)

    def write_drop_in(self):
        def modinfo(argv, **_):
            release, module = argv[-2], argv[-1]
            return subprocess.CompletedProcess(argv, 0 if module in SHIPPED[release] else 1)

        with mock.patch.object(phases_impl.subprocess, "run", side_effect=modinfo), \
                mock.patch.object(phases_impl, "info"):
            phases_impl._drop_initramfs_modules_the_kernel_lacks(self.ctx)
        return self.conf_dir / phases_impl.INITRAMFS_MODULES_CONF

    def modules_for(self, drop_in, release):
        # Source the drop-in as mkinitcpio does, with modinfo answering for
        # the kernel being built.
        script = (
            'modinfo() { [[ $1 == -k ]] || return 2; [[ " $SHIPPED " == *" $3 "* ]]; }\n'
            "MODULES=(t2bce_vhci usbhid hid_apple)\n"
            f'. "{drop_in}"\n'
            'printf "%s\\n" "${MODULES[*]}"\n'
        )
        result = subprocess.run(
            ["bash", "-c", script],
            env={"KERNELVERSION": release, "SHIPPED": " ".join(sorted(SHIPPED[release])),
                 "PATH": "/usr/bin:/bin"},
            check=True, capture_output=True, text=True,
        )
        return result.stdout.split()

    def test_t2_kernel_keeps_the_keyboard_module(self):
        drop_in = self.write_drop_in()
        self.assertIn("t2bce_vhci", self.modules_for(drop_in, T2))

    def test_kernel_without_the_module_leaves_it_out(self):
        drop_in = self.write_drop_in()
        self.assertEqual(self.modules_for(drop_in, OMARCHY), ["usbhid", "hid_apple"])

    def test_no_drop_in_when_every_kernel_has_every_module(self):
        everything = {T2: SHIPPED[T2], OMARCHY: SHIPPED[T2]}
        with mock.patch.dict(SHIPPED, everything):
            drop_in = self.write_drop_in()
        self.assertFalse(drop_in.exists())


if __name__ == "__main__":
    unittest.main()
